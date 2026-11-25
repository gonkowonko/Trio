import Foundation
import WidgetKit

// LOCAL: GLANCE-DIRECT. The Glance complication's own pipeline: fed only by the
// watch's own G7 link, one reload request per new reading, for the Glance kind
// alone. Nothing from the phone (loop updates, its readings, background refresh)
// writes to it or reloads it. The phone's settings (units, glucose range, colour
// steps, stale time) are read when a reading is saved, from the watch's copy of
// them, but a settings change never triggers a redraw.
//
// Why (25 Nov 2026): with Glance on the shared snapshot it got ~30 reload requests
// an hour for 12 readings, and on the wrist watchOS deferred redraws for 40 minutes
// at a time, so Glance sat a reading behind. This keeps Glance's requests to the
// minimum, so if it still sticks the limit is watchOS, not us.
//
// To remove it: delete this file, its call in WatchCGMHost (`GlanceDirectFeed`),
// put "TrioGlanceComplication" back in `WatchState.reloadInstalledComplications`,
// and point `GlanceProvider` back at `ComplicationStore.load()`.

@MainActor final class GlanceDirectFeed {
    static let shared = GlanceDirectFeed()

    /// Also in GlanceComplication.swift (`GlanceDirectStore`); the strings must match.
    static let stateKey = "GlanceDirect.state"
    private static let readingsKey = "GlanceDirect.readings"
    private static let glanceKind = "TrioGlanceComplication"
    /// A previous reading older than this gives no delta.
    private static let deltaGap: TimeInterval = 15 * 60

    private struct Reading: Codable {
        var t: TimeInterval
        var mgdl: Int
        var trend: String?
    }

    private let defaults = ComplicationStore.defaults
    private lazy var readings: [Reading] = defaults?.data(forKey: Self.readingsKey)
        .flatMap { try? JSONDecoder().decode([Reading].self, from: $0) } ?? []
    private var lastReloadedReading: TimeInterval?

    /// Every batch the G7 link delivers: the reading, and any backfill after it.
    func receive(_ incoming: [BloodGlucose]) {
        guard let defaults else { return }
        let known = Set(readings.map { Int($0.t / 60) })
        for reading in incoming {
            guard let value = reading.glucose ?? reading.sgv else { continue }
            let t = reading.dateString.timeIntervalSince1970
            guard !known.contains(Int(t / 60)) else { continue }
            readings.append(Reading(t: t, mgdl: value, trend: reading.direction?.rawValue))
        }
        readings.sort { $0.t < $1.t }
        let from = Date().addingTimeInterval(-ComplicationState.chartWindow).timeIntervalSince1970
        readings.removeAll { $0.t < from }
        defaults.set(try? JSONEncoder().encode(readings), forKey: Self.readingsKey)

        guard let latest = readings.last else { return }
        do {
            defaults.set(try JSONEncoder().encode(state(latest: latest)), forKey: Self.stateKey)
        } catch {
            WatchLogger.shared.warning(.data, "Glance direct state not saved", error: error)
            return
        }
        // Backfill only fills the graph: the next redraw picks it up. A second request
        // a moment after the first would be ignored by WidgetKit anyway.
        guard latest.t != lastReloadedReading else { return }
        lastReloadedReading = latest.t
        WidgetCenter.shared.reloadTimelines(ofKind: Self.glanceKind)
        let age = Int(Date().timeIntervalSince1970 - latest.t)
        WatchLogger.shared.info(.data, "Glance direct reload requested, reading \(age) s old")
    }

    private func state(latest: Reading) -> ComplicationState {
        let range = WatchState.shared.glucoseRange
        let base = ComplicationStore.load() ?? .placeholder
        var delta = ComplicationState.missingValue
        if readings.count >= 2 {
            let previous = readings[readings.count - 2]
            if latest.t - previous.t < Self.deltaGap {
                // in mg/dL, then converted, as the phone does (DELTA-MGDL)
                let changeMgdl = latest.mgdl - previous.mgdl
                let change = range.isMmol
                    ? NSDecimalNumber(decimal: Decimal(changeMgdl).asMmolL).doubleValue
                    : Double(changeMgdl)
                let formatted = range.isMmol ? String(format: "%.1f", change) : String(format: "%.0f", change)
                delta = change < 0 ? formatted : "+" + formatted
            }
        }
        var state = base
        state.date = Date(timeIntervalSince1970: latest.t)
        state.glucose = Decimal(latest.mgdl).formatted(for: range.isMmol ? .mmolL : .mgdL)
        state.glucoseColorHex = range.color(latest.mgdl).toHexString()
        state.trend = latest.trend ?? ""
        state.delta = delta
        state.iob = ComplicationState.missingValue
        state.cob = ComplicationState.missingValue
        state.lastLoopTime = ComplicationState.missingValue
        state.loopDate = nil
        state.units = range.isMmol ? GlucoseUnits.mmolL.rawValue : GlucoseUnits.mgdL.rawValue
        state.glucoseValue = range.display(latest.mgdl)
        state.history = readings.map { ComplicationPoint(timestamp: $0.t, glucose: range.display($0.mgdl)) }
        return state
    }
}
