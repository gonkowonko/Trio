import CoreData
import Foundation

// GARMIN-REMOTE: carbs and bolus from the TrioIQ Remote Garmin Edge widget.
// Everything lives in this file and WatchConfigGarminRemoteView.swift; GarminManager only
// registers the widget and hands its messages here. Search for GARMIN-REMOTE to find every hook.
//
// Messages (see the TrioIQRemote repo README):
//   widget -> Trio : "status", or {"cmd":"status","pending":"…"} to also ask what happened to a
//                    request the widget never heard back about (it closed while waiting)
//   widget -> Trio : {"cmd":"carbs","g":20,"ts":<sec>,"id":"…"}
//   widget -> Trio : {"cmd":"bolus","tenths":15,"ts":<sec>,"id":"…"}
//   Trio -> widget : {"ack":"carbs"|"bolus","id":"…","ok":true|false,"reason":"…"}
//   Trio -> widget : the Garmin watch state, plus "remote": true, and while each is allowed
//                    "garminMaxCarbs", "garminCarbPresets" ([g, g]) / "garminMaxBolus".
//                    "lastCarbs" {"g","ts"} and "lastBolus" {"tenths","ts"}: newest from any
//                    source in the last 12 hours. Also sent unasked after a Garmin entry's loop.
//                    "pendingResult" {"id","ok","reason"} or {"id","unknown":true} when asked.

/// TrioIQ Remote settings. Kept out of TrioSettings so the feature can be removed without
/// touching settings decoding.
struct GarminRemoteSettings: Codable, Equatable {
    var isCarbsEnabled = false
    var isBolusEnabled = false
    /// Grams per entry
    var maxCarbs = 60
    /// Units per bolus. Also capped at the pump's max bolus when a request is checked.
    var maxBolus: Decimal = 1
    /// Grams on the widget's two carb buttons, never above maxCarbs
    var carbPresetA = 20
    var carbPresetB = 40

    init() {}

    /// Missing keys keep their defaults, so settings saved by an older build still load
    /// instead of failing to decode and resetting everything to off
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GarminRemoteSettings()
        isCarbsEnabled = try container.decodeIfPresent(Bool.self, forKey: .isCarbsEnabled) ?? defaults.isCarbsEnabled
        isBolusEnabled = try container.decodeIfPresent(Bool.self, forKey: .isBolusEnabled) ?? defaults.isBolusEnabled
        maxCarbs = try container.decodeIfPresent(Int.self, forKey: .maxCarbs) ?? defaults.maxCarbs
        maxBolus = try container.decodeIfPresent(Decimal.self, forKey: .maxBolus) ?? defaults.maxBolus
        carbPresetA = try container.decodeIfPresent(Int.self, forKey: .carbPresetA) ?? defaults.carbPresetA
        carbPresetB = try container.decodeIfPresent(Int.self, forKey: .carbPresetB) ?? defaults.carbPresetB
    }
}

enum GarminRemote {
    /// Connect IQ app id of the TrioIQ Remote widget (its manifest.xml)
    static let appUUID = UUID(uuidString: "45dd5f22-a860-4e83-9521-f0a37443d800")!
    static let displayName = "TrioIQ Remote"

    @Persisted(key: "GarminRemote.settings") static var settings = GarminRemoteSettings()
}

/// A request already answered, so a repeat of the same id gets the same answer instead of a
/// second entry or dose
private struct GarminRemoteHandledRequest: Codable, Equatable {
    let id: String
    let ok: Bool
    let reason: String?
    let date: Date
}

/// Checks and carries out TrioIQ Remote requests. Trio is the gatekeeper: every limit is
/// checked here whatever the widget showed, and a request is answered at most once.
final class GarminRemoteHandler {
    private let apsManager: APSManager
    private let settingsManager: SettingsManager
    private let watchState: () async -> [GarminWatchState]

    /// Oldest request still acted on. Bolus is tight so a delayed message can't dose late.
    private let carbsMaxAge: TimeInterval = 15 * 60
    private let bolusMaxAge: TimeInterval = 2 * 60
    /// Allowance for the Edge's clock running ahead of the phone's
    private let clockSkew: TimeInterval = 2 * 60
    /// Minimum gap between boluses from the Edge
    private let bolusSpacing: TimeInterval = 3 * 60

    @Persisted(key: "GarminRemote.handledRequests") private var handled: [GarminRemoteHandledRequest] = []
    @Persisted(key: "GarminRemote.lastBolusAt") private var lastBolusAt: TimeInterval = 0

