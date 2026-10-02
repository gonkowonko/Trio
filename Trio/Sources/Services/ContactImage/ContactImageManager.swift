import Combine
import Contacts
import CoreData
import Swinject
import UIKit

protocol ContactImageManagerDelegate: AnyObject {
    func contactImageManagerDidUpdateState(_ state: ContactImageState)
}

protocol ContactImageManager {
    var delegate: ContactImageManagerDelegate? { get set }
    func requestAccess() async -> Bool
    func createContact(name: String) async -> String?
    func deleteContact(withIdentifier identifier: String) async -> Bool
    func updateContact(withIdentifier identifier: String, newName: String) async -> Bool
    @MainActor func updateContactImageState() async
    func setImageForContact(contactId: String) async
    func validateContactExists(withIdentifier identifier: String) async -> Bool
}

final class BaseContactImageManager: NSObject, ContactImageManager, Injectable {
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var contactImageStorage: ContactImageStorage!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var iobService: IOBService!
    @Injected() private var apsManager: APSManager!
    @Injected() private var broadcaster: Broadcaster!

    /// Time-derived visual state that changes even when no new data arrives: the
    /// loop ring's colour and whether the CGM reading has aged into its muted
    /// treatment. Used to decide when a periodic refresh would actually change the
    /// rendered image, so the timer can skip redundant contact-store writes.
    private struct RenderStaleness: Equatable {
        /// Held as the very value `ContactPicture.ringColor` classifies, rather than
        /// as a private re-derivation of it. This used to be a third hand-written
        /// copy of the 30s lag and the 5/10-minute ladder, annotated "must match
        /// `ContactPicture.Config.lag`" — a promise the compiler could not keep,
        /// since that constant was `private`. Had the two drifted, this gate would
        /// have reported "unchanged" for a boundary the renderer had crossed and
        /// frozen the ring on the wrong colour indefinitely.
        let loop: LoopFreshness
        /// The glucose band drives the fade on the value, trend and delta — and, at
        /// `.expired`, replaces them with dashes — so the periodic refresh must
        /// re-render when it changes too. Every band here draws differently, so each
        /// transition earns its contact-store write.
        let glucoseFreshness: GlucoseFreshness

        static func current(for state: ContactImageState, now: Date = Date()) -> RenderStaleness {
            RenderStaleness(
                loop: LoopFreshness.classify(
                    lastLoopDate: state.lastLoopDate,
                    now: now,
                    closedLoop: state.closedLoop,
                    manualTempBasal: state.manualTempBasal
                ),
                glucoseFreshness: GlucoseFreshness.classify(glucoseDate: state.glucoseDate, now: now)
            )
        }
    }

    private let contactStore = CNContactStore()

    // Make it read-only from outside the class
    private(set) var state = ContactImageState()

    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseContactImageManager.queue", qos: .background)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Token for the `didBecomeActive` observer, held so it can be removed. The
    /// block-based `addObserver` is not cleaned up by the observer's deallocation
    /// the way the selector-based API is — dropping the token leaks the block for
    /// the lifetime of the notification center.
    private var foregroundObserver: NSObjectProtocol?

    /// Periodic timer that re-renders contact images purely so staleness advances
    /// (green -> yellow -> red) when no new glucose / IOB / determination arrives.
    ///
    /// 30s to match `Home.StateModel`'s own tick, which is what repaints the loop
    /// pill. Both surfaces sample on independent timers, so they can still land on
    /// opposite sides of a boundary for up to one tick — matching the cadence keeps
    /// that worst case to ~30s instead of ~60s. Ticks are cheap: the pre-check below
    /// is a main-actor hop and a struct comparison, and does no I/O when the bands
    /// have not moved.
    private let staleRefreshTimer = DispatchTimer(timeInterval: 30)

    /// The staleness last written to the contact store, so the timer can skip
    /// redundant `CNSaveRequest`s while the rendered result would be unchanged.
    private var lastRenderedStaleness: RenderStaleness?

    /// What a queued render is allowed to skip. Ordered so coalescing keeps the
    /// stronger request: `full` > `stalenessOnly`.
    private enum RenderRequest: Int, Comparable {
        /// Staleness timer tick — skip the pass if the staleness band is unchanged.
        case stalenessOnly
        /// New data arrived — render, but skip any contact whose photo in the store
        /// is already byte-identical to the new one (CONTACT-CYCLE).
        case full

