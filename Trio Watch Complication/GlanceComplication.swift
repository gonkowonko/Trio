import Charts
import SwiftUI
import WidgetKit

// GLANCE: "Trio Glance", a rectangular complication showing only the watch's
// own G7 data: glucose + arrow in Trio's glucose colour, the delta stacked over
// "3m ago" on the right, and a full-width three-hour graph of dots under it.
//
// No loop, IOB or COB, by Gary's choice (24 Nov 2026). Those come from the
// phone, and the newest the watch can know at each G7 wake is the previous
// cycle's: the phone loops a few seconds after the reading, and its result
// can't wake the watch. The phone's contact-image complication carries them
// instead, since the phone redraws that as soon as it loops.
//
// To remove it, delete this file and the two `GLANCE` lines (the bundle entry
// in TrioWatchComplication.swift and the reload kind in WatchState.swift).

enum GlanceComplication {
    /// Also listed in `WatchState.reloadInstalledComplications()`; the two must match.
    static let kind = "TrioGlanceComplication"
}

// MARK: - Timeline

struct GlanceEntry: TimelineEntry {
    let date: Date
    let state: ComplicationState
    let isPlaceholder: Bool
}

/// Entries every minute for the first hour after the reading, then every five
/// minutes to two hours, so the reading age counts up by the minute: watchOS
/// 10.6 has no compact self-updating "4m", so the timeline steps it.
struct GlanceProvider: TimelineProvider {
    private static let minuteSpan: TimeInterval = 60 * 60
    private static let totalSpan: TimeInterval = 2 * 60 * 60

    func placeholder(in _: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), state: Self.sample, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        guard !context.isPreview, let state = ComplicationStore.load() else {
            completion(GlanceEntry(date: Date(), state: Self.sample, isPlaceholder: context.isPreview))
            return
        }
        completion(GlanceEntry(date: Date(), state: state, isPlaceholder: false))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        guard let state = ComplicationStore.load() else {
            completion(Timeline(entries: [GlanceEntry(date: now, state: .placeholder, isPlaceholder: true)], policy: .never))
            return
        }

        let anchor = state.date
        var dates: [Date] = [now]
        var offset = (now.timeIntervalSince(anchor) / 60).rounded(.down) * 60 + 60
        while anchor.addingTimeInterval(offset) < now.addingTimeInterval(Self.totalSpan) {
            dates.append(anchor.addingTimeInterval(offset))
            offset += offset < Self.minuteSpan ? 60 : 5 * 60
        }
        dates += state.staleTransitionDates(after: now, within: Self.totalSpan)

        let entries = Set(dates).sorted().map { GlanceEntry(date: $0, state: state, isPlaceholder: false) }
        GlanceRedrawLog.record(builtAt: now, readingDate: state.date)
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static var sample: ComplicationState {
        ComplicationState.sample(units: ComplicationStore.load()?.units ?? ComplicationState.defaultUnits)
    }
}

/// LOCAL: GLANCE-REDRAW-LOG. The extension can't reach the phone, so each
/// timeline WidgetKit asks for is noted in the app group, and the watch app
/// writes the notes into its log on its next wake (WatchState
/// `logGlanceRedraws`). Shows whether a reload request was acted on, and how
/// long after the reading. Remove this enum, its call in `getTimeline` and
/// the watch-side reader to take it out.
enum GlanceRedrawLog {
    static let key = "GlanceComplication.redraws"
    private static let limit = 60

    static func record(builtAt: Date, readingDate: Date) {
        guard let defaults = ComplicationStore.defaults else { return }
        var notes = defaults.array(forKey: key) as? [[Double]] ?? []
        notes.append([builtAt.timeIntervalSince1970, readingDate.timeIntervalSince1970])
        defaults.set(Array(notes.suffix(limit)), forKey: key)
    }
}

enum GlancePalette {
    static let green = Color(red: 0.435, green: 0.812, blue: 0.592)
    static let red = Color(red: 0.922, green: 0.341, blue: 0.341)
    static let amber = Color(red: 0.98, green: 0.72, blue: 0.24)
    static let yellow = Color(red: 0.949, green: 0.788, blue: 0.298)

    /// Red under the low limit, yellow over the high one, green between.
    static func glucose(_ value: Double, band: ClosedRange<Double>) -> Color {
        if value < band.lowerBound { return red }
        if value > band.upperBound { return yellow }
        return green
    }
}

/// Trio's own glucose colours, from the colour steps the phone sends for PR
/// 1809's ring gauge (`ComplicationState.ringStops`). They follow the phone's
/// Glucose Color Scheme setting: hard steps at the low and high limits for
/// static, 13 hue steps for dynamic. Each step sits on the gauge's mg/dL scale.
/// Between steps the colour is interpolated, the way the gauge's own gradient
/// does. With no steps (an older phone build) it falls back to the fixed
/// red/green/yellow of `GlancePalette.glucose`.
struct GlanceColorScale {
    private struct Stop {
        let location: Double
        let red, green, blue: Double
    }

