import Foundation

/// Small formatters used only by the Custom lock-screen layout.
///
/// Deliberately self-contained: the Custom layout is a separable stream of
/// work, so it does not borrow helpers from the Detailed layout or from the
/// device-status pills, and nothing outside `Views/Custom` reads these.
enum LiveActivityCustomFormat {
    /// Mirrors `CurrentGlucoseView.isReadingFresh` and `APSManager`'s loop-input
    /// gate: a reading older than 12 minutes — one missed transmission on a
    /// 5-minute schedule — is masked rather than shown as if current.
    static let readingFreshnessWindow: TimeInterval = 12 * 60

    static func isReadingFresh(lastReading: Date?, now: Date = Date()) -> Bool {
        guard let lastReading else { return false }
        return now.timeIntervalSince(lastReading) < readingFreshnessWindow
    }
}
