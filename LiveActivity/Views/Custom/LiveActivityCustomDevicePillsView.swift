import ActivityKit
import SwiftUI
import WidgetKit

/// The sensor and pump pills on the Custom layout's header row.
///
/// **LA-PILL-REDESIGN (2026-09-23): one treatment for every state, colour only.**
/// Each pill is the outlined capsule the healthy state always had — the same
/// build as `LiveActivityCustomLoopDotView`, a 1pt ring at 0.5 around content at
/// 0.9 — recoloured by severity. No countdowns, no labels, no solid fill:
///
/// - **ok** — green.
/// - **warning** (approaching expiry) — amber.
/// - **grace / expired** — red. The two are no longer told apart on the banner.
/// - **device status message** — red, plus a warning triangle, the one label
///   kept: it is the only way to tell "the device has a fault, open the app"
///   from "the device is due for replacement".
/// - **not attached** — dim grey outline, icon only, so the pair stays a pair.
///
/// Why: the grace countdown was `Text(timerInterval:)`, redrawing the lock
/// screen every second while shown, during the hunt for the branch's extra
/// battery drain. A minute-only version was tried the same day and only comes
/// in words (`44 minutes`), too wide for these; Gary chose to drop the
/// countdown instead. The exact time left is in the app's device lanes.
///
/// Known risk, recorded in `LiveActivityCustomPalette`: `LoopRed` is a dark
/// colour and was judged weak as a thin outline on this dark banner, which is
/// why the grace state had been given a frosted ground and `redVivid`. The loop
/// dot already uses exactly this red-outline treatment for `.overdue`, so the
/// two now match. If red reads weak on device, give the red states back the
/// frosted ground (see `la-pill-redesign-rollback/`) rather than another red.
///
/// **Every status message is loud, warmup included** — Gary's explicit choice on
/// 2026-09-10. The G7 driver reports `Searching for Sensor`, `Sensor Expired`
/// and `Sensor Warmup` all at `.normalCGM`, so severity alone cannot separate
/// them; telling them apart would need a new field on `DeviceStatusMessage`.
///
/// Deliberately a Custom-stream copy of the same idea as the device-status
/// pills used by the Detailed layout, not a shared component: either stream has
/// to be removable without disturbing the other. Note the two differ — the
/// Detailed pills hide an unattached device where these grey it.
struct LiveActivityCustomDevicePillsView: View {
    let cgm: LiveActivityAttributes.DeviceLifecycle?
    let pump: LiveActivityAttributes.DeviceLifecycle?
    let cgmStatus: LiveActivityAttributes.DeviceStatusMessage?
    let pumpStatus: LiveActivityAttributes.DeviceStatusMessage?

    var body: some View {
        HStack(spacing: 4) {
            LiveActivityCustomDevicePill(
                symbol: "sensor.tag.radiowaves.forward.fill",
                lifecycle: cgm,
                status: cgmStatus
            )
            LiveActivityCustomDevicePill(
                symbol: "keyboard.onehanded.left",
                lifecycle: pump,
                status: pumpStatus
            )
        }
    }
}

struct LiveActivityCustomDevicePill: View {
    let symbol: String
    let lifecycle: LiveActivityAttributes.DeviceLifecycle?
    let status: LiveActivityAttributes.DeviceStatusMessage?

    /// Shared with `LiveActivityCustomLoopDotView`, which sizes itself to match
    /// so the status row reads as elements of one size.
    static let height: CGFloat = 19
    /// Floor, not a fixed size. The two symbols differ slightly in advance
    /// (16pt and 15pt at this size), so without a floor the pair would sit as
    /// two capsules a point apart. The floor squares them up.
    private static let minimumWidth: CGFloat = 30

    /// Ring and content opacities, the loop dot's values.
    private static let ringOpacity: Double = 0.5
    private static let contentOpacity: Double = 0.9

    private var isAttached: Bool {
        lifecycle != nil || status != nil
    }

    /// The pill's one colour. Every status message is red regardless of
    /// `isCritical` — see the type's note.
    private var severity: Color {
        if status != nil { return LiveActivityCustomPalette.red }
        guard let lifecycle else { return .white }
        switch lifecycle.phase {
        case .ok: return LiveActivityCustomPalette.green
        case .warning: return .orange
        case .expired,
             .grace: return LiveActivityCustomPalette.red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))

            if status != nil {
                // No room for the message; the marker says "open the app".
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(isAttached ? severity.opacity(Self.contentOpacity) : Color.white.opacity(0.3))
        .padding(.horizontal, status != nil ? 7 : 5)
        .frame(height: Self.height)
        .frame(minWidth: Self.minimumWidth)
        .background(
            Capsule().strokeBorder(
                isAttached ? severity.opacity(Self.ringOpacity) : Color.white.opacity(0.18),
                lineWidth: 1
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status?.message ?? "")
    }
}
