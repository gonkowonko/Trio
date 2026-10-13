import ActivityKit
import Combine
import CoreData
import Foundation
import LoopKit
import LoopKitUI
import Swinject
import UIKit

@available(iOS 16.2, *) private struct ActiveActivity {
    let activity: Activity<LiveActivityAttributes>

    /// Determines if the current activity needs to be recreated.
    ///
    /// - Returns: `true` if the activity is dismissed, ended, stale, or has been active for more than 60 minutes; otherwise,
    /// `false`.
    func needsRecreation() -> Bool {
        switch activity.activityState {
        case .dismissed,
             .ended,
             .stale:
            return true
        case .active:
            break
        @unknown default:
            return true
        }
        return -activity.attributes.startDate.timeIntervalSinceNow > TimeInterval(60 * 60)
    }
}

final class LiveActivityData: ObservableObject {
    /// Determination data used to update live activity state.
    @Published var determination: DeterminationData?
    /// The most recent IoB data
    @Published var iob: Decimal?
    /// Array of glucose readings fetched from persistent storage.
    @Published var glucoseFromPersistence: [GlucoseData]?
    /// The current override data (if any).
    @Published var override: OverrideData?
    /// The current temp target data (if any).
    @Published var tempTarget: TempTargetData?
    /// The widget items displayed within the live activity.
    @Published var widgetItems: [LiveActivityAttributes.LiveActivityItem]?
}