    /// Ids being worked on right now; a repeat arriving meanwhile is dropped and the first one answers
    private var inFlight: Set<String> = []

    init(apsManager: APSManager, settingsManager: SettingsManager, watchState: @escaping () async -> [GarminWatchState]) {
        self.apsManager = apsManager
        self.settingsManager = settingsManager
        self.watchState = watchState
    }

    /// Handles one message from the widget. `reply` sends a dictionary back to it.
    func handle(_ message: Any, reply: @escaping ([String: Any]) -> Void) {
        // The answers, in-flight ids and bolus gap are only touched on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handle(message, reply: reply) }
            return
        }
        if let text = message as? String, text == "status" {
            Task { await sendStatus(reply: reply) }
            return
        }
        if let request = message as? [String: Any], request["cmd"] as? String == "status" {
            // Worked out here on the main thread, where the answers and in-flight ids live
            let pendingResult = (request["pending"] as? String).flatMap { pendingResult(for: $0) }
            Task { await sendStatus(reply: reply, pendingResult: pendingResult) }
            return
        }

        guard let request = message as? [String: Any],
              let command = request["cmd"] as? String,
              let id = request["id"] as? String, !id.isEmpty,
              let sentAt = (request["ts"] as? NSNumber)?.doubleValue
        else {
            warning(.watch, "Ignored malformed message from TrioIQ Remote")
            return
        }

        // Sent once the loop after an entry has run, so the widget's IOB and COB catch up
        // while it's still open
        let pushStatus: () async -> Void = { [weak self] in
            await self?.sendStatus(reply: reply)
        }

        let respond: (Bool, String?) -> Void = { [weak self] ok, reason in
            self?.record(id: id, ok: ok, reason: reason)
            var ack: [String: Any] = ["ack": command, "id": id, "ok": ok]
            if let reason { ack["reason"] = reason }
            reply(ack)
        }

        if inFlight.contains(id) {
            debug(.watch, "TrioIQ Remote request \(id) already in progress, ignoring the repeat")
            return
        }
        if let previous = handled.first(where: { $0.id == id }) {
            info(.watch, "TrioIQ Remote request \(id) was already answered, sending the same answer")
            var ack: [String: Any] = ["ack": command, "id": id, "ok": previous.ok]
            if let reason = previous.reason { ack["reason"] = reason }
            reply(ack)
            return
        }

