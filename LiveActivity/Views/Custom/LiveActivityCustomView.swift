import ActivityKit
import SwiftUI
import WidgetKit

/// The Custom lock-screen layout.
///
/// Three stacked rows rather than two columns:
///
/// 1. **Header** — loop dot and age on the left, the active adjustment and the
///    device pills on the right. Everything that is a *status* lives here.
/// 2. **Reading** — the glucose value, trend and delta, with the three-hour
///    chart taking the rest of the width.
/// 3. **Values** — IOB, COB and basal across the full banner, under a hairline.
///
/// The rows are fixed-height and sum to just under what the lock screen will
/// give a Live Activity, so the banner does not resize as content comes and
/// goes — an override starting or a pill going amber changes what a row says,
/// never how tall it is.
///
/// Everything here is confined to `Views/Custom`: it shares data types with the
/// rest of the widget but no view code, so the whole layout can be removed by
/// deleting this folder and the `.custom` case that selects it.
struct LiveActivityCustomView: View {
    var context: ActivityViewContext<LiveActivityAttributes>

    private var state: LiveActivityAttributes.ContentState { context.state }
    private var detail: LiveActivityAttributes.ContentAdditionalState { context.state.detailedViewState }
    private var isMgdL: Bool { state.unit == "mg/dL" }

    /// LA-STALE-AMBER: the loop dot, allowed to go amber without a push.
    ///
    /// The pushed severity is only as current as the last push, and the timed push
    /// that should turn the dot amber (`scheduleLoopSeverityRefresh`) is a
    /// `Task.sleep` in the app, which cannot fire while iOS has the app suspended.
    /// Measured on 12–13 Sep 2026: 21 of 23 amber crossings pushed 65–266s late,
    /// because a missed CGM reading is also what would have woken the app.
    ///
    /// `staleDate` is the one clock ActivityKit runs without the app, and the body is
    /// re-evaluated when it passes. So once `isStale` is set, and only then, the loop's
    /// age is checked against `Date()` here. At any other render the same check could
    /// not be trusted to re-run, which is why severity is pushed in the first place.
    ///
    /// Escalates `.ok` only: open loop and manual temp are modes rather than ages, and
    /// a pushed late or overdue is already right. `staleDate` is the determination's
    /// date + 360s, so this goes amber as long as the loop completed within 30s of its
    /// determination (observed 1–10s). The age check stops a false amber if a newer loop
    /// finished without a newer determination reaching the state.
    ///
    /// LA-TINT: internal rather than private, so `LiveActivityView` can hand the same
    /// value to the banner tint and the two can never disagree.
    var loopDotState: LiveActivityCustomPalette.LoopState {
        let pushed = LiveActivityCustomPalette.loopState(for: detail.loopStatus)
        guard context.isStale, pushed == .ok,
              let lastLoopDate = detail.loopStatus?.lastLoopDate
        else { return pushed }

        // The same 30s lag as `LoopFreshness`, which is not compiled into this target.
        let age = Date.now.timeIntervalSince(lastLoopDate) - 30
        if age > LiveActivityCustomPalette.loopLateWindow { return .overdue }
        if age > LiveActivityCustomPalette.loopFreshWindow { return .late }
        return pushed
    }

    /// Row heights, and the gaps around the value row.
    ///
    /// These have to be budgeted, not just chosen. The lock screen caps the
    /// banner at around 152pt; ask for more and iOS does not clip, it *squeezes*
    /// — and the first thing to collapse is the 14pt padding under the last row.
    /// That is what made the value row look pushed up against the hairline: the
    /// space below it was quietly being eaten to make everything else fit.
    ///
    /// So the rows below sum to about 123pt, which leaves the banner padding
    /// intact and the gaps predictable. Raising any of them costs another row
    /// the same amount.
    ///
    /// Removing the header row returned 23pt to that budget — the first slack
    /// this layout has had, having previously totalled 151pt against the 152pt
    /// ceiling. It is spent here on the reading row, which now stacks the status
    /// capsules over the chart on one side and three lines of readout on the
    /// other, and on the 3pt border, which costs 6pt across the banner.
    private static let stackSpacing: CGFloat = 3
    /// Height of the capsule row above the chart. Matches the pills and chip,
    /// which are both 19pt.
    private static let statusHeight: CGFloat = 19
    /// The chart takes what is left of this after the status capsules above it,
    /// so every point added here goes straight to the plot.
    ///
    /// Raised from 80 once the budget was counted properly. The border is drawn
    /// with `.overlay`, which paints over the content without participating in
    /// layout — so it costs nothing, and an earlier version of this comment that
    /// charged 6pt for it was simply wrong. That left 10pt unspent.
    ///
    /// Stopping short of the ceiling deliberately: it is approximate, and the
    /// one time this layout reached it iOS did not clip but quietly ate the
    /// banner's own bottom padding, which is a much harder fault to spot than a
    /// short chart.
    ///
    /// Back to 86 now the status bar runs down the leading edge instead of along
    /// the foot: a vertical bar takes width from the padding and no height at
    /// all, so the 4pt the foot version borrowed returns to the chart.
    private static let readingHeight: CGFloat = 86
    private static let valuesHeight: CGFloat = 32
    private static let valuesTopGap: CGFloat = 2

    /// Trims the banner's own bottom padding, which the shared
    /// `addLiveActivityModifiers` sets to 14pt on all four sides. Left alone it
    /// puts far more air under the value row than the hairline puts above it,
    /// and it cannot be balanced from above without spending the chart's
    /// height. Negative padding is the only way to reach it without changing
    /// the modifier every other layout shares.
    private static let bottomTrim: CGFloat = -7

