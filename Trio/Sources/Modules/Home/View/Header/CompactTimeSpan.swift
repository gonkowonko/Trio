import Foundation

// LOCAL: COMPACT-SPAN. Home header only (device lanes, glucose age, loop age,
// snooze pill). Upstream's `formattedTimeSpan` ("5 days 14 hr", "2 hr 15 min")
// stays everywhere else and for VoiceOver; this is the narrow form of the same
// units, "5d 14h", "2h 15m", "45m", "3h". Local-only file so merges never touch it.
// Roll back: delete this file and swap `compactTimeSpan` / `compactTimeAgo`
// back to `formattedTimeSpan` / `formattedTimeAgo` (grep COMPACT-SPAN).

extension Duration {
    /// Largest two units, narrow width, zero units dropped, rounded down:
    /// "5d 14h", "18h 59m", "3h", "45m", "< 1m".
    func compactTimeSpan(locale: Locale = .autoupdatingCurrent) -> String {
        if isUnderAMinute {
            return "<\u{00A0}" + Duration.seconds(60).compactTimeSpan(locale: locale)
        }
        let units: Set<UnitsFormatStyle.Unit> = self < .seconds(86400) ? [.hours, .minutes] : [.days, .hours]
        return formatted(
            .units(allowed: units, width: .narrow, zeroValueUnits: .hide, fractionalPart: .hide(rounded: .down))
                .locale(locale)
        )
    }
}

extension Date {
    /// Compact time since this date: "7m", "1h 30m", "< 1m".
    func compactTimeAgo(locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(-timeIntervalSinceNow).compactTimeSpan(locale: locale)
    }
}