        static func < (lhs: RenderRequest, rhs: RenderRequest) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// CONTACT-CYCLE: how long after the loop lands to render. Long enough for what
    /// follows `Loop succeeded` in the same cycle — `reportEnacted`, the IOB refresh it
    /// triggers, the Nightscout "uploaded" flag written back to the determination —
    /// which the 25 Sep logs put within ~2s.
    private static let loopSettleDelay: TimeInterval = 5

    /// CONTACT-CYCLE: how long any other data event waits for the loop before
    /// rendering anyway. The loop normally lands 7-10s after a reading and pulls the
    /// render in to `loopSettleDelay`; this only fires on its own when the loop fails
    /// or doesn't run, or for data that changes outside a cycle (a manual bolus).
    private static let loopFallbackDelay: TimeInterval = 30

    /// CONTACT-CYCLE: when the armed render is due, or nil if none is armed. Never
    /// pushed later by a newer event — only pulled earlier — so a steady trickle of
    /// events cannot starve it the way a debounce can. Main-actor access only.
    private var armedRenderDeadline: Date?
    private var armedRenderTask: Task<Void, Never>?

    /// CONTACT-CYCLE: held while a render is armed, so iOS doesn't suspend the app
    /// inside the wait and lose the render until the next wake. That is the failure
    /// that sank the Live Activity's 6s debounce on 2026-08-18. Costs a few seconds
    /// of extra residency per cycle at most, and only when nothing else is keeping
    /// the app awake. Main-actor access only.
    private var armedRenderBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// The render waiting to run behind the one currently executing, if any.
    /// Requests arriving while one is queued coalesce into it instead of piling
    /// up further renders. Main-actor access only.
    private var queuedRenderRequest: RenderRequest?

    /// Tail of the serial render chain; every new render awaits the previous one,
    /// so at most one render executes at a time. Main-actor access only.
    private var renderTask: Task<Void, Never>?

    private var units: GlucoseUnits = .mgdL

    private var deltaFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = settingsManager.settings.units == .mmolL ? 1 : 0
        formatter.positivePrefix = "+"
        formatter.negativePrefix = "-"
        return formatter
    }

    weak var delegate: ContactImageManagerDelegate?

    init(resolver: Resolver) {
        super.init()
        injectServices(resolver)
        units = settingsManager.settings.units
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        registerRenderTriggers()
        startStaleRefreshTimer()
        registerForegroundRefresh()
        broadcaster.register(SettingsObserver.self, observer: self)
    }