    /// Raises the glucose block off the row's true centre.
    ///
    /// Box-centred and optically centred are not the same thing here, and going
    /// to three lines did not fix it as I assumed — the asymmetry is inside the
    /// *fonts*, not the line count. Measured against the real faces: the 36pt
    /// rounded value carries 8.86pt of empty ascent above the digits' ink, while
    /// the 12.5pt age below leaves only 0.35pt beneath its own. That is 8.5pt
    /// more air above the readout than below it, so centring the box leaves the
    /// visible text sitting low against the hairline.
    ///
    /// Half the difference re-centres the ink. An offset rather than padding,
    /// so the row's height and the chart beside it are untouched.
    private static let glucoseOpticalLift: CGFloat = 4

    /// Same treatment the other layouts use: the dynamic scheme is widened to a
    /// fixed 55–220 span so the hue ramp has room, while the static scheme uses
    /// the user's own thresholds.
    private var glucoseColor: Color {
        let hasStaticColorScheme = state.glucoseColorScheme == "staticColor"
        let hardCodedLow = isMgdL ? Decimal(55) : 55.asMmolL
        let hardCodedHigh = isMgdL ? Decimal(220) : 220.asMmolL

        return Color.getDynamicGlucoseColor(
            glucoseValue: Decimal(string: state.bg) ?? 100,
            highGlucoseColorValue: hasStaticColorScheme
                ? (isMgdL ? state.highGlucose : state.highGlucose.asMmolL) : hardCodedHigh,
            lowGlucoseColorValue: hasStaticColorScheme
                ? (isMgdL ? state.lowGlucose : state.lowGlucose.asMmolL) : hardCodedLow,
            targetGlucose: isMgdL ? state.target : state.target.asMmolL,
            glucoseColorScheme: state.glucoseColorScheme
        )
    }

    /// Newest reading in the chart. Drives the value block's age readout and its
    /// staleness masking; `state.date` is the determination time, not this.
    private var lastReadingDate: Date? {
        detail.chart.map(\.date).max()
    }

    var body: some View {
        if state.isInitialState {
            Text("Live Activity Expired. Open Trio to Refresh")
                .minimumScaleFactor(0.01)
        } else {
            VStack(spacing: Self.stackSpacing) {
                readingRow

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)

                LiveActivityCustomTilesView(
                    iob: detail.iob,
                    cob: detail.cob,
                    basal: detail.basal
                )
                .frame(height: Self.valuesHeight)
                .padding(.top, Self.valuesTopGap)
            }
            .padding(.bottom, Self.bottomTrim)
        }
    }

    /// Adjustment chip and device pills, right-aligned above the chart.
    ///
    /// This was the header row, and carried a loop dot, the `TRIO` wordmark and
    /// the loop age alongside these. All three are gone: the banner's border now
    /// carries loop health, which says the same thing from the edge of the
    /// screen and costs no content space at all. What it does not carry is the
    /// precise age — a deliberate trade, since the bands (looping / behind /
    /// overdue) are what a glance is actually reading.
    ///
    /// Dropping them also ends the crowding that made the chip truncate to
    /// `Custom O…` beside a `1:44…` countdown: these two now have the row to
    /// themselves.
    private var statusRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            LiveActivityCustomAdjustmentChipView(
                isOverrideActive: detail.isOverrideActive,
                overrideName: detail.overrideName,
                overrideDate: detail.overrideDate,
                overrideDuration: detail.overrideDuration,
                isTempTargetActive: detail.isTempTargetActive,
                tempTargetName: detail.tempTargetName,
                tempTargetDate: detail.tempTargetDate,
                tempTargetDuration: detail.tempTargetDuration
            )
            .layoutPriority(1)

            LiveActivityCustomDevicePillsView(
                cgm: detail.cgmLifecycle,
                pump: detail.pumpLifecycle,
                cgmStatus: detail.cgmStatus,
                pumpStatus: detail.pumpStatus
            )
            .layoutPriority(2)

            // Trailing the devices, and outside their `HStack` so it keeps the
            // row's own 6pt spacing rather than the pills' tighter 4pt — the
            // gap is what marks it as a different kind of thing from the pair
            // beside it.
            LiveActivityCustomLoopDotView(
                state: loopDotState
            )
            .layoutPriority(2)
        }
        .frame(height: Self.statusHeight)
    }

    /// The readout on the left, and the status row stacked over the chart on the
    /// right.
    ///
    /// The two used to be separate rows, which meant the pills reserved a full
    /// banner-width strip for two capsules. Nesting them puts the freed height
    /// into the glucose block — which now needs it, with the delta and the
    /// reading age on lines of their own — and into the chart.
    private var readingRow: some View {
        // No spacing: the glucose block's own width carries the gutter, so the
        // chart's left edge is exactly `columnWidth` from the banner's content
        // edge and the readout can be centred across that whole span.
        HStack(alignment: .center, spacing: 0) {
            LiveActivityCustomGlucoseBlockView(
                glucose: state.bg,
                direction: state.direction,
                delta: state.change,
                lastReading: lastReadingDate,
                glucoseColor: glucoseColor
            )
            .offset(y: -Self.glucoseOpticalLift)

            VStack(spacing: Self.stackSpacing) {
                statusRow

                LiveActivityCustomChartView(
                    chart: detail.chart,
                    isMgdL: isMgdL,
                    low: state.lowGlucose,
                    high: state.highGlucose,
                    target: state.target,
                    glucoseColorScheme: state.glucoseColorScheme,
                    // LA-TINT: same states that tint the banner.
                    isTinted: loopDotState == .late || loopDotState == .overdue
                )
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: Self.readingHeight)
    }
}
