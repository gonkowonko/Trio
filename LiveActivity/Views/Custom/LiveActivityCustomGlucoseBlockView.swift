import ActivityKit
import SwiftUI
import WidgetKit

/// The Custom layout's glucose readout: the value at size, the trend arrow
/// beside it, and the delta and reading age on the line beneath.
///
/// Replaced `LiveActivityCustomBobbleView` in the composition. The ring was a
/// faithful copy of the home screen's bobble, but it spent a 104pt square on one
/// number; this block says the same thing in half the width, which is what pays
/// for the chart's axes and the full-width tile row. The bobble view was deleted
/// on 2026-09-14 once nothing used it; a copy is in `bobble-view-rollback/` at
/// the project root.
///
/// The line under the value carries delta and age rather than the unit. The unit
/// is a constant — it tells you nothing you didn't know a second ago — whereas
/// "is it moving, and is this reading current" is the reason to glance at all.
struct LiveActivityCustomGlucoseBlockView: View {
    let glucose: String
    /// Trend arrow as the app renders it elsewhere (`↗︎`, `→`, …). `nil` when
    /// the CGM reports no direction.
    let direction: String?
    let delta: String
    /// Newest reading in the chart, not the determination time.
    let lastReading: Date?
    let glucoseColor: Color

    /// Width of the whole left-hand column, gutter included — the block owns the
    /// space right up to the chart's edge rather than leaving a separate stack
    /// spacing beside it. That is what lets the readout centre itself in the
    /// full gap instead of in a frame that stops short of it.
    static let columnWidth: CGFloat = 130

    private var isFresh: Bool {
        LiveActivityCustomFormat.isReadingFresh(lastReading: lastReading)
    }

    /// LA-BG-STALENESS: one CGM cycle past due, `GlucoseFreshness.agingInterval`. That
    /// type is compiled into the app target only, so the number is copied here.
    private static let readingAgingWindow: TimeInterval = 6 * 60

