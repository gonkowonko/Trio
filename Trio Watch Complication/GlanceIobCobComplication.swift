import SwiftUI
import WidgetKit

/// LOCAL: GLANCE-IOBCOB (27 Nov). "Trio Glance IOB/COB": IOB over COB, the same size, in
/// the contact image's colours (insulin blue, loop yellow), each with the watch app's icon (syringe, fork and knife). A
/// plainer round alternative to the PR's "Trio IOB", which has a label, the value and a
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
        // 27 Nov sim (46 mm): with icons, "1.85" only fitted at 15 pt, too small to
        // glance at; the colours already say which is which, so the icons are off
        // and the numbers take the width.
        static let showsIcons = false
        static let valueSize: CGFloat = 20
        static let iconSize: CGFloat = 9
        static let iconGap: CGFloat = 2
        static let rowGap: CGFloat = -2
    }

    var body: some View {
        VStack(spacing: Layout.rowGap) {
            row(symbol: "syringe.fill", value: iob, color: GlanceIobCob.insulinBlue)
            row(symbol: "fork.knife", value: cob, color: GlanceIobCob.carbAmber)
        }
        .padding(.horizontal, 4)
    }

    private func row(symbol: String, value: String, color: Color) -> some View {
        let tint = fullColor ? color : Color.primary
        return HStack(spacing: Layout.iconGap) {
            if Layout.showsIcons {
                Image(systemName: symbol)
                    .font(.system(size: Layout.iconSize, weight: .bold))
                    .foregroundStyle(tint)
                    .widgetAccentable()
            }
            Text(value)
                .font(.system(size: Layout.valueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .widgetAccentable()
        }
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
