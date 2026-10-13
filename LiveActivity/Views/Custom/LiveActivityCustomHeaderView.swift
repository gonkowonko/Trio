import ActivityKit
import SwiftUI
import WidgetKit

/// The Custom layout's top line: a loop-health dot, the app name, and how long
/// ago the loop last completed.
///
/// The dot carries loop status so it doesn't need a tile of its own. Thresholds
/// match `LoopView` on the home screen — green within 5 minutes, amber within
/// 10, red beyond — so both surfaces escalate at the same moment.
struct LiveActivityCustomHeaderView: View {
    let loopStatus: LiveActivityAttributes.LoopStatus?
    /// Dropped when the header row is sharing its width with an adjustment
    /// chip. The wordmark is the one thing on this line that carries no state,
    /// so it is the first thing to give way rather than truncating a loop age
    /// or an override name.
    var showsWordmark: Bool = true

    private static let freshWindow: TimeInterval = 5 * 60
    private static let lateWindow: TimeInterval = 10 * 60

    private var age: TimeInterval? {
        guard let date = loopStatus?.lastLoopDate, date != .distantPast else { return nil }
        return Date().timeIntervalSince(date)
    }

    private var color: Color {
        guard let status = loopStatus else { return .secondary }
        // An open loop is not "unhealthy", it is switched off — neutral, the
        // same call `LoopView` makes.
        guard status.isClosedLoop else { return .secondary }
        if status.isManualTempBasal { return .purple }
        guard let age else { return .secondary }
        if age <= Self.freshWindow { return LiveActivityCustomPalette.green }
        if age <= Self.lateWindow { return .orange }
        return LiveActivityCustomPalette.red
    }

    /// A `Text` rather than a `String`, so the elapsed time can be interpolated
    /// as a system-rendered date run.
    ///
    /// This was a computed string built from `Date()` at render time, which
    /// looked equivalent and is not: a Live Activity's view body is only
    /// re-evaluated when something pushes new content, and pushes arrive with
    /// the glucose cycle — roughly every five minutes. So the readout sat frozen
    /// on whatever it said at the last push, showing "0 m" for minutes at a
    /// stretch. Interpolating the date with a style hands the run to the system,
    /// which advances it without any update being sent.
    ///
    /// Kept as one interpolated key rather than three concatenated `Text`s so it
    /// stays a single translatable phrase and languages can order it themselves.
    private var label: Text {
        guard let status = loopStatus else {
            return Text("no loop data", comment: "Custom Live Activity loop status")
        }
        guard status.isClosedLoop else {
            return Text("open loop", comment: "Custom Live Activity loop status")
        }
        if status.isManualTempBasal {
            return Text("manual temp basal", comment: "Custom Live Activity loop status")
        }
        guard let age, let date = status.lastLoopDate else {
            return Text("no loop data", comment: "Custom Live Activity loop status")
        }
        // The wording and the dot's colour still switch only on a re-render, so
        // an overdue loop keeps the healthy phrasing until the next push. The
        // elapsed figure beside it is right either way, which is the part being
        // read.
        return age > Self.lateWindow
            ? Text("not looped \(date, style: .relative)", comment: "Custom Live Activity loop status, overdue")
            : Text("looped \(date, style: .relative) ago", comment: "Custom Live Activity loop status, healthy")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            if showsWordmark {
                Text(verbatim: "TRIO")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            label
                .font(.caption2)
                .foregroundStyle(color == .secondary ? Color.secondary : color)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}
