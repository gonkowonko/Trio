import SwiftUI
import WidgetKit

/// Paired CGM / pump lifecycle pills for the Live Activity, floated in the
/// chart's top-trailing corner opposite the override and temp-target chips.
///
/// The design principle is that **footprint scales with severity**, so a
/// healthy pair costs almost nothing to read:
/// - **ok** — green, icon only, at the pill's minimum width.
/// - **warning** — orange, icon + coarse countdown (`9h`). The pill *widens*,
///   which is a second signal on top of colour and survives colourblindness.
/// - **grace** — red, icon + live ticking countdown to hard shutdown.
/// - **expired** — red, icon + "Replace". Static, because there is nothing
///   left to count down.
///
/// The green pill sets the minimum width; every other phase grows to fit its
/// own content, so the pair is symmetric while healthy and deliberately
/// asymmetric the moment one device needs attention.
///
/// Colours are `DeviceLanesView`'s, including its red-reservation rule:
/// warning and critical both render orange, and **red only ever means the
/// grace period**, so a red pill has exactly one meaning.
///
/// One caveat this surface has that the lane doesn't: red is also the colour of
/// a low glucose reading (`Color.staticLow`, and hue 0° at the bottom of the
/// dynamic scheme). The pills are therefore *filled capsules with white
/// content* rather than bare coloured glyphs — the enclosure makes them read as
/// badges, not as values, so a red pod pill can't be confused with a red BG.
enum LiveActivityDeviceKind {
    case cgm
    case pump

    /// Same SF Symbols the home-screen device lanes use, so the two surfaces
    /// stay recognisably the same system.
    var symbol: String {
        switch self {
        case .cgm: return "sensor.tag.radiowaves.forward.fill"
        case .pump: return "keyboard.onehanded.left"
        }
    }

    /// The pod glyph is a thin outline and carries slightly less optical weight
    /// at pill size than the sensor tag, which is mostly solid mass.
    var iconPointSize: CGFloat {
        switch self {
        case .cgm: return 12
        case .pump: return 13
        }
    }

    var accessibilityName: String {
        switch self {
        case .cgm: return String(localized: "Sensor", comment: "Accessibility name for the CGM status pill")
        case .pump: return String(localized: "Pump", comment: "Accessibility name for the pump status pill")
        }
    }
}

/// A single device's status pill.
struct LiveActivityDeviceStatusPill: View {
    let kind: LiveActivityDeviceKind
    let lifecycle: LiveActivityAttributes.DeviceLifecycle

    private var phase: LiveActivityAttributes.DeviceLifecycle.Phase { lifecycle.phase }
    private var endsAt: Date? { lifecycle.endsAt }

    /// `DeviceLanesView`'s palette. `LoopGreen` already exists in the
    /// LiveActivity target's asset catalog; `LoopRed` does not, so both are
    /// pinned to their catalog values here. Copy `LoopRed.colorset` across and
    /// these can become `Color("LoopGreen")` / `Color("LoopRed")`.
    private enum Palette {
        static let green = Color(red: 0.435, green: 0.812, blue: 0.592)
        static let red = Color(red: 0.922, green: 0.341, blue: 0.341)
    }

    private static let height: CGFloat = 21
    /// Set by the icon-only green pill; every pill is at least this wide.
    private static let minimumWidth: CGFloat = 34
    /// Fits `59:59` and `5:59:59` respectively, at `.caption` with monospaced
    /// digits, so a ticking countdown never reflows the row.
    private static let shortCountdownWidth: CGFloat = 42
    private static let longCountdownWidth: CGFloat = 54
    private static let oneHour: TimeInterval = 3600

    private var fill: Color {
        switch phase {
        case .ok: return Palette.green
        case .warning: return .orange
        case .expired,
             .grace: return Palette.red
        }
    }