    /// LA-BG-STALENESS: the reading is a cycle late, so the value, arrow and delta turn
    /// grey — the same grey the dashes use once `isFresh` masks them at 12 minutes.
    ///
    /// Grey rather than faded. A 0.55 fade (the contact image's `.aging` opacity) was
    /// tried first and barely showed on device: a saturated green over the Live
    /// Activity's frosted glass keeps its colour at half strength, where the contact
    /// image's dark bitmap does not. Grey reads as "not current" on any wallpaper, at
    /// the cost of the in-range colour for those six minutes.
    ///
    /// Computed from `Date()` at draw time, which is only right when a draw actually
    /// happens, so both boundaries have one arranged. ActivityKit redraws at
    /// `staleDate` (the determination's date + 360s, so never before the reading turns
    /// 6 minutes old) without the app awake, and `scheduleReadingExpiryRefresh` pushes
    /// at 12 minutes, landing at the app's next wake if it is suspended.
    ///
    /// Judged from the reading's own age, not `context.isStale`: `staleDate` follows
    /// the determination, so a failing loop with a working CGM would otherwise dim a
    /// reading that is perfectly current.
    private var isAging: Bool {
        guard let lastReading, isFresh else { return false }
        return Date.now.timeIntervalSince(lastReading) >= Self.readingAgingWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Centred, not baseline-aligned. Sharing a baseline is right when two
            // runs of text are read as one line, but the arrow is a symbol beside
            // a number rather than a word after a word — sat on the digits'
            // baseline its much smaller ink ends up 5.3pt below their centre and
            // reads as having slipped.
            //
            // Box-centring gets within 0.4pt of centring the *ink*, close enough
            // that a measured offset would only add a constant to maintain. It
            // also holds for every arrow the CGM emits: `↑ ↗︎ → ↘︎ ↓ ↔︎` and the
            // doubles all carry an ink centre within 0.1pt of each other, so the
            // arrow does not hop as the trend changes.
            HStack(alignment: .center, spacing: 4) {
                Text(isFresh ? glucose : "– –")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(isFresh && !isAging ? glucoseColor : Color.secondary) // LA-BG-STALENESS
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if isFresh, let direction, !direction.isEmpty {
                    Text(direction)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(isAging ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.85)))
                }
            }

            subline
        }
        // Collapse to the content's own width first. Without this the stack
        // spreads to fill the column, and centring it then moves nothing —
        // there is no slack left to distribute. Horizontal only: the vertical
        // axis still needs to flex with the row.
        .fixedSize(horizontal: true, vertical: false)
        // The two lines stay left-aligned to each other; it is the pair that is
        // centred, so the delta still hangs off the value rather than floating
        // under its middle.
        .frame(width: Self.columnWidth, alignment: .center)
    }

    /// Width reserved for the reading age.
    ///
    /// The age is a system-rendered date run so that it advances between pushes,
    /// and those report an ideal width SwiftUI cannot measure. Unframed, that
    /// ideal propagates up through the block's `fixedSize` and the readout takes
    /// the chart's space with it — the same failure the device pill's countdown
    /// produced.
    ///
    /// Now that the age has a line to itself rather than sharing one with the
    /// delta, it can afford the readable wording: `.relative` renders
    /// `1 min, 45 secs` at 91pt, which is why it had to be the terser `.timer`
    /// while the two shared 88pt. 96pt covers that and leaves the column its
    /// 130pt.
    private static let ageWidth: CGFloat = 96

    /// LA-SUBLINE-INSET (2026-09-24): the delta and age lines sit this far in from
    /// the value's leading edge. Their ink already started within ~1pt of the
    /// digits', but a 36pt rounded `6` (or `1`, `9`…) reads as starting inside its
    /// curve, so the flush 14pt lines looked as if they hung out to the left.
    /// Optical alignment, not metric — tune by eye on device.
    private static let sublineInset: CGFloat = 3

    /// Delta and reading age, each on a line of its own.
    ///
    /// They shared one line while the header carried the loop status and space
    /// was scarce. With the header gone the column has the height, and stacking
    /// them means neither has to be abbreviated to fit beside the other.
    ///
    /// The delta still disappears once the reading is stale: a difference
    /// between two old readings describes a trend that has already stopped
    /// being true, and the age is the only honest fact left.
    @ViewBuilder private var subline: some View {
        let trimmed = delta.trimmingCharacters(in: .whitespaces)

        VStack(alignment: .leading, spacing: 1) {
            if isFresh, !trimmed.isEmpty {
                Text(trimmed)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isAging ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.9)))
            }

            if let lastReading {
                // `.relative` is a choice between three self-updating styles,
                // all rendered and compared rather than assumed. At 2 min 19 s:
                //
                //   .relative   2 min, 19 secs   ticks every second
                //   .offset     +2 minutes      ticks once a minute
                //   .timer      2:19            ticks every second
                //
                // `.offset` is the only one with minute granularity, and only
                // became usable once the header was removed — `looped +2
                // minutes ago` was unreadable in a sentence. Its drawback here
                // is the sign: the delta directly above already starts with a
                // `+`, so the column would stack two plus signs meaning
                // different things. Swapping styles is this one line.
                //
                // LA-AGE-MINUTES (2026-09-23): now minute-granular. `.relative`
                // changed every second for as long as the banner was on screen —
                // the only per-second redraw the Custom layout always carries, and
                // one Simple and Detailed do not have at all. Suspected of the
                // branch's extra drain, which Trio's logs cannot see because the
                // lock screen is drawn outside the app. This is still a
                // system-rendered format that advances with no push; it just has
                // nothing to change between minutes. `sign: .never` avoids the
                // `+` that ruled out plain `.offset`. The `else` is the old line,
                // kept only because the target's minimum is 17.6. One field so an hour-old
                // reading reads `1 hour` (37pt) rather than `1 hour, 2 minutes` (102pt,
                // past `ageWidth`); under an hour it is `2 minutes`, 59–65pt.
                Group {
                    if #available(iOS 18.0, *) {
                        Text(
                            .currentDate,
                            format: .offset(to: lastReading, allowedFields: [.hour, .minute], maxFieldCount: 1, sign: .never)
                        )
                    } else {
                        Text(lastReading, style: .relative)
                    }
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.ageWidth, alignment: .leading)
            } else {
                Text(verbatim: "--")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.leading, Self.sublineInset) // LA-SUBLINE-INSET
    }
}
