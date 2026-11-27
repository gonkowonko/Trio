import Foundation
import WidgetKit

/// LOCAL: WATCH-SETTLE (v3, 27 Nov). When the shared complications (Glucose, Gauge, IOB,
/// Chart, Loop) are asked to redraw. Kept in its own file so it can be carried onto dev
/// once PR 1809 lands: `WatchState` only calls `snapshotSaved`, `isWaitingForLoop` and
/// `installedKinds`. Glance is not handled here (`GlanceDirectFeed`).
///
/// Why: every snapshot change used to send a reload, so each reading sent two or three
/// within ~10 s (the watch's own G7 reading, then the phone's loop result, sometimes the
/// phone's update just before): ~31-37 an hour for 12 readings (watch log, 24-25 Nov).
/// watchOS often drew the first, which carries the previous loop, and skipped or deferred
/// the rest, so the loop shown was a reading behind the phone.
///
/// The rules:
/// 1. A new reading waits up to `settleLimit` for its loop, then sends one reload. If it
///    timed out, the reading's loop still gets one reload if it lands within
///    `lateLoopWindow`, while the watch is still awake.
/// 2. While readings are arriving, nothing else reloads. watchOS held such reloads until
///    the next wake and ran them before the new reading was saved, so they drew the old
///    reading and cost the real one (watch log 26 Nov 10:52-11:10). The next reading is
///    under 5 min away and brings the change with it; amber needs a 5.5 min old loop, and
///    the timelines already carry `loopFreshnessTransitionDates` for ageing.
/// 3. A loop that lands while readings have stopped (the last one older than
///    `readingsStalledAfter`: a missed G7 reading, warm-up, the watch away from the
///    sensor) reloads straight away, so the loop colour follows the phone instead of
///    ageing to amber while it loops fine. No reading reload is pending to collide with.
/// 4. Only the kinds on a face are reloaded (`installedKinds`), to spend less of
///    watchOS's per-complication refresh allowance.
///
/// Measured with v2 (rules 1-2): 26-27 Nov overnight, 99 of 99 readings drawn with their
/// own loop, median 28 s; an evening hour where watchOS deferred redraws 2-5 min.
///
/// To take this out: delete this file, `complicationSettle` and its three uses in
/// `WatchState` (marked WATCH-SETTLE), and restore `reloadInstalledComplications()` in
/// `saveComplicationSnapshot`.
final class ComplicationSettle {
    private static let settleLimit: TimeInterval = 20
    private static let lateLoopWindow: TimeInterval = 60
    /// A reading this much newer than the last snapshot's starts a new cycle; the
    /// phone's and the watch's copies of one reading are seconds apart.
    private static let newReadingGap: TimeInterval = 30
    /// Readings are 5 min apart; past this one has been missed.
    private static let readingsStalledAfter: TimeInterval = 6 * 60

    private var settleReadingDate: Date?
    private var settleStartedAt: Date?
    private var settleTimeout: DispatchWorkItem?
    private var timedOutReading: Date?
    private var timedOutAt: Date?
    private var reload: () -> Void = {}

    /// A reading is waiting for its loop and will send its own reload.
    var isWaitingForLoop: Bool { settleReadingDate != nil }

    /// The loop for `reading` has run: the previous loop is ~5 min older than it.
    private static func loopIsIn(for reading: Date, _ snapshot: ComplicationState) -> Bool {
        guard let loop = snapshot.loopDate else { return false }
        return loop > reading.addingTimeInterval(-60)
    }

    /// Called after each saved snapshot change; `reload` sends the reload when one is due.
    func snapshotSaved(_ snapshot: ComplicationState, previous: ComplicationState?, reload: @escaping () -> Void) {
        self.reload = reload
        let isNewReading = previous.map { snapshot.date.timeIntervalSince($0.date) > Self.newReadingGap } ?? true

        // Rule 1: a new reading waits for its loop.
        if isNewReading {
            settleTimeout?.cancel()
            timedOutReading = nil
            settleReadingDate = snapshot.date
            settleStartedAt = Date()
            if Self.loopIsIn(for: snapshot.date, snapshot) {
                finishSettle(reason: "the loop was already in")
                return
            }
            WatchLogger.shared.debug(.data, "Complication reload held for the loop")
            let work = DispatchWorkItem { [weak self] in
                self?.finishSettle(reason: "no loop within \(Int(Self.settleLimit)) s")
            }
            settleTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleLimit, execute: work)
            return
        }

        if let reading = settleReadingDate {
            if Self.loopIsIn(for: reading, snapshot) {
                finishSettle(reason: "the loop arrived")
            } else if let started = settleStartedAt, Date().timeIntervalSince(started) >= Self.settleLimit {
                // the timeout's work item can be late if the app was suspended
                finishSettle(reason: "no loop within \(Int(Self.settleLimit)) s")
            }
            return
        }

        // Rule 1: the reading's own loop, landing soon after a timeout.
        if let reading = timedOutReading, let timedOut = timedOutAt,
           Date().timeIntervalSince(timedOut) <= Self.lateLoopWindow,
           Self.loopIsIn(for: reading, snapshot)
        {
            timedOutReading = nil
            WatchLogger.shared.info(
                .data,
                "Complication reload for the late loop, \(Int(Date().timeIntervalSince(reading))) s after the reading"
            )
            reload()
            return
        }

        // Rule 3: a new loop while readings have stopped.
        let readingAge = Date().timeIntervalSince(snapshot.date)
        if readingAge > Self.readingsStalledAfter,
           let loop = snapshot.loopDate, loop > (previous?.loopDate ?? .distantPast)
        {
            WatchLogger.shared.info(
                .data,
                "Complication reload for a loop while readings have stopped, reading \(Int(readingAge / 60)) min old"
            )
            reload()
        }
        // Rule 2: anything else waits for the next reading.
    }

    private func finishSettle(reason: String) {
        guard let reading = settleReadingDate else { return }
        let timedOut = !reason.hasPrefix("the loop")
        settleReadingDate = nil
        settleStartedAt = nil
        settleTimeout?.cancel()
        settleTimeout = nil
        timedOutReading = timedOut ? reading : nil
        timedOutAt = timedOut ? Date() : nil
        WatchLogger.shared.info(
            .data,
            "Complication reload released, \(reason), \(Int(Date().timeIntervalSince(reading))) s after the reading"
        )
        reload()
    }

    // MARK: Rule 4: only the kinds on a face

    private static let installedKindsKey = "WatchSettle.installedKinds"

    /// The shared complication kinds on a face, as WidgetKit last reported them, or all
    /// of them until it has. The reload itself stays synchronous (RELOAD-NOW: a G7 wake
    /// can suspend the app before an async callback runs), so this reads the list saved
    /// by the previous call and asks WidgetKit for a fresh one for next time. A kind just
    /// added to a face draws itself when added, and is in the list from the next reload.
    func installedKinds() -> [String] {
        // GLANCE-IOBCOB: its kind (`GlanceIobCob.kind`, in the complication extension).
        let all = ComplicationKind.allCases.map(\.widgetKind) + ["TrioGlanceIobCobComplication"]
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard let configurations = try? result.get() else { return }
            let installed = Set(configurations.map(\.kind))
            UserDefaults.standard.set(all.filter { installed.contains($0) }, forKey: Self.installedKindsKey)
        }
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.installedKindsKey) else { return all }
        return saved
    }
}