        switch command {
        case "carbs":
            handleCarbs(request, id: id, sentAt: sentAt, respond: respond, pushStatus: pushStatus)
        case "bolus":
            handleBolus(request, id: id, sentAt: sentAt, respond: respond, pushStatus: pushStatus)
        default:
            warning(.watch, "Ignored unknown TrioIQ Remote command \(command)")
        }
    }

    // MARK: - Status

    /// Same watch state the data field gets, plus the limits. Sent whatever the CGM or loop
    /// state, so the widget's "Trio replied recently" check only reflects the phone link.
    private func sendStatus(reply: @escaping ([String: Any]) -> Void, pendingResult: [String: Any]? = nil) async {
        var status: [String: Any] = [:]
        if let state = await watchState().first,
           let data = try? JSONEncoder().encode(state),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            status = object
        }

        // Lets the widget accept a reply that has no glucose in it
        status["remote"] = true

        let settings = GarminRemote.settings
        if settings.isCarbsEnabled {
            status["garminMaxCarbs"] = settings.maxCarbs
            status["garminCarbPresets"] = [settings.carbPresetA, settings.carbPresetB].map { min($0, settings.maxCarbs) }
        }
        if settings.isBolusEnabled, effectiveMaxBolus > 0 {
            status["garminMaxBolus"] = NSDecimalNumber(decimal: effectiveMaxBolus).doubleValue
        }

        // Newest entries from any source, so the widget's "last" lines and double-entry
        // warning match Trio, including entries made in the app and ones deleted there
        if let carbs = await lastCarbEntry() {
            status["lastCarbs"] = ["g": Int(carbs.grams.rounded()), "ts": Int(carbs.date.timeIntervalSince1970)]
        }
        if let bolus = await lastManualBolus() {
            let tenths = NSDecimalNumber(decimal: bolus.units * 10).doubleValue.rounded()
            status["lastBolus"] = ["tenths": Int(tenths), "ts": Int(bolus.date.timeIntervalSince1970)]
        }

        if let pendingResult {
            status["pendingResult"] = pendingResult
        }

        debug(.watch, "Sending status to TrioIQ Remote")
        let finalStatus = status
        await MainActor.run { reply(finalStatus) }
    }

    // MARK: - Carbs

    private func handleCarbs(
        _ request: [String: Any],
        id: String,
        sentAt: TimeInterval,
        respond: @escaping (Bool, String?) -> Void,
        pushStatus: @escaping () async -> Void
    ) {
        let settings = GarminRemote.settings
        guard settings.isCarbsEnabled else {
            return refuse("Carbs off in Trio", id: id, respond: respond)
        }
        guard let grams = (request["g"] as? NSNumber)?.intValue, grams > 0 else {
            return refuse("Invalid amount", id: id, respond: respond)
        }
        guard grams <= settings.maxCarbs else {
            return refuse("Over \(settings.maxCarbs) g limit", id: id, respond: respond)
        }
        guard isCurrent(sentAt, maxAge: carbsMaxAge) else {
            return refuse("Request too old", id: id, respond: respond)
        }

        inFlight.insert(id)
        // Logged at the time it was tapped on the Edge, never in the future
        let date = min(Date(timeIntervalSince1970: sentAt), Date())

        Task {
            let context = CoreDataStack.shared.newTaskContext()
            let saved: Bool = await context.perform {
                let entry = CarbEntryStored(context: context)
                entry.id = UUID()
                entry.carbs = Double(grams)
                entry.date = date
                entry.note = "Via Garmin"
                entry.isFPU = false
                entry.isUploadedToNS = false
                entry.isUploadedToHealth = false
                entry.isUploadedToTidepool = false
                do {
                    try context.save()
                    return true
                } catch let saveError {
                    error(.treatments, "Saving carbs from TrioIQ Remote failed", error: saveError)
                    return false
                }
            }

            await MainActor.run {
                self.inFlight.remove(id)
                if saved {
                    info(.treatments, "Logged \(grams) g carbs from TrioIQ Remote")
                    respond(true, nil)
                } else {
                    respond(false, "Saving failed")
                }
            }

            // Loop now so COB and dosing reflect the carbs without waiting for the next cycle
            if saved {
                do {
                    try await self.apsManager.determineBasalSync()
                } catch {
                    warning(.loop, "Loop after TrioIQ Remote carbs failed", error: error)
                }
                await pushStatus()
            }
        }
    }

    // MARK: - Bolus

    /// The Garmin max, never above the pump's max bolus
    private var effectiveMaxBolus: Decimal {
        min(GarminRemote.settings.maxBolus, settingsManager.pumpSettings.maxBolus)
    }

    private func handleBolus(
        _ request: [String: Any],
        id: String,
        sentAt: TimeInterval,
        respond: @escaping (Bool, String?) -> Void,
        pushStatus: @escaping () async -> Void
    ) {
        guard GarminRemote.settings.isBolusEnabled else {
            return refuse("Bolus off in Trio", id: id, respond: respond)
        }
        guard let tenths = (request["tenths"] as? NSNumber)?.intValue, tenths > 0 else {
            return refuse("Invalid amount", id: id, respond: respond)
        }
        let amount = Decimal(tenths) / 10
        let max = effectiveMaxBolus
        // Refused, not reduced: enactBolus doesn't check the pump max, and a silently
        // smaller dose than the rider asked for is its own surprise
        guard amount <= max else {
            return refuse("Over \(Self.unitsText(max)) U limit", id: id, respond: respond)
        }
        guard isCurrent(sentAt, maxAge: bolusMaxAge) else {
            return refuse("Request too old", id: id, respond: respond)
        }
        guard apsManager.bolusProgress.value == nil else {
            return refuse("Bolus in progress", id: id, respond: respond)
        }
        let sinceLast = Date().timeIntervalSince1970 - lastBolusAt
        guard sinceLast >= bolusSpacing else {
            let minutes = Int(sinceLast / 60)
            return refuse(minutes < 1 ? "Bolus sent just now" : "Bolus sent \(minutes)m ago", id: id, respond: respond)
        }

        inFlight.insert(id)
        // Taken before anything is awaited, so a second request can't slip in meanwhile
        let previousBolusAt = lastBolusAt
        lastBolusAt = Date().timeIntervalSince1970

        Task {
            // The gap also counts manual boluses from the app or Apple Watch, not just Garmin ones
            if let last = await self.lastManualBolus() {
                let since = Date().timeIntervalSince(last.date)
                if since < self.bolusSpacing {
                    await MainActor.run {
                        self.inFlight.remove(id)
                        self.lastBolusAt = previousBolusAt
                        let minutes = Int(since / 60)
                        self.refuse(
                            minutes < 1 ? "Bolus given just now" : "Bolus given \(minutes)m ago",
                            id: id,
                            respond: respond
                        )
                    }
                    return
                }
            }

            info(.bolus, "TrioIQ Remote requested a bolus of \(Self.unitsText(amount)) U")
            // enactBolus returns after the loop that follows a manual bolus
            await self.apsManager
                .enactBolus(amount: NSDecimalNumber(decimal: amount).doubleValue, isSMB: false) { success, message in
                    Task { @MainActor in
                        self.inFlight.remove(id)
                        if success {
                            info(.bolus, "TrioIQ Remote bolus of \(Self.unitsText(amount)) U enacted")
                            respond(true, nil)
                        } else {
                            // The gap stays: a pump error can leave a partial delivery, and Trio's
                            // own alert says to check pump history before repeating
                            warning(.bolus, "TrioIQ Remote bolus of \(Self.unitsText(amount)) U failed: \(message)")
                            respond(false, "Bolus failed, check pump")
                        }
                    }
                }
            await pushStatus()
        }
    }

    /// What happened to a request the widget asked about. Nil while it's still being worked
    /// on (its own answer will follow); "unknown" if Trio has no record of it, so it never
    /// arrived and nothing was done.
    private func pendingResult(for id: String) -> [String: Any]? {
        if inFlight.contains(id) {
            return nil
        }
        guard let answer = handled.first(where: { $0.id == id }) else {
            info(.watch, "TrioIQ Remote asked about request \(id), which never arrived")
            return ["id": id, "unknown": true]
        }
        var result: [String: Any] = ["id": id, "ok": answer.ok]
        if let reason = answer.reason { result["reason"] = reason }
        return result
    }

    // MARK: - Last entries

    /// How far back "lastCarbs" / "lastBolus" look
    private let lastEntryWindow: TimeInterval = 12 * 60 * 60

    /// Newest carb entry from any source within the window, leaving out fat/protein equivalents
    /// and future entries
    private func lastCarbEntry() async -> (date: Date, grams: Double)? {
        let now = Date()
        let windowStart = now.addingTimeInterval(-lastEntryWindow)
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = CarbEntryStored.fetchRequest()
            // Bounded by the window so the date index is walked over hours, not months
            request.predicate = NSPredicate(
                format: "isFPU == NO AND date >= %@ AND date <= %@",
                windowStart as NSDate,
                now as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1
            guard let entry = try? context.fetch(request).first, let date = entry.date else { return nil }
            return (date, entry.carbs)
        }
    }

    /// Newest manual bolus from any source (app, Apple Watch, Garmin) within the window,
    /// leaving out SMBs
    private func lastManualBolus() async -> (date: Date, units: Decimal)? {
        let now = Date()
        let windowStart = now.addingTimeInterval(-lastEntryWindow)
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = PumpEventStored.fetchRequest()
            // Bounded by the window: most pump events are temp basals and SMBs, so an unbounded
            // newest-first walk could cover days of history before finding a manual bolus
            request.predicate = NSPredicate(
                format: "bolus != nil AND bolus.isSMB == NO AND timestamp >= %@ AND timestamp <= %@",
                windowStart as NSDate,
                now as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            request.fetchLimit = 1
            guard let event = try? context.fetch(request).first, let date = event.timestamp, let bolus = event.bolus
            else { return nil }
            let units = (bolus.amount ?? bolus.programmedAmount)?.decimalValue ?? 0
            return (date, units)
        }
    }

    // MARK: - Helpers

    private func refuse(_ reason: String, id: String, respond: (Bool, String?) -> Void) {
        info(.watch, "Refused TrioIQ Remote request \(id): \(reason)")
        respond(false, reason)
    }

    private func isCurrent(_ sentAt: TimeInterval, maxAge: TimeInterval) -> Bool {
        let age = Date().timeIntervalSince1970 - sentAt
        return age <= maxAge && age >= -clockSkew
    }

    /// Keeps the last day of answers, at most 50
    private func record(id: String, ok: Bool, reason: String?) {
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        var kept = handled.filter { $0.date > dayAgo && $0.id != id }
        kept.append(GarminRemoteHandledRequest(id: id, ok: ok, reason: reason, date: Date()))
        handled = Array(kept.suffix(50))
    }

    private static func unitsText(_ units: Decimal) -> String {
        String(format: "%.1f", NSDecimalNumber(decimal: units).doubleValue)
    }
}
