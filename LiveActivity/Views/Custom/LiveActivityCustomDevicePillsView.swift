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
/// **LA-PILL-FAULT (2026-10-13): outline = age, solid = fault.** Gary found amber
/// "near expiry" and red "grace" too easy to confuse with a fault, since only a 9pt
/// triangle told them apart. Now a status message fills the pill solid and the
/// triangle becomes an icon naming the fault; the device icon stays, so which
/// device it is never depends on position. Pump messages follow the driver's own
/// warning/critical split (amber/red); CGM messages stay red, per the 10 Sep
/// choice — the G7 rates "Sensor Expired" as normal, so its levels can't be used.
/// The fill takes whichever is worse of the message and the lifecycle colour, so a
/// pod in grace is never shown amber because of a lesser warning.
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
                status: pumpStatus,
                splitsWarnings: true
            )
        }
    }
}

struct LiveActivityCustomDevicePill: View {
    let symbol: String
    let lifecycle: LiveActivityAttributes.DeviceLifecycle?
    let status: LiveActivityAttributes.DeviceStatusMessage?
    /// LA-PILL-FAULT: true for the pump — a non-critical message is amber rather
    /// than red. The CGM leaves it false.
    var splitsWarnings: Bool = false

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

    /// The lifecycle colour — the outline's, and the floor for a fault's fill.
    private var lifecycleColor: Color {
        guard let lifecycle else { return .white }
        switch lifecycle.phase {
        case .ok: return LiveActivityCustomPalette.green
        case .warning: return .orange
        case .expired,
             .grace: return LiveActivityCustomPalette.red
        }
    }

    /// LA-PILL-FAULT: the fill for a status message — the worse of the message's own
    /// severity and the lifecycle colour.
    private var faultColor: Color {
        guard let status else { return lifecycleColor }
        let messageIsRed = status.isCritical || !splitsWarnings
        let lifecycleIsRed = lifecycle?.phase == .expired || lifecycle?.phase == .grace
        return messageIsRed || lifecycleIsRed ? LiveActivityCustomPalette.red : .orange
    }

    /// LA-PILL-FAULT: an icon naming the fault, matched on the driver's English
    /// message (Omnipod DASH and G7 wording). Anything unrecognised keeps the
    /// warning triangle, so a new or translated message still reads as a fault.
    private var faultSymbol: String {
        let message = status?.message.lowercased() ?? ""
        let table: [(String, String)] = [
            ("signal loss", "antenna.radiowaves.left.and.right.slash"),
            ("manual basal", "hand.raised.fill"),
            ("suspended", "pause.fill"),
            ("no insulin", "drop"),
            ("occlusion", "nosign"),
            ("expired", "hourglass"),
            ("comms issue", "questionmark"),
            ("no pod", "xmark"),
            ("finish", "ellipsis"),
            ("searching", "magnifyingglass"),
            // G7 direct connection: "Pair Sensor" / "Pair New Sensor",
            // "Waiting for Sensor", "Connection Refused".
            ("pair", "plus"),
            ("waiting", "dot.radiowaves.left.and.right"),
            ("refused", "lock.slash"),
            ("warmup", "timer"),
            ("failed", "xmark.octagon.fill"),
            ("error", "xmark.octagon.fill"),
            ("issue", "exclamationmark")
        ]
        return table.first { message.contains($0.0) }?.1 ?? "exclamationmark.triangle.fill"
    }

    var body: some View {
        let isFault = status != nil
        let color = isFault ? faultColor : lifecycleColor

        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))

            if isFault {
                // No room for the message; the icon names it.
                Image(systemName: faultSymbol)
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(
            !isAttached ? Color.white.opacity(0.3)
                : isFault ? Color.black.opacity(0.85)
                : color.opacity(Self.contentOpacity)
        )
        .padding(.horizontal, isFault ? 7 : 5)
        .frame(height: Self.height)
        .frame(minWidth: Self.minimumWidth)
        .background {
            if isFault {
                Capsule().fill(color.opacity(Self.contentOpacity))
            } else {
                Capsule().strokeBorder(
                    isAttached ? color.opacity(Self.ringOpacity) : Color.white.opacity(0.18),
                    lineWidth: 1
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status?.message ?? "")
    }
}
