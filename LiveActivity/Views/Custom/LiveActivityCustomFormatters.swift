import Foundation

/// Small formatters used only by the Custom lock-screen layout.
///
/// Deliberately self-contained: the Custom layout is a separable stream of
/// work, so it does not borrow helpers from the Detailed layout or from the
/// device-status pills, and nothing outside `Views/Custom` reads these.
enum LiveActivityCustomFormat {
    /// Compact `5d 14h` / `22h` / `45m` remaining time, matching the phrasing
    /// the home screen's device lanes use.
    static func remaining(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let totalMinutes = Int(max(0, date.timeIntervalSince(now))) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        let d = String(localized: "d", comment: "Abbreviation for Days")
        let h = String(localized: "h", comment: "Abbreviation for Hours")
        let m = String(localized: "m", comment: "Abbreviation for Minutes")
        if days > 0, hours > 0 { return "\(days)\(d) \(hours)\(h)" }
        if days > 0 { return "\(days)\(d)" }
        if hours > 0 { return "\(hours)\(h)" }
        if minutes > 0 { return "\(minutes)\(m)" }
        return "<" + "\u{00A0}" + "1" + "\u{00A0}" + m
    }

    /// Whole minutes since `date`, as `2 m`. Used for the reading age inside
    /// the bobble and the loop age in the header.
    static func minutesAgo(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return "\(minutes)\u{00A0}" + String(localized: "m", comment: "Abbreviation for Minutes")
    }

    /// Mirrors `CurrentGlucoseView.isReadingFresh` and `APSManager`'s loop-input
    /// gate: a reading older than 12 minutes — one missed transmission on a
    /// 5-minute schedule — is masked rather than shown as if current.
    static let readingFreshnessWindow: TimeInterval = 12 * 60

    static func isReadingFresh(lastReading: Date?, now: Date = Date()) -> Bool {
        guard let lastReading else { return false }
        return now.timeIntervalSince(lastReading) < readingFreshnessWindow
    }
}
