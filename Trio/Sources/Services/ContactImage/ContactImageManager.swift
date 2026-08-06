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

    /// Time-derived visual state that changes even when no new data arrives: the
    /// loop-ring staleness band (green/yellow/red) and whether the CGM reading is
    /// stale (muted grey). Used to decide when a periodic refresh actually changes
    /// the rendered image, so the timer can skip redundant contact-store writes.
    private struct RenderStaleness: Equatable {
        enum LoopBand {
            case noLoop // no loop date yet -> gray
            case fresh // <= 5 min -> green
            case warning // <= 10 min -> yellow
            case stale // > 10 min -> red
        }

        let loopBand: LoopBand
        /// Glucose staleness band (fresh / warning / urgent) drives the strike-through
        /// colour, so the periodic refresh must re-render when it changes too.
        let glucoseStaleness: ContactPicture.GlucoseStaleness

        /// Must match `ContactPicture.Config.lag`.
        private static let loopLag: TimeInterval = 30

        static func current(for state: ContactImageState, now: Date = Date()) -> RenderStaleness {
            let loopBand: LoopBand
            if let lastLoopDate = state.lastLoopDate {
                let delta = now.timeIntervalSince(lastLoopDate) - loopLag
                if delta <= 5.minutes.timeInterval {
                    loopBand = .fresh
                } else if delta <= 10.minutes.timeInterval {
                    loopBand = .warning
                } else {
                    loopBand = .stale
                }
            } else {
                loopBand = .noLoop
            }

            let glucoseStaleness = ContactPicture.GlucoseStaleness.classify(glucoseDate: state.glucoseDate, now: now)

            return RenderStaleness(loopBand: loopBand, glucoseStaleness: glucoseStaleness)
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

    /// Periodic timer that re-renders contact images purely so staleness advances
    /// (green -> yellow -> red) when no new glucose / IOB / determination arrives.
    private let staleRefreshTimer = DispatchTimer(timeInterval: 60)

    /// The staleness last written to the contact store, so the timer can skip
    /// redundant `CNSaveRequest`s while the rendered result would be unchanged.
    private var lastRenderedStaleness: RenderStaleness?

    /// What a queued render is allowed to skip.
    private enum RenderRequest {
        /// New data arrived — render and write to the contact store unconditionally.
        case full
        /// Staleness timer tick — skip the write if the staleness band is unchanged.
        case stalenessOnly
    }

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
    }

    // MARK: - Render triggers

    /// Subscribes the render pipeline to every data signal that should refresh
    /// the contact images.
    ///
    /// A single loop cycle emits all of these within a second or two: new glucose
    /// kicks the loop, which then publishes a loop date (the same signal the app's
    /// loop pill uses — it also fires in open loop, where the determination's
    /// `timestamp` is never stamped), a new determination and an IOB update. They
    /// are merged and debounced into one render per burst instead of four racing
    /// ones, so the render also sees the fully settled state (glucose + loop date
    /// + COB + IOB) rather than whichever slice happened to arrive first.
    private func registerRenderTriggers() {
        let determinationUpdates: AnyPublisher<Void, Never> = coreDataPublisher?
            .filteredByEntityName("OrefDetermination")
            .map { _ in () }
            .eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()

        Publishers.MergeMany(
            glucoseStorage.updatePublisher.eraseToAnyPublisher(),
            iobService.iobPublisher.map { _ in () }.eraseToAnyPublisher(),
            apsManager.lastLoopDateSubject.map { _ in () }.eraseToAnyPublisher(),
            determinationUpdates
        )
        .debounce(for: .seconds(1), scheduler: queue)
        .sink { [weak self] in
            self?.enqueueRender(.full)
        }
        .store(in: &subscriptions)
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
        Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Unconditional full render so returning to the app always repairs
            // whatever the contact store currently holds.
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
            guard let self = self else { return }

            // Coalesce into an already-queued render: it will snapshot the latest
            // state when it starts anyway. Just make sure a data-driven request
            // isn't downgraded to a staleness-only write gate.
            if self.queuedRenderRequest != nil {
                if request == .full {
                    self.queuedRenderRequest = .full
                }
                return
            }

            self.queuedRenderRequest = request
            let previousRender = self.renderTask
            self.renderTask = Task {
                await previousRender?.value
                await self.runQueuedRender()
            }
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
            if unchanged { return }
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

                let delta = glucoseObjects.count >= 2
                    ? Decimal(firstGlucoseValue.glucose) - Decimal(glucoseObjects.dropFirst().first?.glucose ?? 0)
                    : 0
                let deltaConverted = settingsManager.settings.units == .mgdL ? delta : delta.asMmolL
                state.delta = deltaFormatter.string(from: deltaConverted as NSNumber)
            }

            // Drive the loop ring from the same source as the app's loop pill
            // (`apsManager.lastLoopDate`), not the determination's `timestamp`, which
            // is only stamped on enacted (closed-loop) determinations and so lags or
            // never updates in open loop. `.distantPast` means "no loop yet" -> nil,
            // so the ring shows gray rather than a spurious stale-red.
            let loopDate = apsManager.lastLoopDate
            state.lastLoopDate = loopDate == .distantPast ? nil : loopDate

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

        // Snapshot the render inputs on the main actor: a consistent copy of
        // `state` plus the staleness we are about to render. Committing the gate
        // only after a successful write (below) means a failed or no-op pass
        // leaves the periodic timer free to retry next tick.
        let (stateSnapshot, renderedStaleness) = await MainActor.run {
            (state, RenderStaleness.current(for: state))
        }
        var didUpdateAnyContact = false

        // Iterate through all stored ContactImageEntry objects
        for contactEntry in await contactImageStorage.fetchContactImageEntries() {
            // Ensure the contact has a valid contact ID
            guard let contactId = contactEntry.contactId else { continue }

            // Generate a new image for the contact based on the snapshotted state.
            // `getImage` is main-actor isolated (SwiftUI `View`), so the `await`
            // hops to the main thread for the render only; the CNContactStore I/O
            // below stays off it.
            let newImage = await ContactPicture.getImage(contact: contactEntry, state: stateSnapshot)

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

                // Create a mutable copy of the contact to update its image
                let mutableContact = contact.mutableCopy() as! CNMutableContact
                mutableContact.imageData = newImage.pngData() // Set the new image data

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

        // Commit the gate only on a successful render, so a transient
        // CNContactStore failure or an empty-entries pass doesn't wedge the
        // periodic staleness timer into skipping needed refreshes. Written on
        // the main actor to stay serialized with the timer's read.
        if didUpdateAnyContact {
            await MainActor.run { lastRenderedStaleness = renderedStaleness }
        }

        // Release the background task assertion now the render + writes are done.
        await MainActor.run {
            var id = backgroundTaskID
            endBackgroundTaskSafely(&id, taskName: "Update Contact Images")
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
