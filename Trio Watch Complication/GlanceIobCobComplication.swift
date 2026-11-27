import SwiftUI
import WidgetKit

/// LOCAL: GLANCE-IOBCOB (27 Nov). "Trio Glance IOB/COB": IOB over COB, the same size, in
/// the contact image's colours (insulin blue, loop yellow), with small units and a divider;
/// a zero value goes grey (mock-up option B). A plainer round alternative to the PR's "Trio IOB", which has a label, the value and a
/// status line. Unlike Glance it draws the phone's data, so it reads the shared snapshot
/// (`ComplicationStore`) and is reloaded with the shared complications by WATCH-SETTLE
/// (its kind is in `ComplicationSettle.installedKinds`).
///
/// To take this out: delete this file, its line in `TrioWatchComplicationBundle` and its
/// kind in `ComplicationSettle.installedKinds`.
enum GlanceIobCob {
    static let kind = "TrioGlanceIobCobComplication"
    /// The same colours as the contact image (`Color.insulin`, `Color.loopYellow`).
    static let insulinBlue = Color(red: 0.118, green: 0.588, blue: 0.988)
    static let carbAmber = Color(red: 1.0, green: 0.757, blue: 0.271)
}

struct GlanceIobCobProvider: TimelineProvider {
    private static let timelineStep: TimeInterval = 5 * 60
    private static let timelineSpan: TimeInterval = 2 * 60 * 60

    func placeholder(in _: Context) -> TrioGlucoseEntry {
        TrioGlucoseEntry(date: Date(), content: .placeholder(TrioGlucoseProvider.preview))
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioGlucoseEntry) -> Void) {
        guard !context.isPreview, let state = ComplicationStore.load() else {
            completion(TrioGlucoseEntry(date: Date(), content: .placeholder(TrioGlucoseProvider.preview)))
            return
        }
        completion(TrioGlucoseEntry(date: Date(), content: .reading(state)))
    }

    /// As `TrioGlucoseProvider`: entries for the loop going stale, when IOB and COB blank.
    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioGlucoseEntry>) -> Void) {
        let now = Date()
        guard let state = ComplicationStore.load() else {
            completion(Timeline(entries: [TrioGlucoseEntry(date: now, content: .placeholder(.placeholder))], policy: .never))
            return
        }
        let dates = stride(from: 0, through: Self.timelineSpan, by: Self.timelineStep).map { now.addingTimeInterval($0) }
            + state.loopFreshnessTransitionDates(after: now, within: Self.timelineSpan)
        let entries = Set(dates).sorted().map { TrioGlucoseEntry(date: $0, content: .reading(state)) }
        ComplicationRedrawLog.record(kind: "glanceIobCob", builtAt: now, state: state) // WATCH-SETTLE log
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct GlanceIobCobEntryView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: TrioGlucoseEntry

    var body: some View {
        let model = ComplicationModel(
            kind: .iob,
            state: entry.content.state,
            rendering: ComplicationRendering(
                referenceDate: entry.date,
                isPlaceholder: entry.content.isPlaceholder,
                fullColor: renderingMode == .fullColor
            )
        )
        ZStack {
            AccessoryWidgetBackground()
            GlanceIobCobContent(
                iob: model.displayedState.iob,
                cob: model.displayedState.cob,
                fullColor: renderingMode == .fullColor
            )
        }
        .widgetBackground(backgroundView: Color.clear)
    }
}

struct GlanceIobCobContent: View {
    let iob: String
    let cob: String
    let fullColor: Bool

    enum Layout {
        // 27 Nov: option B of the mock-ups. Small units and a hairline divider; a zero
        // or missing value goes grey so the eye lands on what is active. Icons (tried
        // first) only fitted with 15 pt numbers and read as clutter.
        static let valueSize: CGFloat = 15
        static let unitSize: CGFloat = 7
        static let dividerWidth: CGFloat = 26
        static let rowGap: CGFloat = 1
        static let maxRowWidth: CGFloat = 40
    }

    private static let grey = Color(white: 0.55)

    var body: some View {
        VStack(spacing: Layout.rowGap) {
            row(value: iob, unit: "U", color: GlanceIobCob.insulinBlue)
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: Layout.dividerWidth, height: 0.75)
            row(value: cob, unit: "g", color: GlanceIobCob.carbAmber)
        }
    }

    private static func isInactive(_ value: String) -> Bool {
        value == ComplicationState.missingValue || (Double(value) ?? 1) == 0
    }

    private func row(value: String, unit: String, color: Color) -> some View {
        let inactive = Self.isInactive(value)
        let tint = !fullColor ? Color.primary : inactive ? Self.grey : color
        return HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value)
                .font(.system(size: Layout.valueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
            if value != ComplicationState.missingValue {
                Text(unit)
                    .font(.system(size: Layout.unitSize, weight: .semibold, design: .rounded))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(tint)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .frame(maxWidth: Layout.maxRowWidth)
        .widgetAccentable()
    }
}

struct TrioGlanceIobCobComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceIobCob.kind, provider: GlanceIobCobProvider()) { entry in
            GlanceIobCobEntryView(entry: entry)
        }
        .configurationDisplayName(String(
            localized: "Trio Glance IOB/COB",
            comment: "Name of the watch complication showing insulin and carbs on board"
        ))
        .description(String(
            localized: "Insulin on board over carbs on board, the same size, in blue and amber.",
            comment: "Description of the IOB/COB watch complication"
        ))
        .supportedFamilies([.accessoryCircular])
    }
}