    private let stops: [Stop]
    private let isMmol: Bool
    private let band: ClosedRange<Double>

    init(state: ComplicationState) {
        isMmol = state.isMmol
        band = state.inRangeBand
        stops = (state.ringStops ?? []).compactMap { stop in
            var digits = stop.colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
            if digits.hasPrefix("#") { digits.removeFirst() }
            guard digits.count == 6, let value = UInt64(digits, radix: 16) else { return nil }
            return Stop(
                location: stop.location,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
        .sorted { $0.location < $1.location }
    }

    /// `value` in the display unit, as everything in `ComplicationState` is.
    func color(for value: Double) -> Color {
        guard let first = stops.first, let last = stops.last else { return GlancePalette.glucose(value, band: band) }
        let range = WatchComplicationDefaults.gaugeRangeMgdl
        let mgdl = isMmol ? value * WatchComplicationDefaults.mgdlPerMmol : value
        let location = min(max((mgdl - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)

        if location <= first.location { return Color(red: first.red, green: first.green, blue: first.blue) }
        if location >= last.location { return Color(red: last.red, green: last.green, blue: last.blue) }
        // Static schemes repeat a location to make a hard edge; taking the last
        // stop at or below the value lands on the colour above that edge.
        guard let lowerIndex = stops.lastIndex(where: { $0.location <= location }) else {
            return Color(red: first.red, green: first.green, blue: first.blue)
        }
        let lower = stops[lowerIndex]
        let upper = stops[min(lowerIndex + 1, stops.count - 1)]
        let gap = upper.location - lower.location
        let t = gap > 0 ? (location - lower.location) / gap : 0
        return Color(
            red: lower.red + (upper.red - lower.red) * t,
            green: lower.green + (upper.green - lower.green) * t,
            blue: lower.blue + (upper.blue - lower.blue) * t
        )
    }
}

// MARK: - View

struct GlanceEntryView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: GlanceEntry

    var body: some View {
        GlanceContent(
            model: ComplicationModel(
                kind: .glucose,
                state: entry.state,
                rendering: ComplicationRendering(
                    referenceDate: entry.date,
                    isPlaceholder: entry.isPlaceholder,
                    fullColor: renderingMode == .fullColor
                )
            )
        )
        .widgetAccentable()
        .widgetBackground(backgroundView: Color.clear)
    }
}

struct GlanceContent: View {
    let model: ComplicationModel

    private var state: ComplicationState { model.displayedState }

    /// From the reading and the limits, not the snapshot's `glucoseColorHex`:
    /// Trio stores white for any in-range reading, on the phone and on the
    /// watch's own G7 path alike.
    private var glucoseColor: Color {
        if model.isStale { return ComplicationModel.staleText }
        guard model.fullColor else { return .primary }
        guard let value = state.glucoseValue, !model.isPlaceholder else { return state.glucoseColor }
        return GlanceColorScale(state: state).color(for: value)
    }

    /// The delta with a true minus sign, the same width as "+" and easier to
    /// read in rounded type than the hyphen the snapshot carries, and a thin
    /// space after the sign: at 20 pt semibold the minus all but touched the
    /// first digit (seen on device 2026-11-24). "+" gets the same space so the
    /// two line up.
    private var deltaText: String {
        let delta = state.delta
        if delta.hasPrefix("-") { return "\u{2212}\u{2009}" + delta.dropFirst() }
        if delta.hasPrefix("+") { return "+\u{2009}" + delta.dropFirst() }
        return delta
    }

    /// "3m ago" under the delta; just the dashes before there's a reading.
    private var readingAgeLabel: String {
        model.isPlaceholder ? readingAge : String(
            localized: "\(readingAge) ago",
            comment: "Glance complication: minutes since the glucose reading, e.g. 3m ago"
        )
    }

    private var readingAge: String {
        model.isPlaceholder ? ComplicationState.missingValue : "\(state.minutesAgo(at: model.referenceDate))m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Big number on the left; delta over reading age on the right,
            // right-aligned and together about as tall as the number. The three
            // spread evenly across the row at similar sizes looked lost (seen on
            // device 2026-11-24), so the number now clearly leads.
            HStack(alignment: .center, spacing: 6) {
                // Arrow in white at 85% and about 60% of the number's size, as on
                // the Custom Live Activity; only the number carries the glucose
                // colour. Full-size white read brighter than the number and pulled
                // the eye (seen on device 2026-11-24). Centred on the number, not
                // on its baseline, where the smaller arrow would look slipped.
                HStack(alignment: .center, spacing: 3) {
                    Text(model.glucoseText)
                        .font(.system(size: 50, weight: .bold))
                        .foregroundStyle(glucoseColor)
                    if !model.trendArrow.isEmpty {
                        Text(model.trendArrow)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(0.85))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Digits and arrows have no descenders and sit well below the
                // ascender, so trim the empty line box: the number grows to
                // the height of the two lines beside it without the row
                // getting taller and squeezing the graph.
                .padding(.vertical, -7)
                .layoutPriority(2)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    if !model.isStale {
                        Text(deltaText)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.8))
                    }
                    Text(readingAgeLabel)
                        .font(.system(size: 16, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(
                            model.isStale ? (model.fullColor ? GlancePalette.amber : .primary) : model.dimColor
                                .opacity(0.85)
                        )
                }
                .layoutPriority(1)
            }
            .minimumScaleFactor(0.7)
            GlanceChart(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fontDesign(.rounded)
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Chart

/// Three hours of readings across the full width, under the glucose line.
///
/// Layout after another CGM app's watch complication Gary showed (2026-11-24):
/// readings coloured by Trio's own glucose colours, the target range as a faint
/// band (dashed rules at the limits until 2026-11-24), faint vertical rules on
/// the hour. The scale always includes both limits, so the band is a fixed
/// landmark and a reading's height means the same thing every time you look.
///
/// Earlier versions on the right-hand half (dots, then a thin line, both fitted
/// to the readings) were too narrow to read; see the GLANCE memory.
struct GlanceChart: View {
    let model: ComplicationModel

    private var state: ComplicationState { model.displayedState }
    private var band: ClosedRange<Double> { state.inRangeBand }
    private var end: Date { state.date }
    private var start: Date { end.addingTimeInterval(-ComplicationState.chartWindow) }

    /// Room at each end so no dot sits on the clipped edge of the plot: the
    /// latest (larger) dot and the oldest were both cut in half (seen on device
    /// 2026-11-24). The scale runs this far past the latest reading, and readings
    /// closer than this to the left edge aren't drawn.
    private static let edgePadding: TimeInterval = 4 * 60

    private var points: [(date: Date, value: Double)] {
        state.history
            .map { (date: Date(timeIntervalSince1970: $0.timestamp), value: $0.glucose) }
            .filter { $0.date >= start.addingTimeInterval(Self.edgePadding) }
    }

    /// Each pair of neighbouring readings as its own two-point series, so each
    /// stretch of line can take its own colour.
    private var segments: [(id: Int, from: (date: Date, value: Double), to: (date: Date, value: Double))] {
        guard points.count >= 2 else { return [] }
        return (1 ..< points.count).map { (id: $0, from: points[$0 - 1], to: points[$0]) }
    }

    private var domain: ClosedRange<Double> {
        let values = points.map(\.value)
        let step: Double = state.isMmol ? 1 : 18
        let low = min(values.min() ?? band.lowerBound, band.lowerBound) - step
        let high = max(values.max() ?? band.upperBound, band.upperBound) + step
        return max(0, low) ... high
    }

    private var hourMarks: [Date] {
        let calendar = Calendar.current
        guard var mark = calendar.nextDate(after: start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
        else { return [] }
        var marks: [Date] = []
        while mark < end {
            marks.append(mark)
            mark = mark.addingTimeInterval(3600)
        }
        return marks
    }

    private var scale: GlanceColorScale { GlanceColorScale(state: state) }

    private func color(for value: Double) -> Color {
        if model.isStale { return ComplicationModel.staleText }
        guard model.fullColor else { return .primary }
        return scale.color(for: value)
    }

    var body: some View {
        if points.count >= 2 {
            chart
        } else {
            Text("no data")
                .font(.system(size: 11))
                .foregroundStyle(ComplicationModel.dimText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chart: some View {
        Chart {
            // Target range as a faint neutral band (option B, 2026-11-24), in place
            // of dashed rules at the limits: less ink, and neutral rather than the
            // Live Activity's green so in-range green dots keep their contrast.
            RectangleMark(
                yStart: .value("Low", band.lowerBound),
                yEnd: .value("High", band.upperBound)
            )
            .foregroundStyle(Color.white.opacity(0.16))
            ForEach(hourMarks, id: \.self) { hour in
                RuleMark(x: .value("Hour", hour))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.white.opacity(0.20))
            }

            // Dots, one per reading, as on the Custom Live Activity. Thinned dots on
            // a half-width, zoomed chart read as random specks earlier; at full
            // width, every reading, with both limits in view, they read as a trace.
            // The previous version drew a line in coloured sections (`segments`).
            ForEach(points, id: \.date) { point in
                PointMark(x: .value("Time", point.date), y: .value("Glucose", point.value))
                    .symbolSize(point.date == points.last?.date ? 30 : 10)
                    .foregroundStyle(color(for: point.value))
            }
        }
        .chartXScale(domain: start ... end.addingTimeInterval(Self.edgePadding))
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
    }
}

// MARK: - Widget

struct TrioGlanceComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceComplication.kind, provider: GlanceProvider()) { entry in
            GlanceEntryView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Trio Glance", comment: "Name of the glance watch complication"))
        .description(String(
            localized: "Large glucose with trend, delta and reading age, and the last three hours beside it, straight from the sensor.",
            comment: "Description of the glance watch complication"
        ))
        .supportedFamilies([.accessoryRectangular])
    }
}