    private var showsLabel: Bool { phase != .ok }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: kind.iconPointSize, weight: .semibold))

            label
        }
        .foregroundStyle(.white)
        .padding(.horizontal, showsLabel ? 8 : 6)
        .frame(height: Self.height)
        .frame(minWidth: Self.minimumWidth)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder private var label: some View {
        switch phase {
        case .ok:
            EmptyView()

        case .warning:
            // Hours-to-days out, so a coarse string is both enough precision
            // and stable across the ~5 min between Live Activity updates.
            Text(Self.coarseRemaining(until: endsAt))
                .font(.caption).fontWeight(.medium).monospacedDigit()

        case .grace:
            if let endsAt, endsAt > Date.now {
                // `Text(timerInterval:)` is rendered by the system's timer-text
                // machinery, the same as the lock screen clock: the widget's
                // view code is not re-executed, the app is not woken, and no
                // ActivityKit update budget is spent. It is the only way to
                // keep the countdown honest between Trio's ~5 min updates, and
                // it costs essentially nothing to run for the whole window.
                //
                // It needs a fixed frame or the pill resizes as digits tick;
                // the frame widens past an hour to fit `h:mm:ss`.
                Text(timerInterval: Date.now ... endsAt, countsDown: true)
                    .font(.caption).fontWeight(.medium).monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .frame(width: Self.countdownWidth(until: endsAt), alignment: .leading)
            } else {
                Text("Replace").font(.caption).fontWeight(.medium)
            }

        case .expired:
            Text("Replace", comment: "Live Activity device pill label once the device is past hard shutdown")
                .font(.caption).fontWeight(.medium)
        }
    }

    private static func countdownWidth(until endsAt: Date) -> CGFloat {
        endsAt.timeIntervalSinceNow >= oneHour ? longCountdownWidth : shortCountdownWidth
    }

    private var accessibilityDescription: String {
        switch phase {
        case .ok:
            return kind.accessibilityName + ", " + String(localized: "OK", comment: "Device pill accessibility state")
        case .warning:
            return kind.accessibilityName + ", " + Self.coarseRemaining(until: endsAt) + " " +
                String(localized: "remaining", comment: "Device pill accessibility state")
        case .grace:
            return kind
                .accessibilityName + ", " + String(localized: "in grace period", comment: "Device pill accessibility state")
        case .expired:
            return kind.accessibilityName + ", " + String(localized: "replace now", comment: "Device pill accessibility state")
        }
    }

    /// Local copy of `SensorRemainingTimeFormatter`, which currently lives in
    /// the main app target. Fold the two together once that type is shared with
    /// the LiveActivity target.
    static func coarseRemaining(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let totalMinutes = Int(max(0, date.timeIntervalSince(now))) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        let d = String(localized: "d", comment: "Abbreviation for Days")
        let h = String(localized: "h", comment: "Abbreviation for Hours")
        let m = String(localized: "m", comment: "Abbreviation for Minutes")
        if days > 0, hours > 0 { return "\(days)\(d) \(hours)\(h)" }
        if days > 0 { return "\(days)\(d)" }
        if hours > 0 { return "\(hours)\(h)" }
        if minutes > 0 { return "\(minutes)\(m)" }
        return "<" + "\u{00A0}" + "1" + "\u{00A0}" + m
    }
}

/// The pair, laid out for the chart's top-trailing corner. Always present when
/// a device reports a lifecycle — a healthy pair is two minimum-width green
/// pills, which read as "nominal" without asking to be parsed. A device with no
/// lifecycle at all (not set up, or exposing no dates) is omitted rather than
/// shown green, so the corner never claims a health it can't verify.
struct LiveActivityDeviceStatusPills: View {
    let cgm: LiveActivityAttributes.DeviceLifecycle?
    let pump: LiveActivityAttributes.DeviceLifecycle?

    var body: some View {
        if cgm != nil || pump != nil {
            HStack(spacing: 5) {
                if let cgm {
                    LiveActivityDeviceStatusPill(kind: .cgm, lifecycle: cgm)
                }
                if let pump {
                    LiveActivityDeviceStatusPill(kind: .pump, lifecycle: pump)
                }
            }
        }
    }
}

// MARK: - Previews