    deinit {
        if let foregroundObserver = foregroundObserver {
            Foundation.NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    // MARK: - Render triggers

    /// Subscribes the render pipeline to every data signal that should refresh
    /// the contact images.
    ///
    /// A single loop cycle emits all of these: new glucose kicks the loop, which then
    /// publishes a loop date (the same signal the app's loop pill uses — it also fires
    /// in open loop, where the determination's `timestamp` is never stamped), a new
    /// determination and an IOB update. They are merged so the render sees the fully
    /// settled state rather than whichever slice arrived first.
    ///
    /// **Sized from Gary's device logs (2026-08-24), not from a guess.** This was a
    /// `debounce(for: .seconds(1))` on the belief that a cycle's events land "within a
    /// second or two". They do not: measured across 319 cycles, a cycle's events span a
    /// median of **12s** (p75 15s, p90 28s), so the debounce released about four times
    /// per cycle. The result was 1,210 renders in a day against 287 loop cycles — 4.2
    /// per cycle, with 74% of them redundant repeats inside the same cycle. Each one is
    /// two Core Data fetches, a file read, and then per contact entry a 1024x1024
    /// main-actor bitmap render, a PNG encode and a `CNSaveRequest`. That is the most
    /// expensive recurring thing this app does, and three quarters of it was waste.
    ///
    /// `throttle`, not a longer `debounce`, for the reason the Live Activity pipeline
    /// gives: debounce waits for silence and a steady trickle can starve it
    /// indefinitely. Throttle guarantees an emission per window, and Combine's throttle
    /// passes the *first* element straight through — so the photo still updates the
    /// moment a reading lands, and only the follow-on chatter is suppressed.
    ///
    /// 15s because it covers 81% of observed bursts end to end (6s — the Live Activity's
    /// value — covers only 21%, and 30s buys just 10 points more for double the lag).
    ///
    /// **CONTACT-CYCLE (2026-09-30): replaced by one render per cycle, after the loop.**
    /// The throttle's leading edge fired on the reading, *before* the loop had run, so
    /// that pass always drew the previous cycle's IOB, COB and eventual BG. The trailing
    /// edge 15s later then drew the real values. 24-28 Sep: 2.1 passes per cycle, 79% of
    /// cycles exactly 2, and with two contacts ~1,150 `CNSaveRequest`s a day, half of them
    /// writing numbers that were already out of date.
    ///
    /// Now every event only *arms* a render. The loop landing arms it `loopSettleDelay`
    /// out; anything else arms it `loopFallbackDelay` out. The deadline can only move
    /// earlier, never later. So a reading at t, a loop at t+10 gives one render at t+15,
    /// and if the loop never comes, the reading still renders at t+30. Nobody needs a
    /// contact photo inside 15s; the Live Activity is where immediacy lives.
    private func registerRenderTriggers() {
        let determinationUpdates: AnyPublisher<Void, Never> = coreDataPublisher?
            .filteredByEntityName("OrefDetermination")
            .map { _ in () }
            .eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()

        let triggers: [(source: String, delay: TimeInterval, publisher: AnyPublisher<Void, Never>)] = [
            ("loop", Self.loopSettleDelay, apsManager.lastLoopDateSubject.map { _ in () }.eraseToAnyPublisher()),
            ("glucose", Self.loopFallbackDelay, glucoseStorage.updatePublisher.eraseToAnyPublisher()),
            ("iob", Self.loopFallbackDelay, iobService.iobPublisher.map { _ in () }.eraseToAnyPublisher()),
            ("determination", Self.loopFallbackDelay, determinationUpdates)
        ]

        for trigger in triggers {
            trigger.publisher
                .sink { [weak self] in
                    Task { @MainActor in
                        self?.armRender(in: trigger.delay, source: trigger.source)
                    }
                }
                .store(in: &subscriptions)
        }
    }

    /// CONTACT-CYCLE: arms one render `delay` from now, unless one is already due
    /// sooner. See `registerRenderTriggers()`.
    @MainActor private func armRender(in delay: TimeInterval, source _: String) {
        let deadline = Date().addingTimeInterval(delay)
        if let armed = armedRenderDeadline, armed <= deadline {
            return
        }

        armedRenderTask?.cancel()
        armedRenderDeadline = deadline
        if armedRenderBackgroundTask == .invalid {
            armedRenderBackgroundTask = startBackgroundTask(withName: "Contact Image Cycle Wait")
        }

        armedRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // Replaced by a sooner arm: that one now owns the background task.
            guard !Task.isCancelled, let self else { return }
            self.armedRenderDeadline = nil
            self.armedRenderTask = nil
            self.enqueueRenderOnMain(.full)

            // Hold the wait's assertion until the render is done — it takes its own,
            // but only once it starts. If another render was armed meanwhile, that
            // one inherits the assertion and ends it.
            await self.renderTask?.value
            if self.armedRenderDeadline == nil {
                endBackgroundTaskSafely(&self.armedRenderBackgroundTask, taskName: "Contact Image Cycle Wait")
            }
        }
    }

    // MARK: - Foreground refresh

    /// Re-renders contact images when the app becomes active.
    ///
    /// The event-driven publishers and the stale-refresh timer only run while the app
    /// is executing; once Trio is suspended the contact image freezes on its last
    /// render, so the value the user sees in Contacts / on a call screen can be stale
    /// even while the app's own loop is healthy. Refreshing on `didBecomeActive`
    /// guarantees the image reflects current data every time the user returns to Trio,
    /// mirroring the Live Activity's foreground refresh.
    private func registerForegroundRefresh() {
        foregroundObserver = Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Unconditional render so returning to the app always repairs whatever
            // the contact store currently holds. The identical-bytes skip compares
            // against the store itself, so a photo changed outside Trio still differs
            // and is rewritten; only a contact already holding this image is skipped.
            self?.enqueueRender(.full)
        }
    }

    // MARK: - Time-driven staleness refresh

    /// Starts the periodic timer that re-renders contact images when data goes stale.
    ///
    /// The event-driven publishers (glucose / IOB / determination) only fire when *new*
    /// data arrives. When the CGM or loop stalls, none of them fire, so the contact image
    /// would otherwise stay frozen on the last-rendered values. This timer advances the
    /// loop-ring color (green -> yellow -> red) and mutes the glucose value once it goes
    /// stale, but only writes to the contact store when the rendered result actually
    /// changes, to avoid hammering `CNContactStore` every tick.
    private func startStaleRefreshTimer() {
        staleRefreshTimer.eventHandler = { [weak self] in
            guard let self = self else { return }
            Task {
                // Cheap pre-check so a tick with an unchanged staleness band doesn't
                // enqueue a render (and its Core Data fetches) every 60 s. The
                // serialized render re-checks this authoritatively after refreshing
                // the state, so a stale pre-check here can never bake wrong data.
                let bandChanged = await MainActor.run {
                    RenderStaleness.current(for: self.state) != self.lastRenderedStaleness
                }
                guard bandChanged else { return }
                self.enqueueRender(.stalenessOnly)
            }
        }
        staleRefreshTimer.resume()
    }