/// A service managing live activity updates and state management.
///
/// This class handles the creation, update, and termination of live activities based on various data sources
/// (e.g. Core Data notifications, glucose updates, settings changes). It integrates with system notifications,
/// dependency injection, and user defaults to ensure that the live activity reflects the current app state.
///
/// Additionally, it supports a restart functionality (via `restartActivityFromLiveActivityIntent()`)
/// via iOS shortcuts, similar to other iOS apps like xDrip4iOS or Sweet Dreams.
@available(iOS 16.2, *) final class LiveActivityManager: Injectable, ObservableObject, SettingsObserver,
    BasalProfileObserver
{
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!
    @Injected() private var apsManager: APSManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var deviceDataManager: DeviceDataManager!

    private let activityAuthorizationInfo = ActivityAuthorizationInfo()
    /// Indicates whether system live activities are enabled.
    @Published private(set) var systemEnabled: Bool

    /// Returns the current Trio settings.
    private var settings: TrioSettings {
        settingsManager.settings
    }

    /// The current active live activity.
    private var currentActivity: ActiveActivity?

    /// One-shot refresh armed for the next loop-severity boundary. Replaced on every
    /// push, so at most one is ever pending. See `scheduleLoopSeverityRefresh`.
    private var loopSeverityRefreshTask: Task<Void, Never>?

    /// LA-BG-STALENESS: one-shot refresh armed for the moment the newest reading turns
    /// 12 minutes old. See `scheduleReadingExpiryRefresh`.
    private var readingExpiryRefreshTask: Task<Void, Never>?

    /// LA-BASAL-CACHE: the basal profile, held in memory for the basal tile's scheduled
    /// rate. `scheduledBasalRate()` used to read and decode `basal_profile.json` on
    /// every `pushCurrentContent()` — synchronously, on the main actor, and before the
    /// LA-COALESCE dedupe, so even skipped pushes paid for it.
    ///
    /// Refreshed by `BasalProfileObserver` when the editor saves, and on every
    /// foreground/background transition, because Autotune and Onboarding also write
    /// the file and neither broadcasts. Both run in the app, so the next transition
    /// catches them before the lock screen is seen. Main thread only.
    private var basalProfile: [BasalProfileEntry]?

    // LA-COALESCE: what was last handed to ActivityKit, so an identical push can
    // be skipped. `ContentState` is already `Hashable`.
    //
    // Safe against the display going stale two ways over. `staleDate` is derived
    // from `state.date` rather than `Date.now`, so an identical state yields an
    // identical staleDate and skipping loses nothing. And the rolling labels —
    // "looped 3 m ago", the reading age, the freshness masking — are recomputed
    // when the *system* re-renders the view, which the logs show happens
    // independently of our pushes (only 8 of 2230 push gaps fell near 60s, yet
    // the labels tick every minute on device).
    //
    // Time-bounded regardless, as a belt: past this window an identical state is
    // pushed anyway, so nothing can freeze for longer than it. The longest burst
    // observed in a full day was 53s.
    private var lastPushedState: LiveActivityAttributes.ContentState?
    private var lastPushedAt: Date?
    private static let redundantPushWindow: TimeInterval = 60

    /// LA-LOOP-WAIT: a new reading starts a cycle that changes the banner several times
    /// in ~10s — the reading, the pump status, the suggested determination and IOB, then
    /// the loop's enacted result. Each went out as its own push: 2.8 per reading on
    /// 2026-10-01, never fewer than 2, and only the last one is what the cycle settled
    /// on. So from a new reading until the loop lands, ordinary pushes are held and the
    /// cycle goes out once, `loopWaitSettle` after the loop.
    ///
    /// The reading is delayed by that wait: the loop lands a median 7s after it (p90 9s,
    /// max 25s over 296 cycles), so ~12s in all. `loopWaitFallback` caps it if the loop
    /// fails or never runs. Forced pushes (the reading-expiry refresh) are never held.
    ///
    /// Not a debounce: the flush is a deadline that only moves earlier, and a background
    /// task is held while it is armed, so suspension cannot lose it — the failure that
    /// sank the 6s debounce (see the `objectWillChange` throttle). Main actor only.
    private var loopWaitDeadline: Date?
    private var loopWaitTask: Task<Void, Never>?
    private var loopWaitBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Enacted determination and IOB arrive through 2s debounces after the loop, ~1–3s.
    private static let loopWaitSettle: TimeInterval = 5
    private static let loopWaitFallback: TimeInterval = 30

    private var data = LiveActivityData()

    /// A dispatch queue for handling Core Data change notifications.
    private let queue = DispatchQueue(label: "LiveActivityBridge.queue", qos: .userInitiated)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Initializes a new instance of `LiveActivityBridge` and sets up observers, subscribers, and notifications.
    ///
    /// - Parameter resolver: The dependency injection resolver.
    init(resolver: Resolver) {
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        systemEnabled = activityAuthorizationInfo.areActivitiesEnabled
        injectServices(resolver)
        setupNotifications()
        registerHandler()
        monitorForLiveActivityAuthorizationChanges()
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(BasalProfileObserver.self, observer: self) // LA-BASAL-CACHE
        reloadBasalProfile() // LA-BASAL-CACHE
        // LA-COALESCE: `LiveActivityData` publishes six properties independently,
        // and `objectWillChange` fires once per assignment — so one refresh cycle
        // sent up to six full ActivityKit updates. Logs for 2026-08-15 show 2231
        // pushes against 286 glucose readings, in 278 bursts averaging 8 each.
        //
        // `throttle`, emphatically not `debounce`. Debounce waits for silence
        // before it emits, and the work that feeds this runs inside a bounded
        // background task (`FetchGlucoseManager`'s "Glucose Store and Heartbeat
        // Decision"). A 6s debounce was tried and it left the banner a whole
        // glucose cycle behind the app: if the task ended or iOS suspended the
        // process inside the quiet window, the emission never fired and the push
        // was lost until something else — usually the user opening the app —
        // triggered one. On a display showing glucose that is the wrong trade
        // however many pushes it saves.
        //
        // Throttle emits the *first* change immediately, so a new reading
        // reaches the banner at once, then collapses the rest of the burst to at
        // most one push per window. Latency is zero where it matters and the
        // rate is still bounded.
        //
        // **Widening this window does almost nothing — measured, not reasoned.**
        // 12s ran for a day (2026-09-08/09) on a prediction that it would take
        // 36.4 pushes/hr down to ~17. It gave 33.8/hr: a 5% cut, not 55%.
        //
        // The prediction came from replaying a day of observed push timestamps
        // against wider windows, which silently assumed every push arrives
        // through *this* publisher. Most do not — the `MergeMany` pipeline in
        // `registerHandler()` and the lifecycle observers in
        // `setupNotifications()` call `pushCurrentContent()` directly and never
        // touch this throttle. Widening it only squeezes a minority inlet.
        //
        // It does bite on what it governs: median intra-burst gap moved 6s -> 9s
        // and sub-12s gaps 93% -> 71%. That partial signature is exactly what a
        // throttle looks like when most of the traffic flows past it.
        //
        // **So do not re-derive a window size from push counts in the logs** —
        // they are not all from here. If pushes ever genuinely need cutting, the
        // lever is those bypassing call sites, not this number. And there is no
        // energy case either way: the 2026-09-08 budget put the entire saving at
        // ~0.03% of a battery.
        //
        // Back at 6s because the cost is real and one-sided. The first change
        // still goes out immediately, so a new glucose reading is never delayed,
        // but a correction arriving later in the same cycle — determination,
        // IOB, the basal tile — waits out the window. That is the shape of the
        // 2026-08-22 basal staleness bug.
        //
        // One loose end: iOS stopped reporting "The Trio widget updated
        // frequently" while 12s was in, having reported it at 36.4/hr. Neither
        // the hourly rate (33.8 vs 36.4) nor burst density explains that — same
        // -second pushes and peak-per-minute both got *worse*. Unexplained, and
        // n=1 against a heuristic that may not be deterministic. Gary is
        // re-testing at 6s to see whether it comes back.
        data.objectWillChange
            .throttle(for: .seconds(6), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                Task { @MainActor in
                    // by the time this runs, the object change is done, so we see the new data here
                    await self?.pushCurrentContent()
                }
            }.store(in: &subscriptions)
        loadInitialData()
    }

    /// Sets up application notifications that trigger live activity updates when the app state changes.
    private func setupNotifications() {
        let notificationCenter = Foundation.NotificationCenter.default
        notificationCenter
            .addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.reloadBasalProfile() // LA-BASAL-CACHE
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter
            .addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.reloadBasalProfile() // LA-BASAL-CACHE
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter.addObserver(
            self,
            selector: #selector(loadWidgetItems),
            name: .liveActivityOrderDidChange,
            object: nil
        )
    }

    /// Called when the app settings change.
    ///
    /// This method triggers an update to the live activity content state based on the new settings.
    /// - Parameter _: The updated `TrioSettings`.
    func settingsDidChange(_: TrioSettings) {
        Task { @MainActor in
            await self.pushCurrentContent()
        }
    }

    /// LA-BASAL-CACHE: the editor saved a new profile. It is handed over directly, so
    /// no file read is needed.
    func basalProfileDidChange(_ basalProfile: [BasalProfileEntry]) {
        self.basalProfile = basalProfile
        Task { @MainActor in
            await self.pushCurrentContent()
        }
    }

    /// LA-BASAL-CACHE: the only place the basal profile file is read.
    private func reloadBasalProfile() {
        basalProfile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
    }

    /// Registers handlers for Core Data changes related to overrides, glucose readings, and determinations.
    private func registerHandler() {
        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            Task { await self?.loadOverrides() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            Task { await self?.loadTempTarget() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            Task { await self?.loadGlucose() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OrefDetermination")
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                Task { await self?.loadDetermination() }
            }.store(in: &subscriptions)

        iobService.iobPublisher
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.data.iob = self?.iobService.currentIOB
            }.store(in: &subscriptions)

        // Pump and CGM state changes touch none of the data above, so without
        // this the basal tile, loop dot and device rows stay frozen at whatever
        // they were when some *other* value last changed. Suspending delivery
        // is the clearest case: nothing else moves, so nothing would repaint.
        // LA-COALESCE: `removeDuplicates()` before the `map` to Void, not after.
        // `pumpExpiresAtDate` and `cgmDisplayState` are `CurrentValueSubject`s,
        // which republish on every assignment whether the value changed or not —
        // and `publishCGMStatus()` reassigns a freshly constructed, identical
        // `CgmDisplayState` on every CGM read callback. Mapping to `()` first
        // discards the value, making the redundancy impossible to detect
        // downstream. All five payloads are Equatable, so this is free.
        // LA-COALESCE exception: `suspended` and `scheduledBasal` deliberately
        // keep their duplicates. `DeviceDataManager` fires one of them on every
        // pump status update, so they are the only signal that the *enacted*
        // basal rate changed — a temp going 0.4 -> 0 flips neither boolean.
        // De-duplicating them left the basal tile a full cycle behind the pump,
        // which is half of the 2026-08-22 wrong-rate bug (see
        // `currentBasalStatus`). Redundant pushes are still suppressed, just
        // later: `pushUpdate`'s identical-`ContentState` check drops them before
        // they reach ActivityKit, so the cost of the duplicates here is
        // rebuilding a struct in-process, not a push.
        Publishers.MergeMany(
            deviceDataManager.suspended.map { _ in () }.eraseToAnyPublisher(),
            deviceDataManager.scheduledBasal.map { _ in () }.eraseToAnyPublisher(),
            deviceDataManager.manualTempBasal.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            deviceDataManager.pumpExpiresAtDate.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            fetchGlucoseManager.cgmDisplayState.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .seconds(1), scheduler: DispatchQueue.global(qos: .utility))
        .sink { [weak self] in
            Task { @MainActor in
                await self?.pushCurrentContent()
            }
        }.store(in: &subscriptions)

        // LA-LOOP-WAIT: the loop landed, so the held cycle can go out once it settles.
        apsManager.lastLoopDateSubject
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.armLoopWaitFlush(in: Self.loopWaitSettle, reason: "loop")
                }
            }.store(in: &subscriptions)

        // LA-LOOP-WAIT: a failed loop is just as finished, but `lastLoopDateSubject` only
        // fires on success. Without this, every cycle under a manual temp basal sat out
        // the whole fallback (7 on 2026-10-02, 16:01–16:31). `nil` is the success reset;
        // `dropFirst` skips the subject's replay of the last error on subscribe.
        apsManager.lastError
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.armLoopWaitFlush(in: Self.loopWaitSettle, reason: "loop failed")
                }
            }.store(in: &subscriptions)
    }

    /// LA-LOOP-WAIT: opens the hold for a new reading. A reading arriving while one is
    /// already open (a backfill a second later) changes nothing.
    @MainActor private func openLoopWait() {
        guard loopWaitDeadline == nil else { return }
        loopWaitDeadline = .distantFuture
        armLoopWaitFlush(in: Self.loopWaitFallback, reason: "fallback")

        // The loop can beat the Core Data round trip here: 10% of cycles on 2026-10-01
        // looped within 1s of the reading. Its signal has then already gone by, so settle
        // from it now rather than sit out the fallback. The previous cycle's loop is
        // minutes old and never matches.
        let loopAge = -apsManager.lastLoopDate.timeIntervalSinceNow
        if loopAge < Self.loopWaitFallback {
            armLoopWaitFlush(in: max(0, Self.loopWaitSettle - loopAge), reason: "loop, before reading")
        }
    }

    /// LA-LOOP-WAIT: flushes the hold `delay` from now, unless it is already due sooner.
    /// Does nothing when no hold is open, so a loop outside a cycle pushes as before.
    @MainActor private func armLoopWaitFlush(in delay: TimeInterval, reason: String) {
        let deadline = Date().addingTimeInterval(delay)
        guard let open = loopWaitDeadline, deadline < open else { return }

        loopWaitTask?.cancel()
        loopWaitDeadline = deadline
        if loopWaitBackgroundTask == .invalid {
            loopWaitBackgroundTask = startBackgroundTask(withName: "Live Activity Loop Wait")
        }

        loopWaitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // Replaced by a sooner flush, which now owns the background task.
            guard !Task.isCancelled, let self else { return }
            await self.flushLoopWait(reason: reason)
        }
    }

    /// LA-LOOP-WAIT: closes the hold and pushes the settled cycle.
    @MainActor private func flushLoopWait(reason _: String) async {
        loopWaitDeadline = nil
        loopWaitTask = nil
        await pushCurrentContent()
        // A hold opened while that push was in flight inherits the assertion.
        if loopWaitDeadline == nil {
            endBackgroundTaskSafely(&loopWaitBackgroundTask, taskName: "Live Activity Loop Wait")
        }
    }

    /// Fetches and maps new determination data and updates the live activity content state.
    private func loadDetermination() async {
        do {
            data.determination = try await fetchAndMapDetermination()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map determination: \(error)"
            )
        }
    }

    /// Fetches and maps override data and updates the live activity content state.
    private func loadOverrides() async {
        do {
            data.override = try await fetchAndMapOverride()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map override: \(error)")
        }
    }

    /// Fetches and maps temp target data and updates the live activity content state.
    private func loadTempTarget() async {
        do {
            data.tempTarget = try await fetchAndMapTempTarget()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map temp target: \(error)")
        }
    }

    /// Handles changes to the live activity order.
    ///
    /// Loads widget items from user defaults and triggers an update to the live activity order.
    @objc private func loadWidgetItems() {
        data.widgetItems = UserDefaults.standard.loadLiveActivityOrderFromUserDefaults() ?? LiveActivityAttributes
            .LiveActivityItem.defaultItems
    }

    /// Sets up the array of glucose data from persistent storage and triggers an update to the live activity.
    private func loadGlucose() async {
        do {
            let glucose = try await fetchAndMapGlucose()
            // LA-LOOP-WAIT: open the hold *before* publishing, so the throttled push this
            // assignment triggers already finds it. Only for a newer, current reading:
            // not the first load, a backfill of old values, or an edit or deletion.
            if let previous = data.glucoseFromPersistence?.map(\.date).max(),
               let newest = glucose.map(\.date).max(), newest > previous,
               -newest.timeIntervalSinceNow < 5 * 60
            {
                await openLoopWait()
            }
            data.glucoseFromPersistence = glucose
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch glucose with error: \(error)"
            )
        }
    }

    private func loadInitialData() {
        Task {
            await self.loadGlucose()
            await self.loadOverrides()
            await self.loadTempTarget()
            await self.loadDetermination()
            self.loadWidgetItems()
        }
    }

    /// Monitors live activity authorization changes and updates the `systemEnabled` flag.
    private func monitorForLiveActivityAuthorizationChanges() {
        Task {
            for await activityState in activityAuthorizationInfo.activityEnablementUpdates {
                if activityState != systemEnabled {
                    await MainActor.run {
                        systemEnabled = activityState
                    }
                }
            }
        }
    }

    /// Pushes an update to the live activity with the specified content state.
    ///
    /// If an existing activity requires recreation or is outdated, this method ends it and starts a new one.
    /// Otherwise, it updates the current live activity.
    ///
    /// - Parameters:
    ///   - state: The new content state to push to the live activity.
    ///   - force: LA-BG-STALENESS: push even when `state` matches the last push. For a
    ///     scheduled refresh whose whole purpose is a redraw — the view's draw-time checks
    ///     change what it shows without the state changing at all.
    @MainActor private func pushUpdate(_ state: LiveActivityAttributes.ContentState, force: Bool = false) async {
        if !settings.useLiveActivity || !systemEnabled {
            await endActivity()
            return
        }

        if currentActivity == nil {
            // try to restore an existing activity
            currentActivity = Activity<LiveActivityAttributes>.activities
                .max { $0.attributes.startDate < $1.attributes.startDate }.map {
                    ActiveActivity(activity: $0)
                }

            if let currentActivity {
                debug(.default, "[LiveActivityManager] Restored live activity: \(currentActivity.activity.id)")
            }
        }

        // End all unknown activities except the current one
        for unknownActivity in Activity<LiveActivityAttributes>.activities
            .filter({ self.currentActivity?.activity.id != $0.id })
        {
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        if let currentActivity {
            if currentActivity.needsRecreation(), UIApplication.shared.applicationState == .active {
                debug(.default, "[LiveActivityManager] Ending current activity for recreation: \(currentActivity.activity.id)")
                await endActivity()
                // After endActivity(), currentActivity is guaranteed to be nil
                // No recursive task, but explicitly restart
                debug(.default, "[LiveActivityManager] Re-pushing update after recreation.")
                await pushUpdate(state, force: force)
            } else {
                let content = ActivityContent(
                    state: state,
                    staleDate: min(state.date ?? Date.now, Date.now).addingTimeInterval(360)
                )
                // LA-COALESCE: nothing on screen would differ, and we pushed
                // recently — skip rather than wake the widget extension again.
                if !force, let lastPushedState, lastPushedState == state,
                   let lastPushedAt, Date.now.timeIntervalSince(lastPushedAt) < Self.redundantPushWindow
                {
                    debug(.default, "[LiveActivityManager] Skipped redundant update: state unchanged")
                    return
                }

                // Before the update, check if currentActivity is still valid
                if let stillCurrent = self.currentActivity, stillCurrent.activity.id == currentActivity.activity.id {
                    debug(.default, "[LiveActivityManager] Updating current activity: \(stillCurrent.activity.id)")
                    await stillCurrent.activity.update(content)
                    // LA-COALESCE
                    lastPushedState = state
                    lastPushedAt = Date.now
                } else {
                    debug(.default, "[LiveActivityManager] Skipped update: currentActivity changed during pushUpdate.")
                }
            }
        } else {
            // ... Activity is newly created ...
            do {
                let expired = ActivityContent(
                    state: LiveActivityAttributes
                        .ContentState(
                            unit: settings.units.rawValue,
                            bg: "--",
                            direction: nil,
                            change: "--",
                            date: Date.now,
                            highGlucose: settings.high,
                            lowGlucose: settings.low,
                            target: data.determination?.target ?? 100 as Decimal,
                            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
                            lockScreenStyleIOS: .simple,
                            lockScreenStyleWatchOS: .simple,
                            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                                chart: [],
                                rotationDegrees: 0,
                                cob: 0,
                                iob: 0,
                                tdd: 0,
                                isOverrideActive: false,
                                overrideName: "",
                                overrideDate: Date.now,
                                overrideDuration: 0,
                                overrideTarget: 0,
                                isTempTargetActive: false,
                                tempTargetName: "",
                                tempTargetDate: Date.now,
                                tempTargetDuration: 0,
                                tempTargetTarget: 0,
                                widgetItems: [],
                                minForecast: [],
                                maxForecast: [],
                                forecastLines: [],
                                forecastDisplayType: ForecastDisplayType.cone.rawValue,
                                // Placeholder content shown for the instant before the
                                // real state lands — no pills rather than wrong ones.
                                cgmLifecycle: nil,
                                pumpLifecycle: nil,
                                loopStatus: nil,
                                cgmStatus: nil,
                                pumpStatus: nil,
                                basal: nil
                            ),
                            isInitialState: true
                        ),
                    staleDate: Date.now.addingTimeInterval(60)
                )

                let activity = try Activity.request(
                    attributes: LiveActivityAttributes(startDate: Date.now),
                    content: expired,
                    pushType: nil
                )
                currentActivity = ActiveActivity(activity: activity)
                debug(.default, "[LiveActivityManager] Created new activity: \(activity.id)")

                // Update the newly created activity with actual data
                let updateContent = ActivityContent(
                    state: state,
                    staleDate: Date.now.addingTimeInterval(5 * 60)
                )
                await activity.update(updateContent)
                // LA-COALESCE: record the creation push too, so the burst that
                // usually follows it is coalesced like any other.
                lastPushedState = state
                lastPushedAt = Date.now
                debug(.default, "[LiveActivityManager] Set initial content for new activity: \(activity.id)")
            } catch {
                debug(
                    .default,
                    "[LiveActivityManager]: Error creating new activity: \(error)"
                )
                // Reset currentActivity on error to allow retry on next update
                currentActivity = nil
            }
        }
    }

    /// Ends the current live activity and ensures that all unknown activities are terminated.
    private func endActivity() async {
        debug(.default, "[LiveActivityManager] Ending all live activities...")

        // LA-COALESCE: a new activity must never be compared against what the
        // previous one was showing.
        lastPushedState = nil
        lastPushedAt = nil

        if let currentActivity {
            debug(.default, "[LiveActivityManager] Ending current activity: \(currentActivity.activity.id)")
            await currentActivity.activity.end(nil, dismissalPolicy: .immediate)
            self.currentActivity = nil
        }

        for unknownActivity in Activity<LiveActivityAttributes>.activities {
            debug(.default, "[LiveActivityManager] Ending unknown activity: \(unknownActivity.id)")
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        debug(.default, "[LiveActivityManager] All live activities ended.")
    }

    /// Restarts the live activity from a Live Activity Intent.
    ///
    /// This method mimics xdrip's `restartActivityFromLiveActivityIntent()` behavior by verifying that a valid content state
    /// exists,
    /// ending the current live activity, and starting a new one using the current state.
    @MainActor func restartActivityFromLiveActivityIntent() async {
        await endActivity()

        while (currentActivity != nil && currentActivity!.activity.activityState != .ended) || Activity<LiveActivityAttributes>
            .activities.contains(where: { $0.activityState != .ended })
        {
            debug(.default, "[LiveActivityManager] Waiting for Live Activity to end...")
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s sleep
        }

        // Add additional delay to ensure iOS has fully cleaned up the previous activity
        debug(.default, "[LiveActivityManager] Waiting additional time for iOS to clean up...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s additional delay

        await pushCurrentContent()

        debug(.default, "[LiveActivityManager] Restarted Live Activity from LiveActivityIntent (via iOS Shortcut)")
    }
}

@available(iOS 16.2, *) extension LiveActivityManager {
    /// Sensor lifecycle for the Live Activity's CGM pill. Prefers the full
    /// lifespan timeline (G7 only — it is the one manager exposing a grace
    /// end) and falls back to a bare expiry date for every other CGM.
    private func currentCgmLifecycle() -> LiveActivityAttributes.DeviceLifecycle? {
        guard fetchGlucoseManager.cgmGlucoseSourceType != .none else { return nil }
        let manager = fetchGlucoseManager.cgmManager
        return LiveActivityDeviceLifecycle.cgm(
            timeline: SensorLifecycleTimeline.resolve(manager: manager),
            expiresAt: SensorExpiryResolver.expiresAt(
                manager: manager,
                glucoseSource: fetchGlucoseManager.glucoseSource,
                lifecycle: fetchGlucoseManager.cgmProgressHighlight.value
            )
        )
    }

    /// Pump lifecycle for the Live Activity's pump pill. `pumpExpiresAtDate` is
    /// nil for pumps with no session clock (Medtronic, Dana), which report `ok`
    /// rather than vanishing.
    private func currentPumpLifecycle() -> LiveActivityAttributes.DeviceLifecycle? {
        LiveActivityDeviceLifecycle.pump(
            expiresAt: apsManager.pumpExpiresAtDate.value,
            isPumpSetUp: apsManager.pumpManager != nil
        )
    }

    /// Loop health for the Custom layout's header dot. `lastLoopDate` is the
    /// APS loop's own timestamp, not the determination date already carried in
    /// `ContentState.date` — `LoopView` distinguishes the two and so must this.
    private func currentLoopStatus() -> LiveActivityAttributes.LoopStatus {
        let lastLoopDate = apsManager.lastLoopDate
        // Any dosing mode that enacts (#1511), the same rule upstream's `NotLoopingMonitor` uses:
        // Low Glucose Suspend and Basal Testing still loop, so their dot ages like closed loop.
        let isClosedLoop = settings.dosingMode.automation != .off

        // The real `manualTempBasal`, which maps to `.manualTemp` below — the same blue
        // the Home pill uses for this state.
        //
        // This used to pass `false`, to keep the age ladder visible on the grounds that
        // a manual temp shouldn't mask how long ago the loop ran. On device that was a
        // false alarm: `APSManager` still attempts the loop every cycle and it fails
        // with `manualBasalTemp` ("Loop not possible during the manual basal temp"), and
        // `finalizeLoop` stamps `lastLoopDate` only on *success*. So the date freezes
        // and the dot marches to red while nothing is actually wrong — observed
        // 2026-08-25, red dot against a Home pill that correctly showed manual mode.
        //
        // Red has to mean "act on this". A user-chosen manual basal is not that, and the
        // mode is already carried by the hand icon on the basal tile, plus the
        // `trio.aps.manualTempBasalActive` alert. `.inactive` is the right bucket: the
        // dot's own doc calls it "the loop is switched off ... not a fault".
        let freshness = LoopFreshness.classify(
            lastLoopDate: lastLoopDate == .distantPast ? nil : lastLoopDate,
            now: Date(),
            closedLoop: isClosedLoop,
            manualTempBasal: apsManager.isManualTempBasal
        )

        let severity: LiveActivityAttributes.LoopStatus.Severity = switch freshness {
        case .never,
             .openLoop: .inactive
        case .manualTemp: .manualTemp
        case .fresh: .ok
        case .aging: .late
        case .stale: .overdue
        }

        return LiveActivityAttributes.LoopStatus(
            lastLoopDate: lastLoopDate,
            isClosedLoop: isClosedLoop,
            isManualTempBasal: apsManager.isManualTempBasal,
            severity: severity
        )
    }

    /// Pushes again at the instant the loop's severity band changes.
    ///
    /// Every other update is driven by data arriving. This one exists for the case
    /// where data has *stopped* arriving: a missed CGM reading means no glucose, so no
    /// loop, so nothing publishes and nothing pushes — precisely when the banner is
    /// showing a stale dot and most needs correcting.
    ///
    /// Costs nothing while healthy. A loop landing every ~5 min re-pushes and
    /// reschedules before the first boundary is ever reached, so this only fires once
    /// the loop has genuinely stopped keeping up.
    private func scheduleLoopSeverityRefresh(for status: LiveActivityAttributes.LoopStatus) {
        loopSeverityRefreshTask?.cancel()
        loopSeverityRefreshTask = nil

        guard status.isClosedLoop,
              let lastLoopDate = status.lastLoopDate, lastLoopDate != .distantPast,
              let boundary = LoopFreshness.nextBoundary(lastLoopDate: lastLoopDate, after: Date())
        else { return }

        // A whole second past the boundary, not on it. `LoopFreshness` compares with
        // `<=`, so a push landing exactly on `lastLoopDate + lag + freshLimit` still
        // classifies `.ok` — it would push an unchanged state and re-arm for the
        // *next* boundary, leaving the dot green until 10:30 and never reaching
        // `.overdue` at all. Verified by simulating the sequence: with no margin the
        // bands come out ok -> ok -> late; with it, ok -> late -> overdue.
        let delay = boundary.timeIntervalSinceNow + 1
        guard delay > 0 else { return }

        loopSeverityRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.pushCurrentContent()
        }
    }

    /// LA-BG-STALENESS: pushes once, a second after the newest reading turns 12 minutes old.
    ///
    /// The Custom layout masks the BG to dashes at that age (`isReadingFresh`), but it
    /// decides that when it draws, and nothing else draws then: ActivityKit's stale
    /// redraw comes at ~6 minutes and the loop's red push at ~10m40s after the reading.
    /// Without this the mask appeared only if something happened to redraw later.
    ///
    /// Forced past the LA-COALESCE dedupe, because the state is normally identical to the
    /// last push: same reading, only its age has moved. It terminates: the refresh calls
    /// back into `pushCurrentContent`, which re-arms for the same reading, finds the
    /// boundary already passed, and arms nothing.
    ///
    /// Like the loop refresh it is a `Task.sleep`, so while the app is suspended it lands
    /// at the next wake. Free while readings arrive: each push re-arms for the newer
    /// reading and cancels this one.
    private func scheduleReadingExpiryRefresh(lastReading: Date) {
        readingExpiryRefreshTask?.cancel()
        readingExpiryRefreshTask = nil

        // 12 minutes is `LiveActivityCustomFormat.readingFreshnessWindow`, the same number
        // as `GlucoseFreshness.staleInterval` and `APSManager`'s dosing gate. The widget's
        // copy is not compiled into the app, so it is repeated here; move all of them
        // together. A second past, because the view tests `<` against its draw time.
        let delay = lastReading.addingTimeInterval(12 * 60).timeIntervalSinceNow + 1
        guard delay > 0 else { return }

        readingExpiryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.pushCurrentContent(force: true)
        }
    }

    /// One-line CGM status (warming up, stabilizing, signal loss, sensor
    /// error), or `nil` while healthy. Split labels are flattened the same way
    /// `DeviceLanesView` does it.
    private func currentCgmStatus() -> LiveActivityAttributes.DeviceStatusMessage? {
        guard let state = fetchGlucoseManager.cgmDisplayState.value,
              !state.localizedMessage.isEmpty
        else { return nil }
        return LiveActivityAttributes.DeviceStatusMessage(
            message: state.localizedMessage.replacingOccurrences(of: "\n", with: " "),
            isCritical: state.status == .critical
        )
    }

    /// Pump problems — pod fault, occlusion, empty reservoir, suspension.
    ///
    /// Same gate the home screen uses in `displayPumpStatusHighlightMessage`:
    /// only warning and critical highlights are worth surfacing, since normal
    /// ones restate what the countdown already says. The app prefixes ⚠️ / ‼️;
    /// here the severity travels as a flag and becomes colour instead, because
    /// the tile has no room for a glyph.
    private func currentPumpStatus() -> LiveActivityAttributes.DeviceStatusMessage? {
        guard let highlight = apsManager.pumpManager?.pumpStatusHighlight,
              highlight.state == .warning || highlight.state == .critical
        else { return nil }
        return LiveActivityAttributes.DeviceStatusMessage(
            message: highlight.localizedMessage.replacingOccurrences(of: "\n", with: " "),
            isCritical: highlight.state == .critical
        )
    }

    /// What the pump is *actually delivering*, read from its own
    /// `basalDeliveryState` rather than from the loop's determination.
    ///
    /// This previously used `data.determination?.rate ?? scheduledBasalRate()`,
    /// which was wrong twice over. `determination.rate` is what oref *asked
    /// for*, not what is running; and when it was absent the tile fell back to
    /// the scheduled profile rate — printing a number the pump was not
    /// delivering. Observed 2026-08-22: a zero temp basal running to recover a
    /// low (BG 3.7) while the banner read `0.4 U/hr`. The home screen, which
    /// reads enacted pump events, correctly showed `0 U/hr`.
    ///
    /// The rule this now follows: **never infer a delivery rate.** If the pump
    /// has not said what it is doing, the tile shows `--`. "Unknown" is a safe
    /// thing to display about insulin; a confident wrong number is not.
    private func currentBasalStatus() -> LiveActivityAttributes.BasalStatus? {
        // No pump paired, or the manager has not resolved yet.
        guard let state = deviceDataManager.pumpManager?.status.basalDeliveryState else { return nil }

        switch state {
        case let .active(at):
            // `DeviceDataManager` treats `.distantPast` as "pump not currently
            // available" — the same sentinel is honoured here.
            guard at != .distantPast else { return nil }
            return LiveActivityAttributes.BasalStatus(
                rate: scheduledBasalRate(),
                kind: .scheduled,
                isSuspended: false
            )

        case let .tempBasal(dose):
            return LiveActivityAttributes.BasalStatus(
                rate: Decimal(dose.unitsPerHour),
                kind: apsManager.isManualTempBasal ? .manualTemp : .temp,
                isSuspended: false
            )

        case .suspended:
            return LiveActivityAttributes.BasalStatus(
                rate: nil,
                kind: .scheduled,
                isSuspended: true
            )

        // Mid-transition: initiating or cancelling a temp, suspending, resuming.
        // The old rate is no longer true and the new one is not yet known, so
        // report the transition as "unknown rate" rather than showing a stale
        // number. `isSuspended` is deliberately false — the pump has not
        // stopped, it is changing its mind.
        case .cancelingTempBasal,
             .initiatingTempBasal,
             .resuming,
             .suspending:
            return LiveActivityAttributes.BasalStatus(
                rate: nil,
                kind: .temp,
                isSuspended: false
            )
        }
    }

    /// Rate the basal profile prescribes for right now. Uses the same lookup
    /// the app uses elsewhere so the tile and the chart agree.
    private func scheduledBasalRate(now: Date = Date()) -> Decimal? {
        // LA-BASAL-CACHE: from memory, not from disk.
        guard let profile = basalProfile else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let totalMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return findBasalRateForOffset(for: totalMinutes, in: profile)
    }

    /// - Parameter force: LA-BG-STALENESS: skip the identical-state dedupe. Only the
    ///   reading-expiry refresh passes `true`.
    @MainActor func pushCurrentContent(force: Bool = false) async {
        // Armed *before* the guards below, deliberately. This is the only thing that
        // moves the loop dot when no data is arriving, and a scheduled refresh calls
        // straight back into this method — so if the re-arm sat after an early return,
        // one pass through a missing-data window would break the chain permanently and
        // the dot would freeze exactly as it did on 2026-08-24. Re-arming first makes
        // the schedule survive a barren pass. It still terminates: the second boundary
        // yields no successor, so `nextBoundary` returns nil and nothing re-arms.
        //
        // Hoisted for the same reason it is used twice — `loopStatus` lives on
        // `ContentAdditionalState`, not on `ContentState`.
        let loopStatus = currentLoopStatus()
        scheduleLoopSeverityRefresh(for: loopStatus)

        guard let glucose = data.glucoseFromPersistence, let bg = glucose.first else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no current glucose data available")
            return
        }
        // LA-BG-STALENESS: the same reading the view judges, the newest in the chart.
        // Armed only once a reading is in hand; an empty fetch leaves any pending refresh
        // armed rather than cancelling it.
        if let lastReading = glucose.map(\.date).max() {
            scheduleReadingExpiryRefresh(lastReading: lastReading)
        }
        // LA-LOOP-WAIT: held until the cycle settles. After the re-arms above, so a
        // held pass still keeps both scheduled refreshes alive.
        if !force, loopWaitDeadline != nil {
            return
        }
        let prevGlucose = data.glucoseFromPersistence?.dropFirst().first

        guard let determination = data.determination else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no determination available")
            return
        }

        let content = LiveActivityAttributes.ContentState(
            new: bg,
            prev: prevGlucose,
            units: settings.units,
            chart: glucose,
            settings: settings,
            determination: determination,
            iob: data.iob,
            override: data.override,
            tempTarget: data.tempTarget,
            widgetItems: data.widgetItems,
            cgmLifecycle: currentCgmLifecycle(),
            pumpLifecycle: currentPumpLifecycle(),
            loopStatus: loopStatus,
            cgmStatus: currentCgmStatus(),
            pumpStatus: currentPumpStatus(),
            basal: currentBasalStatus()
        )

        await pushUpdate(content, force: force)
    }
}
