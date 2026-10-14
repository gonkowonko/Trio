import CoreData
import LoopKit
import SwiftUI

struct CurrentGlucoseView: View {
    let timerDate: Date
    let units: GlucoseUnits
    let alarm: GlucoseAlarm?
    let lowGlucose: Decimal
    let highGlucose: Decimal
    let cgmAvailable: Bool
    var currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let glucose: [GlucoseStored] // This contains the last two glucose values, no matter if its manual or a cgm reading

    @State private var rotationDegrees: Double = 0.0
    @State private var angularGradient = AngularGradient(colors: [
        Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
        Color(red: 0.6235294118, green: 0.4235294118, blue: 0.9803921569),
        Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765),
        Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
        Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902),
        Color(red: 0.7215686275, green: 0.3411764706, blue: 1)
    ], center: .center, startAngle: .degrees(270), endAngle: .degrees(-90))

    @Environment(\.colorScheme) var colorScheme

    private var deltaFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if units == .mmolL {
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 1
            formatter.roundingMode = .halfUp
        } else {
            formatter.maximumFractionDigits = 0
        }
        formatter.positivePrefix = "  +"
        formatter.negativePrefix = "  -"
        return formatter
    }

    var body: some View {
        let triangleColor = Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)

        if cgmAvailable {
            // Bobble renders at 0.9 to leave breathing room for the side panel
            // siblings; the empty-state branch below fits at 1.0. Sensor status
            // (warmup / signal loss / error / expired) now lives in the CGM
            // device tile, not on the bobble — a stale bobble just shows dashes.
            bobbleAndTag(triangleColor: triangleColor)
                .scaleEffect(0.9)
        } else {
            VStack(alignment: .center, spacing: 12) {
                HStack
                    {
                        // no cgm defined so display a generic CGM
                        Image(systemName: "sensor.tag.radiowaves.forward.fill").font(.body).imageScale(.large)
                    }
                HStack {
                    Text("Add CGM").font(.caption).bold()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 100)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(alignment: .top)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Add CGM"))
                .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder private func bobbleAndTag(triangleColor: Color) -> some View {
        ZStack {
            // BOBBLE-GLOW: upstream's (e0052cc62) trend-coloured halo behind the ring.
            // Delete this Circle to remove it; nothing else depends on it.
            Circle()
                .fill(triangleColor)
                .frame(width: 124, height: 124)
                .blur(radius: 24)
                .opacity(colorScheme == .dark ? 0.32 : 0.20)

            TrendShape(gradient: angularGradient, color: triangleColor, showArrow: true)
                .rotationEffect(.degrees(rotationDegrees))

            VStack(alignment: .center) {
                bobbleContent()
            }
        }
        .onChange(of: glucose.last?.directionEnum) {
            withAnimation {
                switch glucose.last?.directionEnum {
                case .doubleUp,
                     .singleUp,
                     .tripleUp:
                    rotationDegrees = -90
                case .fortyFiveUp:
                    rotationDegrees = -45
                case .flat:
                    rotationDegrees = 0
                case .fortyFiveDown:
                    rotationDegrees = 45
                case .doubleDown,
                     .singleDown,
                     .tripleDown:
                    rotationDegrees = 90
                case nil,
                     .notComputable,
                     .rateOutOfRange:
                    rotationDegrees = 0
                default:
                    rotationDegrees = 0
                }
            }
        }
        // read the value, range, trend, delta and age as one element instead of fragments
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bobbleAccessibilityLabel))
    }

    private var delta: String {
        guard glucose.count >= 2 else {
            return "--"
        }

        var lastGlucose = Decimal(glucose.last?.glucose ?? 0)
        var secondLastGlucose = Decimal(glucose.first?.glucose ?? 0)
        if units == .mmolL {
            lastGlucose = lastGlucose.asMmolL
            secondLastGlucose = secondLastGlucose.asMmolL
        }
        let delta = lastGlucose - secondLastGlucose
        return deltaFormatter.string(from: delta as NSNumber) ?? "--"
    }

    /// Spoken trend from the CGM direction arrow (which is otherwise image-only).
    private var trendDescription: String? {
        switch glucose.last?.directionEnum {
        case .doubleUp,
             .tripleUp:
            return String(localized: "rising quickly", comment: "Accessibility: glucose trend")
        case .singleUp:
            return String(localized: "rising", comment: "Accessibility: glucose trend")
        case .fortyFiveUp:
            return String(localized: "rising slowly", comment: "Accessibility: glucose trend")
        case .flat:
            return String(localized: "steady", comment: "Accessibility: glucose trend")
        case .fortyFiveDown:
            return String(localized: "falling slowly", comment: "Accessibility: glucose trend")
        case .singleDown:
            return String(localized: "falling", comment: "Accessibility: glucose trend")
        case .doubleDown,
             .tripleDown:
            return String(localized: "falling quickly", comment: "Accessibility: glucose trend")
        default:
            return nil
        }
    }

    /// Spoken range so the glucose value isn't conveyed by color alone.
    private func rangeDescription(for glucoseValue: Int16) -> String {
        let value = Decimal(glucoseValue)
        if value < lowGlucose {
            return String(localized: "below range", comment: "Accessibility: glucose range")
        }
        if value > highGlucose {
            return String(localized: "above range", comment: "Accessibility: glucose range")
        }
        return String(localized: "in range", comment: "Accessibility: glucose range")
    }

    /// One combined VoiceOver description for the bobble, e.g.
    /// "Glucose 79 mg/dL, in range, falling, delta -2, 1 minute ago".
    private var bobbleAccessibilityLabel: String {
        guard let glucoseValue = glucose.last?.glucose, isReadingFresh else {
            return String(localized: "Glucose unavailable", comment: "Accessibility: no fresh glucose")
        }
        let valueString = glucoseValue == 400
            ? String(localized: "high", comment: "Accessibility: glucose is at the top of the scale")
            : (units == .mgdL ? Decimal(glucoseValue).description : Decimal(glucoseValue).formattedAsMmolL)
        var parts = [String(localized: "Glucose", comment: "Accessibility: glucose label") + " \(valueString) \(units.rawValue)"]
        parts.append(rangeDescription(for: glucoseValue))
        if let trend = trendDescription { parts.append(trend) }
        if delta != "--" {
            parts.append(String(localized: "delta", comment: "Accessibility: glucose delta") + " \(delta)")
        }
        parts.append(TimeAgoFormatter.minutesAgoAccessible(from: glucose.last?.date))
        // Upstream folds the sensor-lifecycle tag (warmup countdown, "expired",
        // "stabilizing") in here, because on their bobble that tag is a child view the
        // `.accessibilityElement(children: .ignore)` above would otherwise drop. This
        // layout has no such child — sensor status lives in the CGM device tile — so
        // their `tagLabel` / `trendIsDownward` do not exist here and the clause is gone.
        //
        // Expect this to come back on every merge that touches upstream's bobble a11y,
        // and note it arrives *silently*: the definitions sit in regions this file
        // deleted long ago, so git drops them without raising a conflict and only the
        // compiler notices. If the tag is ever wanted spoken, it belongs on the device
        // tile's own accessibility label, not here.
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func bobbleContent() -> some View {
        HStack {
            if let glucoseValue = glucose.last?.glucose, isReadingFresh {
                let displayGlucose = units == .mgdL
                    ? Decimal(glucoseValue).description
                    : Decimal(glucoseValue).formattedAsMmolL
                Text(glucoseValue == 400 ? "HIGH" : displayGlucose)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(glucoseColor(for: glucoseValue))
            } else {
                Text("– –")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        if isReadingFresh {
            HStack {
                let minutesAgoString = TimeAgoFormatter.minutesAgo(from: glucose.last?.date)
                Group {
                    Text(minutesAgoString)
                    Text(delta)
                }
                .font(.callout).fontWeight(.bold)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.9) : Color.secondary)
            }
            .frame(alignment: .top)
        }
    }

    /// Matches `APSManager`'s loop-input freshness gate — readings older than
    /// 12 minutes (one missed CGM transmission on a 5-min schedule) get
    /// masked to dashes. Handles warmup + sensor failure naturally: no
    /// fresh data → no number on the bobble.
    /// The boundary itself lives in `GlucoseFreshness`, so this and the contact
    /// image's glucose value cannot drift apart. They render differently past it —
    /// the contact image keeps the number, dimmed — but they cross it together.
    private var isReadingFresh: Bool {
        GlucoseFreshness.classify(glucoseDate: glucose.last?.date).isWithinDosingWindow
    }

    private func glucoseColor(for glucoseValue: Int16) -> Color {
        // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor
        guard Decimal(glucoseValue) <= lowGlucose || Decimal(glucoseValue) >= highGlucose else {
            return Color.primary
        }
        return Trio.getDynamicGlucoseColor(
            glucoseValue: Decimal(glucoseValue),
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 15))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.midY + 10))

        path.closeSubpath()

        return path
    }
}

struct TrendShape: View {
    @Environment(\.colorScheme) var colorScheme

    let gradient: AngularGradient
    let color: Color
    var showArrow: Bool = true

    var body: some View {
        HStack(alignment: .center) {
            ZStack {
                Group {
                    CircleShape(gradient: gradient)
                    if showArrow {
                        TriangleShape(color: color)
                    }
                }.shadow(color: Color.black.opacity(colorScheme == .dark ? 0.75 : 0.33), radius: colorScheme == .dark ? 5 : 3)
                CircleShape(gradient: gradient)
            }
        }
    }
}

struct CircleShape: View {
    @Environment(\.colorScheme) var colorScheme

    let gradient: AngularGradient

    var body: some View {
        Circle()
            .stroke(gradient, lineWidth: 6)
            .background(Circle().fill(Color.chart))
            .frame(width: 130, height: 130)
    }
}

struct TriangleShape: View {
    let color: Color

    var body: some View {
        Triangle()
            .fill(color)
            .frame(width: 35, height: 35)
            .rotationEffect(.degrees(90))
            .offset(x: 85)
    }
}