    // MARK: - Serialized render pipeline

    /// Enqueues a re-render of all contact images.
    ///
    /// Every trigger (data events, staleness timer, foreground activation) funnels
    /// through here so that only one render executes at a time and each render
    /// snapshots `state` when it *starts*, not when it was requested. This closes
    /// the race where a render holding a pre-update state snapshot could land its
    /// contact-store write after a fresher render, leaving a stale image baked into
    /// the contact while `lastRenderedStaleness` claimed otherwise — which then made
    /// the staleness timer skip the repair until the next data event.
    private func enqueueRender(_ request: RenderRequest) {
        Task { @MainActor [weak self] in
            self?.enqueueRenderOnMain(request)
        }
    }

    /// The body of `enqueueRender`, callable synchronously from the main actor so a
    /// caller can await the resulting `renderTask` (CONTACT-CYCLE's armed render does).
    @MainActor private func enqueueRenderOnMain(_ request: RenderRequest) {
        // Coalesce into an already-queued render: it will snapshot the latest
        // state when it starts anyway. Just make sure the queued request isn't
        // downgraded — a data-driven request isn't reduced to the staleness-only
        // gate.
        if let queued = queuedRenderRequest {
            if request > queued {
                queuedRenderRequest = request
            }
            return
        }

        queuedRenderRequest = request
        let previousRender = renderTask
        renderTask = Task {
            await previousRender?.value
            await self.runQueuedRender()
        }
    }

    /// Executes one queued render: refreshes the state first, then re-renders all
    /// images. Only ever runs on the serial render chain built in `enqueueRender`.
    private func runQueuedRender() async {
        // Claim the queued request; requests arriving from here on enqueue a new
        // render behind this one instead of coalescing into it.
        guard let request = await MainActor.run(body: { () -> RenderRequest? in
            let queued = queuedRenderRequest
            queuedRenderRequest = nil
            return queued
        }) else { return }

        // Always re-read the latest data so even a timer-driven render can never
        // bake an outdated reading into the image.
        await updateContactImageState()

        if request == .stalenessOnly {
            // Authoritative staleness gate: evaluated on the serialized chain and
            // after the state refresh, so it reflects exactly what would be
            // rendered — a stale pre-check by the timer can't wedge the pipeline.
            let unchanged = await MainActor.run {
                RenderStaleness.current(for: state) == lastRenderedStaleness
            }
            if unchanged {
                return
            }
        }

        await updateContactImages()
    }

    // MARK: - Core Data Fetches

