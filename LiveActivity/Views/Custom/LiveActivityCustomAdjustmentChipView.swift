import ActivityKit
import SwiftUI
import WidgetKit

/// The override / temp-target chip above the tile grid.
///
/// Overrides and temp targets share this one slot because they are not meant to
/// be applied together; if both ever are, they sit side by side rather than one
/// hiding the other.
///
/// The remaining time counts down live via `Text(timerInterval:)`, which the
/// system renders without waking the app or spending an ActivityKit update.
struct LiveActivityCustomAdjustmentChipView: View {
    /// Matched to the device pills' height — the two share the header row, and
    /// a chip taller than the pills would push the whole banner down whenever
    /// an adjustment starts.
    static let chipHeight: CGFloat = 19

    let isOverrideActive: Bool
    let overrideName: String
    let overrideDate: Date
    let overrideDuration: Decimal

    let isTempTargetActive: Bool
    let tempTargetName: String
    let tempTargetDate: Date
    let tempTargetDuration: Decimal

    var body: some View {
        HStack(spacing: 4) {
            // Glyphs and colours are the home screen's, from
            // `HomeRootView+BottomControls.adjustmentsOverrideView`, so the same
            // adjustment is marked the same way in the app and on the lock
            // screen. Without them the two chips differ only in hue, which
            // leaves colour doing the whole job of saying which is which.
            if isOverrideActive {
                chip(
                    name: overrideName,
                    icon: "clock.arrow.2.circlepath",
                    endsAt: endDate(from: overrideDate, minutes: overrideDuration),
                    color: .purple
                )
            }
            if isTempTargetActive {
                chip(
                    name: tempTargetName,
                    icon: "target",
                    endsAt: endDate(from: tempTargetDate, minutes: tempTargetDuration),
                    color: LiveActivityCustomPalette.green
                )
            }
            // Nothing is rendered when no adjustment is active. The header row
            // keeps its height from the device pills either way, so the rest of
            // the banner does not move when an override starts or ends.
        }
        .lineLimit(1)
    }

    private static let oneHour: TimeInterval = 3600
    private static let tenHours: TimeInterval = 10 * 3600

    /// Width for the ticking countdown, chosen from how long is left.
    ///
    /// `Text(timerInterval:)` is drawn by the system *after* layout, so SwiftUI
    /// has no glyphs to measure and reports an unbounded ideal width. It must be
    /// given an explicit width, and that width has to cover the longest string
    /// it will show: the old hardcoded 40pt was four points short of `1:44:33`,
    /// so a running override lost its seconds to an ellipsis.
    ///
    /// Buckets measured at 10.5pt semibold with monospaced digits: `59:59` needs
    /// 32.0pt, `9:59:59` 43.0pt, `11:59:59` 49.0pt, each given a point of slack.
    /// Safe to size from the value at layout time because the timer only counts
    /// down — the string loses characters as it ticks, never gains them.
    ///
    /// Originally a copy of `LiveActivityCustomDevicePill.countdownWidth`; the
    /// pills dropped their countdown in LA-PILL-REDESIGN, so this is the only
    /// copy now.
    private static func countdownWidth(remaining: TimeInterval) -> CGFloat {
        if remaining >= tenHours { return 50 }
        if remaining >= oneHour { return 44 }
        return 33
    }

    /// An override saved without a name is stored by `OverrideStorage` as
    /// `Override <date>`, which arrives here as a 26-character string whose only
    /// useful word is the first. Collapse it back to the word.
    ///
    /// Matching on the prefix is safe because upstream writes it as a plain
    /// literal rather than a localized one, so it is always this exact English
    /// string. The four-digit test is what keeps a genuine preset named
    /// "Override something" intact — a name a person typed is unlikely to carry
    /// a year in it, and if one does the only cost is that it reads in full.
    private func displayName(_ name: String) -> String {
        let autoPrefix = "Override "
        guard name.hasPrefix(autoPrefix),
              name.dropFirst(autoPrefix.count).range(of: #"\d{4}"#, options: .regularExpression) != nil
        else { return name }
        return String(localized: "Override", comment: "Unnamed override, Custom Live Activity chip")
    }

    /// A zero duration means indefinite, which has no end to count down to.
    private func endDate(from start: Date, minutes: Decimal) -> Date? {
        guard minutes > 0 else { return nil }
        let seconds = TimeInterval(truncating: minutes as NSNumber) * 60
        let end = start.addingTimeInterval(seconds)
        return end > Date.now ? end : nil
    }

    /// Glyph and remaining time only — the name is dropped.
    ///
    /// Carrying the name meant three elastic things competing for one row, and
    /// the name and the countdown ended up truncating each other: `Custom O…`
    /// beside `1:44…`, neither of them legible. The name is the part that can
    /// go. The glyph and colour already say which kind of adjustment is running,
    /// and the wearer is the person who started it — what a glance is actually
    /// asking is *how much longer*, which is the one thing that was being cut.
    ///
    /// The name still reaches VoiceOver through the accessibility label, so
    /// nothing is lost for anyone relying on it.
    ///
    /// Sized to match the device pills beside it: same 19pt capsule, same 10pt
    /// glyph and 10.5pt semibold text, same 3pt gap and 7pt padding. Three
    /// capsules of the same build now, rather than two plus a larger stranger.
    @ViewBuilder private func chip(name: String, icon: String, endsAt: Date?, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))

            if let endsAt {
                Text(timerInterval: Date.now ... endsAt, countsDown: true)
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(
                        width: Self.countdownWidth(remaining: endsAt.timeIntervalSinceNow),
                        alignment: .leading
                    )
            } else {
                // Runs until cancelled. Marked rather than left blank: an
                // absent countdown otherwise reads as something missing, and
                // `endDate` returns nil for two different reasons — no duration
                // set, or an end already passed — which looked identical.
                Image(systemName: "infinity")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: Self.chipHeight)
        .background(Capsule().fill(color.opacity(0.75)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName(name))
    }
}
