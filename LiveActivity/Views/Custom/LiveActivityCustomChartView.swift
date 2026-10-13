import ActivityKit
import Charts
import SwiftUI
import WidgetKit

/// The Custom layout's chart: three hours of readings over a shaded in-range
/// band, with a trailing value axis and hourly time marks.
///
/// Separate from `LiveActivityChartView` on purpose. That view carries forecast
/// cones, override shading and axis marks of its own; this one is a trace you
/// read shape from, plus just enough scale to know what the shape means.
struct LiveActivityCustomChartView: View {
    let chart: [LiveActivityAttributes.ChartItem]
    let isMgdL: Bool
    let low: Decimal
    let high: Decimal
    let target: Decimal
    /// `GlucoseColorScheme.rawValue`. Each point is coloured from its own
    /// reading, matching `GlucoseChartView.pointColor(for:)` on the home
    /// screen — a trace crossing from low to high shifts colour along its
    /// length rather than taking the current reading's colour throughout.
    let glucoseColorScheme: String

    private static let window: TimeInterval = 3 * 60 * 60

    private var windowStart: Date { Date().addingTimeInterval(-Self.window) }

    private var converted: [(date: Date, value: Double, color: Color)] {
        let cutoff = windowStart
        return chart
            .filter { $0.date >= cutoff }
            .map { item in
                let value = isMgdL ? item.value : item.value.asMmolL
                return (item.date, Double(truncating: value as NSNumber), pointColor(for: item.value))
            }
            .sorted { $0.date < $1.date }
    }

    /// Colour for one reading. Works in mg/dL throughout — value and thresholds
    /// alike — so no conversion can desynchronise them. The 55/220 span in
    /// dynamic mode is the same workaround the app and the other layouts use to
    /// give the hue ramp room either side of the user's own thresholds.
    private func pointColor(for value: Decimal) -> Color {
        let isDynamic = glucoseColorScheme == "dynamicColor"
        return Color.getDynamicGlucoseColor(
            glucoseValue: value,
            highGlucoseColorValue: isDynamic ? 220 : high,
            lowGlucoseColorValue: isDynamic ? 55 : low,
            targetGlucose: target,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    private func scaled(_ value: Decimal) -> Double {
        Double(truncating: (isMgdL ? value : value.asMmolL) as NSNumber)
    }

    /// Axis labels only read well on round numbers, so the domain is padded by
    /// half a step and then snapped outwards to a whole one — 1 mmol/L, 20
    /// mg/dL. The padding is what stops the highest reading sitting on the
    /// frame's top edge when it happens to land exactly on a step.
    private var axisStep: Double { isMgdL ? 20 : 1 }

    private var bounds: (min: Double, max: Double) {
        let values = converted.map(\.value)
        let lowLine = scaled(low)
        let highLine = scaled(high)
        let step = axisStep
        let lower = min(values.min() ?? lowLine, lowLine) - step / 2
        let upper = max(values.max() ?? highLine, highLine) + step / 2
        return (
            max(0, (lower / step).rounded(.down) * step),
            (upper / step).rounded(.up) * step
        )
    }

    /// The user's own thresholds, and nothing else.
    ///
    /// The domain edges were labelled too at first and they collided: this axis
    /// is about 50pt tall across a span of eight whole units, so two labels a
    /// unit apart overlap outright. The thresholds are the numbers worth the
    /// room — they name the band, which is what the trace is being read against.
    private var valueAxisMarks: [Double] {
        [scaled(low), scaled(high)]
    }

    private func axisLabel(_ value: Double) -> String {
        isMgdL ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    /// Whole hours inside the window, minus any that fall in the last 20
    /// minutes of it.
    ///
    /// `.stride(by: .hour)` alone puts a label hard against the right edge
    /// whenever the current time is just past the hour, where the value-axis
    /// column clips it to a single digit. Dropping that mark costs nothing —
    /// the right edge of this chart is always now.
    private var timeAxisMarks: [Date] {
        let calendar = Calendar.current
        let cutoff = Date().addingTimeInterval(-20 * 60)
        guard var mark = calendar.nextDate(
            after: windowStart,
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) else { return [] }

        var marks: [Date] = []
        while mark < cutoff {
            marks.append(mark)
            mark = mark.addingTimeInterval(3600)
        }
        return marks
    }

    var body: some View {
        Chart {
            // The in-range band. Cheaper to read than a pair of lines: the eye
            // sees whether the trace is inside a shape without comparing it to
            // two separate rules.
            RectangleMark(
                xStart: .value("Start", windowStart),
                xEnd: .value("End", Date()),
                yStart: .value("Low", scaled(low)),
                yEnd: .value("High", scaled(high))
            )
            .foregroundStyle(LiveActivityCustomPalette.green.opacity(0.12))

            RuleMark(y: .value("Low", scaled(low)))
                .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(LiveActivityCustomPalette.yellow.opacity(0.7))
            RuleMark(y: .value("High", scaled(high)))
                .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Color.white.opacity(0.35))

            ForEach(converted, id: \.date) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Glucose", point.value)
                )
                .symbolSize(7)
                .foregroundStyle(point.color)
            }
        }
        .chartYScale(domain: bounds.min ... bounds.max)
        .chartXScale(domain: windowStart ... Date())
        .chartYAxis {
            // Labels only — no gridlines or ticks. The band and the two dashed
            // rules already carry the horizontal structure.
            AxisMarks(position: .trailing, values: valueAxisMarks) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: timeAxisMarks) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour())
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}