    private func fetchlastDetermination() async throws -> [NSManagedObjectID] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchlastDetermination"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate(format: "deliverAt >= %@", Date.halfHourAgo as NSDate), // fetches enacted and suggested
            key: "deliverAt",
            ascending: false,
            fetchLimit: 1
        )

        return try await context.perform {
            guard let fetchedResults = results as? [OrefDetermination] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID)
        }
    }

    private func fetchGlucose() async throws -> [NSManagedObjectID] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchGlucose"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateFor20MinAgo,
            key: "date",
            ascending: false,
            fetchLimit: 3 /// We only need 1-3 values, depending on whether the user wants to show delta or not
        )

        return try await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return glucoseResults.map(\.objectID)
        }
    }

    private func getCurrentGlucoseTarget() async -> Decimal? {
        let now = Date()
        let calendar = Calendar.current

        let bgTargets = await fileStorage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
            ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        let entries: [(start: String, value: Decimal)] = bgTargets.targets
            .map { ($0.start.trimmingCharacters(in: .whitespacesAndNewlines), $0.low) }

        for (index, entry) in entries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                debug(.default, "Invalid entry start time: \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            guard let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second!,
                of: now
            ) else { continue }

            let entryEndTime: Date
            if index < entries.count - 1, let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start) {
                let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                entryEndTime = calendar.date(
                    bySettingHour: nextEntryComponents.hour!,
                    minute: nextEntryComponents.minute!,
                    second: nextEntryComponents.second!,
                    of: now
                )!
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                return entry.value
            }
        }

        return nil
    }

    // MARK: - Configure ContactImageState in order to update ContactImageImage

    /// Updates the `ContactImageState` with the latest data from Core Data.
    /// This function fetches glucose values and determination entries, processes the data,
    /// and updates the `state` object, which represents the current contact trick state.
    /// - Important: This function must be called on the main actor to ensure thread safety. Otherwise, we would need to ensure thread safety by either using an actor or a perform closure
    @MainActor func updateContactImageState() async {
        do {
            // Get NSManagedObjectIDs on backgroundContext
            let glucoseValuesIds = try await fetchGlucose()
            let determinationIds = try await fetchlastDetermination()

            // Get NSManagedObjects on MainActor
            let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: glucoseValuesIds, context: viewContext)
            let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared
                .getNSManagedObject(with: determinationIds, context: viewContext)
            let lastDetermination = determinationObjects.last

            if let firstGlucoseValue = glucoseObjects.first {
                let value = settingsManager.settings.units == .mgdL
                    ? Decimal(firstGlucoseValue.glucose)
                    : Decimal(firstGlucoseValue.glucose).asMmolL

                state.glucose = Formatter.glucoseFormatter(for: units).string(from: value as NSNumber)
                state.glucoseDate = firstGlucoseValue.date
                state.trend = firstGlucoseValue.directionEnum?.symbol
                state.direction = firstGlucoseValue.directionEnum

                let delta = glucoseObjects.count >= 2
                    ? Decimal(firstGlucoseValue.glucose) - Decimal(glucoseObjects.dropFirst().first?.glucose ?? 0)
                    : 0
                let deltaConverted = settingsManager.settings.units == .mgdL ? delta : delta.asMmolL
                state.delta = deltaFormatter.string(from: deltaConverted as NSNumber)
            } else {
                // fetchGlucose() only looks back 20 minutes, so an empty result means dropout.
                state.glucose = nil
                state.trend = nil
                state.direction = nil
                state.glucoseDate = nil
                state.delta = nil
            }

            // Drive the loop ring from the same source as the app's loop pill
            // (`apsManager.lastLoopDate`), not the determination's `timestamp`, which
            // is only stamped on enacted (closed-loop) determinations and so lags or
            // never updates in open loop. `.distantPast` means "no loop yet" -> nil,
            // so the ring shows gray rather than a spurious stale-red.
            let loopDate = apsManager.lastLoopDate
            state.lastLoopDate = loopDate == .distantPast ? nil : loopDate

            // The other two inputs `LoopFreshness` needs in order to agree with the
            // Home loop pill.
            //
            // Note these are read here and nowhere else, so the staleness timer's
            // pre-check cannot see either of them change — it compares against this
            // cached `state`. Closed loop is therefore given its own render trigger
            // via `settingsDidChange`, matching the pill, which refreshes from the
            // same broadcast. A manual temp basal has no dedicated trigger: it is
            // only reachable in closed loop (the Home affordance is gated on
            // `!closedLoop`, and `LoopFreshness` returns `.openLoop` first either
            // way), so it is rare enough to leave to the next data-driven render.
            // `closedLoop` here means "the loop is driving delivery". Since dosing modes (#1511)
            // that is any mode that enacts, the same rule upstream's `NotLoopingMonitor` uses,
            // so Low Glucose Suspend and Basal Testing count; only Open does not.
            state.closedLoop = settingsManager.settings.dosingMode.automation != .off
            state.manualTempBasal = apsManager.isManualTempBasal

            let iobValue = iobService.currentIOB ?? 0.0
            state.iob = iobValue
            state.iobText = Formatter.decimalFormatterWithOneFractionDigit.string(from: iobValue as NSNumber)

            // we need to do it complex and unelegant, otherwise unwrapping and parsing of cob results in 0
            if let cobValue = lastDetermination?.cob {
                state.cob = Decimal(cobValue)
                state.cobText = Formatter.integerFormatter.string(from: Int(cobValue) as NSNumber)

            } else {
                state.cob = 0
                state.cobText = "0"
            }

            if let eventualBG = settingsManager.settings.units == .mgdL ? lastDetermination?
                .eventualBG : lastDetermination?
                .eventualBG?.decimalValue.asMmolL as NSDecimalNumber?
            {
                let eventualBGAsString = Formatter.decimalFormatterWithOneFractionDigit.string(from: eventualBG)
                state.eventualBG = eventualBGAsString.map { "⇢ " + $0 }
            }

            // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
            let hardCodedLow = Decimal(55)
            let hardCodedHigh = Decimal(220)
            let isDynamicColorScheme = settingsManager.settings.glucoseColorScheme == .dynamicColor
            let highGlucoseColorValue = isDynamicColorScheme ? hardCodedHigh : settingsManager.settings.high
            let lowGlucoseColorValue = isDynamicColorScheme ? hardCodedLow : settingsManager.settings.low
            let fetchedTarget = await getCurrentGlucoseTarget() // ⚠️ this value is mg/dL

            state.highGlucoseColorValue = units == .mgdL ? highGlucoseColorValue : highGlucoseColorValue.asMmolL
            state.lowGlucoseColorValue = units == .mgdL ? lowGlucoseColorValue : lowGlucoseColorValue.asMmolL
            state.targetGlucose = units == .mgdL ? fetchedTarget ?? Decimal(100) : fetchedTarget?.asMmolL ?? 100.asMmolL
            state.glucoseColorScheme = settingsManager.settings.glucoseColorScheme

            // Notify delegate about state update on main thread
            await MainActor.run {
                delegate?.contactImageManagerDidUpdateState(state)
            }
        } catch {
            // Still notify delegate with current state, even if there was an error
            delegate?.contactImageManagerDidUpdateState(state)
        }
    }

    // MARK: - Interactions with CNContactStore API

    /// Checks if the app has access to the user's contacts.
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Sets the image for a specific contact in Apple Contacts.
    /// This function fetches the associated `ContactImageEntry` for the provided contact ID, generates an image
    /// based on the current `ContactImageState`, and updates the contact in the user's Apple Contacts.
    /// - Parameter contactId: The unique identifier of the contact in Apple Contacts.
    /// - Important: This function should be called when a new contact is created and needs its initial image set.
    func setImageForContact(contactId: String) async {
        guard let contactEntry = await contactImageStorage.fetchContactImageEntries().first(where: { $0.contactId == contactId })
        else {
            debugPrint("\(DebuggingIdentifiers.failed) No matching ContactImageEntry found for contact ID: \(contactId)")
            return
        }

        // Create image based on current state
        let newImage = await ContactPicture.getImage(contact: contactEntry, state: state)

        do {
            let predicate = CNContact.predicateForContacts(withIdentifiers: [contactId])
            let contacts = try contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactImageDataKey as CNKeyDescriptor
                ]
            )

            guard let contact = contacts.first else {
                debugPrint("\(DebuggingIdentifiers.failed) Contact with ID \(contactId) not found.")
                return
            }

            let mutableContact = contact.mutableCopy() as! CNMutableContact
            mutableContact.imageData = newImage.pngData()

            let saveRequest = CNSaveRequest()
            saveRequest.update(mutableContact)

            try contactStore.execute(saveRequest)

            debugPrint("\(DebuggingIdentifiers.succeeded) Image successfully set for contact ID: \(contactId)")
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to set image for contact ID \(contactId): \(error)")
        }
    }

    /// Updates the images of all contacts stored in Core Data.
    /// This function iterates through all stored `ContactImageEntry` objects, generates a new contact image
    /// based on the current `ContactImageState`, and updates the image in the user's Apple Contacts.
    /// - Important: Only call this from the serialized render pipeline
    ///   (`enqueueRender`), so no two renders interleave and the contact store
    ///   always ends up holding the newest snapshot. The shared `state` and
    ///   `lastRenderedStaleness` are read/committed on the main actor, while the
    ///   heavy image render and blocking `CNContactStore` I/O stay off the main
    ///   thread.
    func updateContactImages() async {
        // Take a background task assertion so that when this runs on a brief
        // background wake (e.g. a CGM BLE delivery), iOS grants enough time to
        // finish the render + CNContactStore write instead of suspending us
        // mid-flight and leaving a half-updated or stale image baked in. In the
        // foreground this is effectively a no-op.
        let backgroundTaskID = await MainActor.run { startBackgroundTask(withName: "Update Contact Images") }

        await renderAndWriteContactImages()

        // Release the background task assertion now the render + writes are done.
        await MainActor.run {
            var id = backgroundTaskID
            endBackgroundTaskSafely(&id, taskName: "Update Contact Images")
        }
    }

    /// Whether `CNContactStore` writes can currently succeed.
    ///
    /// `.denied`, `.restricted` and `.notDetermined` all fail *permanently* until
    /// the user changes the setting in Settings, so re-rendering into them on every
    /// tick burns work that cannot possibly land — see the gate in
    /// `renderAndWriteContactImages()`.
    private var hasContactsWriteAccess: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        // Limited access (iOS 18+) still permits writing the contacts the user picked.
        if #available(iOS 18.0, *), status == .limited { return true }
        return false
    }

    /// The render itself. Split out of `updateContactImages()` so the background
    /// task assertion has a single acquire/release pair around every exit path.
    private func renderAndWriteContactImages() async {
        // Snapshot the render inputs on the main actor: a consistent copy of
        // `state` plus the staleness we are about to render.
        let (stateSnapshot, renderedStaleness) = await MainActor.run {
            (state, RenderStaleness.current(for: state))
        }

        let contactEntries = await contactImageStorage.fetchContactImageEntries()

        // Nothing this pass could possibly write: the user has no contact images
        // configured, or Contacts access is not granted. Close the staleness gate
        // regardless.
        //
        // Leaving it open was a slow leak of work. `lastRenderedStaleness` would
        // stay `nil` forever, so the timer's pre-check (`current != nil`) reported a
        // change on *every* tick, and each tick ran a full `updateContactImageState()`
        // — two Core Data fetches, two main-actor materialisations and a file read of
        // `bgTargets` — plus this entry fetch, on every tick, indefinitely, for a user
        // who never set up a contact image at all.
        //
        // Closing it costs nothing, because neither case relies on the staleness
        // timer to recover: adding or editing a contact image writes its picture
        // immediately via `setImageForContact`, and every data-driven render is
        // `.full`, which bypasses this gate entirely.
        guard !contactEntries.isEmpty, hasContactsWriteAccess else {
            await MainActor.run { lastRenderedStaleness = renderedStaleness }
            return
        }

        // True once any contact holds this render — written now, or skipped because it
        // already held these exact bytes (CONTACT-CYCLE).
        var didUpdateAnyContact = false

        // Iterate through all stored ContactImageEntry objects
        for contactEntry in contactEntries {
            // Ensure the contact has a valid contact ID
            guard let contactId = contactEntry.contactId else { continue }

            // Generate a new image for the contact based on the snapshotted state.
            // `getImage` is main-actor isolated (SwiftUI `View`), so the `await`
            // hops to the main thread for the render only; the CNContactStore I/O
            // below stays off it.
            let newImage = await ContactPicture.getImage(contact: contactEntry, state: stateSnapshot)
            let pngData = newImage.pngData()

            do {
                // Fetch the existing contact from CNContactStore using its identifier
                let predicate = CNContact.predicateForContacts(withIdentifiers: [contactId])
                let contacts = try contactStore.unifiedContacts(
                    matching: predicate,
                    keysToFetch: [
                        CNContactIdentifierKey as CNKeyDescriptor, // To identify the contact
                        CNContactImageDataKey as CNKeyDescriptor // To fetch current image data
                    ]
                )

                // Ensure the contact exists in the CNContactStore
                guard let contact = contacts.first else {
                    debugPrint(
                        "\(DebuggingIdentifiers.failed) Contact with ID \(contactId) and name \(contactEntry.name) not found."
                    )
                    continue
                }

                // CONTACT-CYCLE: the contact already holds exactly these bytes, so the save
                // would change nothing but still wake contactsd, iCloud and the Watch.
                //
                // Compared against the store itself, not a record of what we last wrote.
                // Contacts hands back the exact bytes it was given — 527 of 527 on device,
                // 2026-09-30 — so this survives a relaunch, and a photo changed or cleared
                // outside Trio differs here and is rewritten, so returning to the app
                // still repairs it without a forced write.
                if let pngData, contact.imageData == pngData {
                    didUpdateAnyContact = true
                    continue
                }

                // Create a mutable copy of the contact to update its image
                let mutableContact = contact.mutableCopy() as! CNMutableContact
                mutableContact.imageData = pngData // Set the new image data

                // Prepare a save request to update the contact
                let saveRequest = CNSaveRequest()
                saveRequest.update(mutableContact)

                // Execute the save request to persist the changes
                try contactStore.execute(saveRequest)
                didUpdateAnyContact = true

                debugPrint("\(DebuggingIdentifiers.succeeded) Updated contact image for \(contactId)")
            } catch {
                debugPrint("\(DebuggingIdentifiers.failed) Failed to update contact image for \(contactId): \(error)")
            }
        }

        // Commit the gate only after a write actually landed, so a transient
        // CNContactStore failure leaves the periodic staleness timer free to retry
        // on the next tick. (A pass with nothing to write returns early above.)
        // Written on the main actor to stay serialized with the timer's read.
        if didUpdateAnyContact {
            await MainActor.run { lastRenderedStaleness = renderedStaleness }
        }
    }

    /// Creates a new contact in the Apple contact list or updates an existing one with the same name.
    /// - Parameter name: The name of the contact.
    /// - Returns: The `identifier` of the created/updated contact, or `nil` if an error occurs.
    func createContact(name: String) async -> String? {
        do {
            // First check if a contact with this name already exists
            let predicate = CNContact.predicateForContacts(matchingName: name)
            let existingContacts = try contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor
                ]
            )

            // If contact exists, return its identifier
            if let existingContact = existingContacts.first {
                debugPrint("Found existing contact with name: \(name)")
                return existingContact.identifier
            }

            // If no existing contact, create a new one
            let contact = CNMutableContact()
            contact.givenName = name

            let saveRequest = CNSaveRequest()
            saveRequest.add(contact, toContainerWithIdentifier: nil)

            try contactStore.execute(saveRequest)

            // Re-fetch to get the identifier
            let newContacts = try contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )

            guard let createdContact = newContacts.first else {
                debugPrint("\(DebuggingIdentifiers.failed) Contact creation failed: No contact found after save.")
                return nil
            }

            return createdContact.identifier
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Error creating/finding contact: \(error)")
            return nil
        }
    }

    /// Validates if a contact still exists in iOS Contacts.
    func validateContactExists(withIdentifier identifier: String) async -> Bool {
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
        let keys = [CNContactIdentifierKey] as [CNKeyDescriptor]

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            return !contacts.isEmpty
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Error validating contact: \(error)")
            return false
        }
    }

    /// Deletes a contact from the Apple contact list using its `identifier`.
    /// - Parameter identifier: The unique identifier of the contact.
    /// - Returns: `true` if the contact was successfully deleted, `false` otherwise.
    func deleteContact(withIdentifier identifier: String) async -> Bool {
        do {
            // Attempt to find the contact using its identifier.
            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let contacts = try contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )

            guard let contact = contacts.first else {
                debugPrint("\(DebuggingIdentifiers.failed) Contact with ID \(identifier) not found.")
                return false
            }

            // Contact found -> Delete it.
            let mutableContact = contact.mutableCopy() as! CNMutableContact
            let deleteRequest = CNSaveRequest()
            deleteRequest.delete(mutableContact)

            try contactStore.execute(deleteRequest)
            debugPrint("\(DebuggingIdentifiers.succeeded) Contact successfully deleted: \(identifier)")
            return true
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Error deleting contact: \(error)")
            return false
        }
    }

    /// Updates an existing contact in the Apple contact list.
    /// - Parameters:
    ///   - identifier: The unique identifier of the contact.
    ///   - newName: The new name to assign to the contact.
    /// - Returns: `true` if the contact was successfully updated, `false` otherwise.
    func updateContact(withIdentifier identifier: String, newName: String) async -> Bool {
        do {
            // Search for the contact using its `identifier`.
            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let contacts = try contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor
                ]
            )

            guard let contact = contacts.first else {
                debugPrint("\(DebuggingIdentifiers.failed) Contact with ID \(identifier) not found.")
                return false
            }

            // Update the contact.
            let mutableContact = contact.mutableCopy() as! CNMutableContact
            mutableContact.givenName = newName

            let updateRequest = CNSaveRequest()
            updateRequest.update(mutableContact)

            try contactStore.execute(updateRequest)
            debugPrint("\(DebuggingIdentifiers.succeeded) Contact successfully updated: \(identifier)")
            return true
        } catch {
            debugPrint("\(DebuggingIdentifiers.failed) Error updating contact: \(error)")
            return false
        }
    }
}

// MARK: - Settings

extension BaseContactImageManager: SettingsObserver {
    /// Re-render on any settings change.
    ///
    /// Closed loop is the one that matters for mirroring the Home loop pill: the pill
    /// repaints from this same broadcast, so without this the ring would keep showing
    /// green/amber/red for a loop that is no longer driving until the next data event
    /// happened to arrive — up to a full loop cycle later.
    ///
    /// It is deliberately not narrowed to `closedLoop`. Units, the glucose colour
    /// scheme and the high/low thresholds are all baked into the rendered image too,
    /// and none of them had a trigger before either.
    func settingsDidChange(_ settings: TrioSettings) {
        units = settings.units
        enqueueRender(.full)
    }
}
