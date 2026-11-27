import SwiftUI
import WidgetKit

/// LOCAL: GLANCE-LOOP (27 Nov). "Trio Glance Loop": a round loop status with a ring that
/// drains over the five minutes after each loop, the phone icon in the loop's colour and
/// the loop's age ("2m") instead of its clock time. Late: a full amber ring; overdue: a
/// full red ring and a struck-through phone. Chosen from mock-ups (option E) over the PR's
/// "Trio Loop", which is unchanged.
///
/// The ring and age move between reloads on their own: the timeline carries an entry every
/// 30 s for 15 min after the loop, then every minute to an hour, all drawn from the one
/// stored snapshot. That costs no reloads. Like the other shared complications it draws
/// the phone's data (`ComplicationStore`) and is reloaded by WATCH-SETTLE (its kind is in
/// `ComplicationSettle.installedKinds`).
///
/// To take this out: delete this file, its line in `TrioWatchComplicationBundle` and its
/// kind in `ComplicationSettle.installedKinds`.
enum GlanceLoop {
    static let kind = "TrioGlanceLoopComplication"
    /// The ring is empty when the loop turns late (`ComplicationState` loopLag + 5 min).
    static let drainSpan: TimeInterval = 5.5 * 60
}

struct GlanceLoopEntry: TimelineEntry {
    let date: Date
    let loopDate: Date?
    let state: ComplicationState
}

struct GlanceLoopProvider: TimelineProvider {
    private static let fineStep: TimeInterval = 30
    private static let fineSpan: TimeInterval = 15 * 60
    private static let coarseSpan: TimeInterval = 60 * 60
    private static let totalSpan: TimeInterval = 2 * 60 * 60

    func placeholder(in _: Context) -> GlanceLoopEntry {
        Self.sampleEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceLoopEntry) -> Void) {
        guard !context.isPreview, let state = ComplicationStore.load() else {
            completion(Self.sampleEntry())
            return
        }
        completion(GlanceLoopEntry(date: Date(), loopDate: state.loopDate, state: state))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<GlanceLoopEntry>) -> Void) {
        let now = Date()
        guard let state = ComplicationStore.load() else {
            completion(Timeline(entries: [GlanceLoopEntry(date: now, loopDate: nil, state: .placeholder)], policy: .never))
            return
        }
        var dates: [Date] = [now]
        if let loop = state.loopDate {
            var offset: TimeInterval = 0
            while offset <= Self.coarseSpan {
                let date = loop.addingTimeInterval(offset)
                if date > now, date < now.addingTimeInterval(Self.totalSpan) { dates.append(date) }
                offset += offset < Self.fineSpan ? Self.fineStep : 60
            }
            dates += state.loopFreshnessTransitionDates(after: now, within: Self.totalSpan)
        }
        let entries = Set(dates).sorted().map { GlanceLoopEntry(date: $0, loopDate: state.loopDate, state: state) }
        ComplicationRedrawLog.record(kind: "glanceLoop", builtAt: now, state: state) // WATCH-SETTLE log
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func sampleEntry() -> GlanceLoopEntry {
        let now = Date()
        return GlanceLoopEntry(date: now, loopDate: now.addingTimeInterval(-60), state: TrioGlucoseProvider.preview)
    }
}

struct GlanceLoopEntryView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: GlanceLoopEntry

    var body: some View {
        GlanceLoopContent(
            freshness: freshness,
            age: entry.loopDate.map { max(0, entry.date.timeIntervalSince($0)) },
            fullColor: renderingMode == .fullColor
        )
        .widgetBackground(backgroundView: Color.clear)
    }

    private var freshness: ComplicationState.LoopFreshness {
        guard entry.loopDate != nil else { return .unknown }
        var state = entry.state
        state.loopDate = entry.loopDate
        return state.loopFreshness(at: entry.date)
    }
}

struct GlanceLoopContent: View {
    let freshness: ComplicationState.LoopFreshness
    /// Seconds since the loop, or nil if it never ran.
    let age: TimeInterval?
    let fullColor: Bool

    enum Layout {
        static let ringWidth: CGFloat = 4
        static let ringInset: CGFloat = 2
        static let iconSize: CGFloat = 15
        static let ageSize: CGFloat = 13
    }

    private var color: Color {
        guard fullColor else { return .primary }
        switch freshness {
        case .fresh: return GlancePalette.green
        case .late: return GlancePalette.amber
        case .overdue: return GlancePalette.red
        case .unknown: return GlancePalette.dim
        }
    }

    /// Full just after a loop, empty as it turns late; full again (in amber or red) after.
    private var fill: Double {
        guard let age else { return 0 }
        guard freshness == .fresh else { return 1 }
        return min(1, max(0, 1 - age / GlanceLoop.drainSpan))
    }

    private var ageText: String {
        guard let age else { return "– –" }
        let minutes = Int(age / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .stroke(color.opacity(0.25), lineWidth: Layout.ringWidth)
                .padding(Layout.ringInset)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(color, style: StrokeStyle(lineWidth: Layout.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(Layout.ringInset)
                .widgetAccentable()
            VStack(spacing: 0) {
                Image(systemName: freshness == .overdue ? "iphone.slash" : "iphone")
                    .font(.system(size: Layout.iconSize, weight: .semibold))
                    .foregroundStyle(color)
                    .widgetAccentable()
                Text(ageText)
                    .font(.system(size: Layout.ageSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fullColor ? Color.white : Color.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
    }
}

struct TrioGlanceLoopComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceLoop.kind, provider: GlanceLoopProvider()) { entry in
            GlanceLoopEntryView(entry: entry)
        }
        .configurationDisplayName(String(
            localized: "Trio Glance Loop",
            comment: "Name of the watch complication showing loop status with a draining ring"
        ))
        .description(String(
            localized: "Loop status: a ring that empties over the five minutes after each loop, and the loop's age.",
            comment: "Description of the Glance loop watch complication"
        ))
        .supportedFamilies([.accessoryCircular])
    }
}