/// Stand-in for the detailed Live Activity layout — a chart-shaped block with
/// the readout row underneath — so the pills can be judged in place rather than
/// floating on their own.
private struct PreviewBanner<Corner: View>: View {
    var overrideName: String?
    @ViewBuilder var corner: () -> Corner

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                PreviewChart()
                    .frame(height: 80)

                corner()
            }
            .overlay(alignment: .topLeading) {
                if let overrideName {
                    Text(overrideName)
                        .font(.footnote).fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.6)))
                }
            }

            HStack(spacing: 0) {
                readout("6.9", "+0.1 →")
                Divider().overlay(Color.white.opacity(0.25))
                readout("0.5 U", "IOB")
                Divider().overlay(Color.white.opacity(0.25))
                readout("0 g", "COB")
                Divider().overlay(Color.white.opacity(0.25))
                readout("08:22", "Updated")
            }
            .frame(height: 40)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.13)))
        .padding()
        .background(Color(red: 0.56, green: 0.49, blue: 0.42))
    }

    private func readout(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3).fontWeight(.medium).foregroundStyle(.white)
            Text(caption).font(.caption).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PreviewChart: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.7))
                    path.addLine(to: CGPoint(x: w, y: h * 0.7))
                }
                .stroke(Color(red: 0.435, green: 0.812, blue: 0.592), lineWidth: 2)

                ForEach(0 ..< 44, id: \.self) { i in
                    let t = CGFloat(i) / 43
                    let y = i < 27 ? h * 0.7 : h * 0.7 - h * 0.42 * sin(CGFloat(i - 27) / 17 * .pi * 0.95)
                    Circle()
                        .fill(
                            y > h * 0.6 ? Color(red: 0.435, green: 0.812, blue: 0.592) :
                                Color(red: 0.33, green: 0.82, blue: 0.78)
                        )
                        .frame(width: 6, height: 6)
                        .position(x: 6 + t * (w - 12), y: y)
                }
            }
        }
    }
}

#Preview("Pills — the four tiers") {
    func lc(
        _ phase: LiveActivityAttributes.DeviceLifecycle.Phase,
        _ seconds: TimeInterval? = nil
    ) -> LiveActivityAttributes.DeviceLifecycle {
        .init(phase: phase, endsAt: seconds.map { Date().addingTimeInterval($0) })
    }

    return VStack(spacing: 0) {
        PreviewBanner {
            LiveActivityDeviceStatusPills(cgm: lc(.ok), pump: lc(.ok))
        }
        PreviewBanner {
            LiveActivityDeviceStatusPills(cgm: lc(.ok), pump: lc(.warning, 9 * 3600))
        }
        PreviewBanner(overrideName: "Exercise") {
            LiveActivityDeviceStatusPills(cgm: lc(.warning, 18 * 3600), pump: lc(.warning, 4 * 3600))
        }
        PreviewBanner {
            LiveActivityDeviceStatusPills(cgm: lc(.ok), pump: lc(.grace, 3 * 3600 + 12 * 60))
        }
        PreviewBanner {
            LiveActivityDeviceStatusPills(cgm: lc(.grace, 48 * 60), pump: lc(.expired))
        }
        PreviewBanner {
            LiveActivityDeviceStatusPills(cgm: lc(.ok), pump: nil)
        }
    }
}

#Preview("Pills — grace countdown widths") {
    func grace(_ seconds: TimeInterval) -> LiveActivityAttributes.DeviceLifecycle {
        .init(phase: .grace, endsAt: Date().addingTimeInterval(seconds))
    }

    return VStack(spacing: 0) {
        PreviewBanner {
            LiveActivityDeviceStatusPills(
                cgm: .init(phase: .ok, endsAt: nil),
                pump: grace(7 * 3600 + 41 * 60)
            )
        }
        PreviewBanner {
            LiveActivityDeviceStatusPills(cgm: grace(59 * 60), pump: grace(4 * 60 + 20))
        }
        PreviewBanner {
            LiveActivityDeviceStatusPills(cgm: .init(phase: .ok, endsAt: nil), pump: grace(47))
        }
    }
}
