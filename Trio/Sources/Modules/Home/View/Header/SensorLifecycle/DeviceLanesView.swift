import CoreData
import LoopKit
import SwiftUI

/// Vertical rhythm inside a lane. The two text rows sit between the pill edge and
/// the bar, and only these two values separate them: `cardPadding` above and below
/// the stack, `rowSpacing` between each row and the bar. Equal values put the text
/// midway; they were 9 and 4, which read as the text hugging the bar.
///
/// **They must sum to 13.** The card is a fixed `HomeLayout.deviceLanesHeight`
/// (62), and 62 − 2·padding − 2·spacing is what the rows themselves get: 36, for
/// the name row, the 6pt bar and the readout row. Raising both — rather than
/// trading one against the other — squeezes the text instead of moving it, unless
/// `deviceLanesHeight` grows to match, which costs the chart.
enum DeviceLaneMetrics {
    static let cardPadding: CGFloat = 6.5
    static let rowSpacing: CGFloat = 6.5

    /// Warning / critical / grace lanes are **outlined**, not washed.
    ///
    /// The tile tint used to be a third signal on top of two that already work: the
    /// bar fills with `phase.fillColor` (or `loopRed` in grace) and the countdown
    /// takes `accentColor`. It also contradicted this file's own rule that the device
    /// name is an identity readout and "stays neutral in every phase" — a 27% wash
    /// covered the name along with everything else, and cost contrast on the text it
    /// covered.
    ///
    /// So an alert lane passes `tintOpacity: 0`, which drops the fill and (see
    /// `GlassPanelBackground.rimOpacity`) promotes the rim to full strength. Healthy
    /// lanes are untouched: they pass no tint, so their fill was already invisible.
    ///
    /// Colour alone separates an alert lane from a healthy one — the rim stays the
    /// same 1pt width throughout. 2pt was tried on device 2026-09-20 and read as
    /// shouting: at this size the extra weight adds urgency the colour already
    /// carries, and the lane starts competing with the bobble.
    ///
    /// Both rims are 1pt; only their opacity differs, and that contrast is what does
    /// the signalling now the fill is gone. 0.9 against the healthy 0.18 was a 5×
    /// step, which read as a *thicker* line rather than a brighter one — at 3x a 1pt
    /// stroke is ~3 physical pixels, fully saturated at 0.9 and half dissolved into
    /// the background at 0.18. 0.6 keeps the amber unmistakable without letting the
    /// lane dominate the screen.
    ///
    /// Set `alertRimOpacity` to 0 to fall back to an unoutlined lane.
    static let alertRimOpacity: Double = 0.6
    /// Healthy lane: a quiet neutral rim, the value these panels have always used.
    /// Resolves to 0.18 through `rimOpacity`'s 0.6 accent factor, which the alert
    /// path deliberately bypasses.
    static let restingRimOpacity: Double = 0.30

    /// LANE-WASH: alert lanes are washed again (Gary, 2026-09-24), reversing the
    /// outline-only decision above: on device the outline alone read as "a normal
    /// card with a red border". Lighter than the old 27% — this is multiplied by
    /// `GlassChrome.panelTintBoost` (1.5), so it lands at 18%.
    static let alertWashOpacity: Double = 0.12
    /// LANE-WASH: with a fill present `rimOpacity` applies its 0.6 accent factor, so
    /// passing 1 keeps the rim at the same 0.6 the outline-only lane used.
    static let alertWashRimOpacity: Double = 1.0
}

/// Two session lanes above the chart — one per device, each on its own glass
/// card sitting *side by side*. Each lane is three rows: `[icon] name` on top,
/// a full-width draining bar in the middle, then `units … countdown` on the
/// bottom (reservoir / battery left, time-left right).
///
/// The bar is a draining gauge: the fill is time *remaining* (matching the
/// countdown below it) and empties toward zero, green during normal life and
/// orange through the warning/critical windows. Red is reserved for the
/// grace period (G7: 12 h past expiry, pod: 8 h): at expiry the whole bar
/// becomes the grace gauge — refilled red, draining toward hard shutdown.
/// A full red bar is unambiguous because normal life never renders red.
/// No playhead knob: an earlier design used one and it read as a draggable
/// scrubber.
///
/// The device name is an identity readout, not a status, so it stays neutral
/// in every phase — only the icon, bar, and countdown take the phase color.
///
/// The lanes are also the devices' tap targets (they replaced the old pump
/// column, which was the pump's only entry point): tapping a lane opens that
/// device's settings, and a missing device renders as an "Add …" row so setup
/// stays reachable. The glass card itself marks the lane as a control, so no
/// chevron is needed.
struct DeviceLanesView: View {
    let timerDate: Date

    // CGM
    let cgmAvailable: Bool
    /// Paired sensor's display name (e.g. "Dexcom G7") — the lane's top-row
    /// label. An identity readout, so it stays neutral in every phase.
    let cgmName: String
    /// Full-lifespan anchors (G7). Preferred lane source: gives elapsed
    /// fraction plus the final-window/grace zones.
    let sensorTimeline: SensorLifecycleTimeline?
    /// Fallback fill for CGMs without a timeline (battery- or age-based
    /// managers): fraction only, no zones.
    let sensorProgress: DeviceLifecycleProgress?
    /// Fallback countdown label when no timeline exists.
    let sensorExpiresAt: Date?
    /// Live CGM status (warming up, stabilizing, signal loss, sensor error,
    /// expired…). When present it replaces the countdown in the lane's readout
    /// row — the status is what matters while it's active, and it moved here off
    /// the glucose bobble to keep that clean. Defaulted so previews/other lanes
    /// can omit it.
    var cgmStatus: CgmDisplayState? = nil
    /// Wall-clock end of the warmup window, for the warmup countdown.
    var cgmWarmupEndsAt: Date? = nil

    // Pump
    let pumpAvailable: Bool
    /// Paired pump's display name (e.g. "Omnipod DASH") — the lane's top-row
    /// label. Neutral like `cgmName`.
    let pumpName: String
    let podExpiresAt: Date?
    let reservoir: Decimal?
    let battery: [OpenAPS_Battery]
    let pumpStatusHighlightMessage: String?
    /// LANE-MANUAL: the highlight above is only Omnipod's "Manual Basal" notice —
    /// the pod is healthy, so the gauge and readouts stay up.
    var pumpStatusHighlightIsManualBasal: Bool = false
    /// LANE-MANUAL: end of the running manual temp, for the lane's countdown.
    var manualTempEndsAt: Date? = nil

    let onTapSensor: () -> Void
    let onTapPump: () -> Void

    /// Omnipod thresholds: amber inside the last 12 h, red inside the last 8 h.
    /// (The retired `PumpView.timerColor` used 24 h for amber; narrowed here so
    /// the warning fires closer to end-of-life.) After nominal expiry the pod
    /// keeps delivering for 8 h before hard shutdown — the grace window the
    /// lane's bar drains through in red.
    private static let podLife: TimeInterval = 72 * 60 * 60
    private static let podWarnWindow: TimeInterval = 12 * 60 * 60
    private static let podCritWindow: TimeInterval = 8 * 60 * 60
    private static let podGraceWindow: TimeInterval = 8 * 60 * 60

    /// Nominal full cartridge for the reservoir gauge shown on clockless pumps
    /// (Medtronic, Dana, simulator); true capacity isn't plumbed to the view.
    /// Sized for the largest common cartridge so a full reservoir reads full —
    /// the low-reservoir *color* (see `podPhase`) is absolute regardless.
    private static let nominalReservoirCapacity: Double = 300

    /// Reservoir thresholds for the low-insulin warning, matching `reservoirColor`.
    private static let reservoirWarnUnits: Decimal = 30
    private static let reservoirCritUnits: Decimal = 10

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            deviceCard(tint: sensorCardTint, action: onTapSensor) {
                if cgmAvailable {
                    DeviceLaneView(
                        iconSystemName: "sensor.tag.radiowaves.forward.fill",
                        name: cgmName,
                        bar: sensorBar,
                        phase: sensorPhase,
                        label: sensorLabel,
                        labelColorOverride: sensorStatus?.color,
                        sublabels: []
                    )
                } else {
                    AddDeviceLaneView(label: String(localized: "Add CGM"))
                }
            }

            deviceCard(tint: podCardTint, action: onTapPump) {
                if pumpAvailable {
                    DeviceLaneView(
                        iconSystemName: "keyboard.onehanded.left",
                        name: pumpName,
                        bar: podBar,
                        phase: podPhase,
                        label: podLabel,
                        labelSymbol: showsManualTempLabel ? "hand.raised.fill" : nil,
                        labelSymbolColor: .loopYellow,
                        sublabels: podSublabels
                    )
                } else {
                    AddDeviceLaneView(label: String(localized: "Add pump"))
                }
            }
        }
    }

    /// Each device sits on its own glass card — matching the header pills and
    /// the bottom panels — so the gap between the two cards replaces the old
    /// hairline divider. Tinted amber/red when the device needs attention.
    ///
    /// A real `Button` (not a bare tap gesture), so the whole card dims while
    /// pressed — the same press feedback the bottom panel's banner states give.
    /// `.plain` keeps the content's own colors instead of tinting it accent.
    @ViewBuilder private func deviceCard(
        tint: Color?,
        action: @escaping () -> Void,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // three compact rows fit the same card height
                .padding(.horizontal, 16)
                .padding(.vertical, DeviceLaneMetrics.cardPadding)
                // Healthy lanes keep the quiet neutral rim they always had (their `tint` is
                // nil, so the fill was already invisible). An alert lane passes
                // `tintOpacity: 0`, which drops the fill and promotes the rim to a full
                // outline — see `DeviceLaneMetrics`.
                // LANE-WASH: alert lanes take a wash as well as the rim — see
                // `DeviceLaneMetrics.alertWashOpacity`. To revert, put back `0` and
                // `alertRimOpacity` here.
                .glassPanel(
                    tint: tint,
                    tintOpacity: tint == nil ? 0.18 : DeviceLaneMetrics.alertWashOpacity,
                    strokeOpacity: tint == nil
                        ? DeviceLaneMetrics.restingRimOpacity
                        : DeviceLaneMetrics.alertWashRimOpacity
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Attention tint for the CGM card: red once into the grace window, amber/red
    /// for a warning/critical phase or an active status message; nil when healthy.
    private var sensorCardTint: Color? {
        if sensorBar?.graceRemaining != nil { return .loopRed }
        if let status = sensorStatus, status.color != .secondary { return status.color }
        switch sensorPhase {
        case .critical,
             .warning: return .orange
        case .normal: return nil
        }
    }

    /// Attention tint for the pump card: red in the grace window, amber/red for a
    /// warning/critical pod-time or low-reservoir phase; nil when healthy.
    private var podCardTint: Color? {
        if podBar?.graceRemaining != nil { return .loopRed }
        switch podPhase {
        case .critical,
             .warning: return .orange
        case .normal: return nil
        }
    }

    // MARK: - Sensor lane

    private var sensorBar: DeviceLaneBar? {
        // During a status override the bar goes neutral (its empty grey track):
        // the life reading isn't the story while the sensor is warming up /
        // searching / errored, and a colored fill would fight the card tint.
        if sensorStatus != nil { return nil }
        if let timeline = sensorTimeline {
            let nominal = timeline.expiresAt.timeIntervalSince(timeline.start)
            let grace = timeline.endsAt.timeIntervalSince(timeline.expiresAt)
            guard nominal > 0 else { return nil }
            var graceRemaining: Double?
            if grace > 0, timerDate >= timeline.expiresAt {
                graceRemaining = timeline.endsAt.timeIntervalSince(timerDate) / grace
            }
            return DeviceLaneBar(
                remaining: timeline.expiresAt.timeIntervalSince(timerDate) / nominal,
                graceRemaining: graceRemaining
            )
        }
        guard let progress = sensorProgress else { return nil }
        return DeviceLaneBar(remaining: 1 - progress.percentComplete, graceRemaining: nil)
    }

    private var sensorPhase: DeviceLanePhase {
        if let timeline = sensorTimeline {
            guard let arc = timeline.arcState(now: timerDate) else { return .critical }
            switch arc.state {
            case .critical: return .critical
            case .warning: return .warning
            default: return .normal
            }
        }
        switch sensorProgress?.progressState {
        case .critical: return .critical
        case .warning: return .warning
        default: return .normal
        }
    }

    /// Live status (warmup / stabilizing / signal loss / error / expired) with
    /// its severity color, mirroring what the glucose bobble used to show. Nil
    /// during healthy operation, when the countdown shows instead.
    private var sensorStatus: (text: String, color: Color)? {
        let lowered = cgmStatus?.localizedMessage.lowercased()
        if let lowered, lowered.contains("warming up") || lowered.contains("warmup") {
            let text = cgmWarmupEndsAt
                .map { DeviceLaneRemainingTimeFormatter.format(until: $0, now: timerDate) }
                ?? String(localized: "Warmup", comment: "CGM warmup status (short, for the device lane)")
            return (text, .orange)
        }
        if let lowered, lowered.contains("stabilizing") {
            return (String(localized: "Stabilizing", comment: "CGM stabilizing status"), .orange)
        }
        if let status = cgmStatus, !status.localizedMessage.isEmpty {
            // LibreLoop/G7 split labels with "\n" for two-line native pills.
            let oneLine = status.localizedMessage.replacingOccurrences(of: "\n", with: " ")
            let color: Color
            switch status.status {
            case .critical: color = .loopRed
            case .warning: color = .orange
            case .normal: color = .secondary
            }
            return (oneLine, color)
        }
        return nil
    }

    private var sensorLabel: String {
        if let status = sensorStatus { return status.text }
        if let timeline = sensorTimeline {
            if timerDate >= timeline.endsAt {
                return String(localized: "Replace sensor", comment: "Device lane label when the CGM session is fully over")
            }
            // Count down to expiry during normal life, then through the grace
            // period to the true end.
            if timerDate >= timeline.expiresAt {
                return String(localized: "Grace", comment: "Device lane label prefix during the post-expiry grace period")
                    + " " + DeviceLaneRemainingTimeFormatter.format(until: timeline.endsAt, now: timerDate)
            }
            return DeviceLaneRemainingTimeFormatter.format(until: timeline.expiresAt, now: timerDate)
        }
        if let expiresAt = sensorExpiresAt {
            if timerDate >= expiresAt {
                return String(localized: "Replace sensor", comment: "Device lane label when the CGM session is fully over")
            }
            return DeviceLaneRemainingTimeFormatter.format(until: expiresAt, now: timerDate)
        }
        return "--"
    }

    // MARK: - Pod lane

    /// LANE-MANUAL: a highlight that means the pod isn't in normal delivery.
    /// Manual Basal isn't one — it's a temp the user chose on a working pod.
    private var podHighlightBlocksGauge: Bool {
        pumpStatusHighlightMessage != nil && !pumpStatusHighlightIsManualBasal
    }

    private var podBar: DeviceLaneBar? {
        // A status highlight (No Pod, signal loss, fault…) means the pod isn't in
        // normal delivery, so the life/reservoir gauge is meaningless — and with
        // no pod paired it would just paint a full bar from the *previous* pod's
        // stale reservoir. Go neutral (empty track) and let the status text carry
        // it, mirroring how `sensorBar` blanks during a CGM status override.
        if podHighlightBlocksGauge { return nil }
        guard let expiresAt = podExpiresAt else {
            // Clockless pumps have no session timer to drain, so show a reservoir
            // gauge instead of an empty track. Capacity isn't exposed to the
            // view, so scale against a nominal full cartridge.
            guard let reservoir else { return nil }
            // 0xDEADBEEF is Omnipod's "50+ U" sentinel (and Omnipod has a clock,
            // so it never reaches here) — treat any such reading as full.
            if reservoir == 0xDEAD_BEEF { return DeviceLaneBar(remaining: 1, graceRemaining: nil) }
            let fraction = Double(truncating: reservoir as NSNumber) / Self.nominalReservoirCapacity
            return DeviceLaneBar(remaining: max(0, min(1, fraction)), graceRemaining: nil)
        }
        var graceRemaining: Double?
        if timerDate >= expiresAt {
            graceRemaining = expiresAt.addingTimeInterval(Self.podGraceWindow)
                .timeIntervalSince(timerDate) / Self.podGraceWindow
        }
        return DeviceLaneBar(
            remaining: expiresAt.timeIntervalSince(timerDate) / Self.podLife,
            graceRemaining: graceRemaining
        )
    }

    private var podPhase: DeviceLanePhase {
        guard let expiresAt = podExpiresAt else {
            // No session clock: warn off the reservoir instead, so the gauge
            // (and label/icon) go orange as insulin runs low.
            guard let reservoir, reservoir != 0xDEAD_BEEF else { return .normal }
            if reservoir <= Self.reservoirCritUnits { return .critical }
            if reservoir <= Self.reservoirWarnUnits { return .warning }
            return .normal
        }
        let remaining = expiresAt.timeIntervalSince(timerDate)
        if remaining <= Self.podCritWindow { return .critical }
        if remaining <= Self.podWarnWindow { return .warning }
        return .normal
    }

    private var podLabel: String {
        if podHighlightBlocksGauge, let message = pumpStatusHighlightMessage {
            // e.g. "⚠️ Insulin suspended" — takes over the whole readout.
            return message.replacingOccurrences(of: "\n", with: " ")
        }
        if showsManualTempLabel {
            // Time only: the hand (`labelSymbol`) says "manual", as do the loop pill
            // and the chart's basal tag. "✋ Manual – 2h 29m" pushed the reservoir
            // out of the lane on device (2026-10-14). The word stays only as the
            // fallback before the temp's end time reaches pump history.
            guard let manualTempEndsAt else {
                return String(localized: "Manual", comment: "Device lane label while a manual temp basal runs, end time unknown")
            }
            return DeviceLaneRemainingTimeFormatter.format(until: manualTempEndsAt, now: timerDate)
        }
        guard let expiresAt = podExpiresAt else {
            // Pumps without a session clock (Medtronic, Dana): lead with the
            // reservoir instead.
            return reservoirString ?? "--"
        }
        let shutdownAt = expiresAt.addingTimeInterval(Self.podGraceWindow)
        if timerDate >= shutdownAt {
            return String(localized: "Replace pod", comment: "View/Header when pod expired")
        }
        if timerDate >= expiresAt {
            return String(localized: "Grace", comment: "Device lane label prefix during the post-expiry grace period")
                + " " + DeviceLaneRemainingTimeFormatter.format(until: shutdownAt, now: timerDate)
        }
        return DeviceLaneRemainingTimeFormatter.format(until: expiresAt, now: timerDate)
    }

    /// LANE-MANUAL: a manual temp's countdown takes the readout while the pod is
    /// healthy. Once pod time is in its warning window or grace, the pod
    /// countdown wins — the bar alone can't say "replace pod".
    private var showsManualTempLabel: Bool {
        guard !podHighlightBlocksGauge,
              pumpStatusHighlightIsManualBasal || manualTempEndsAt != nil,
              podPhase == .normal
        else { return false }
        return podExpiresAt.map { timerDate < $0 } ?? true
    }

    private var podSublabels: [DeviceLaneSublabel] {
        var subs: [DeviceLaneSublabel] = []
        // When the label already leads with the reservoir (no session clock) or
        // a status message owns the readout, don't repeat it.
        if podExpiresAt != nil, !podHighlightBlocksGauge, let reservoirString {
            subs.append(DeviceLaneSublabel(text: reservoirString, color: reservoirColor))
        }
        if let percent = battery.first?.percent, battery.first?.display == true {
            subs.append(DeviceLaneSublabel(
                text: "\(Formatter.integerFormatter.string(for: percent) ?? "100") %",
                color: batteryColor
            ))
        }
        return subs
    }

    private var reservoirString: String? {
        guard let reservoir else { return nil }
        if reservoir == 0xDEAD_BEEF {
            return "50+ " + String(localized: "U", comment: "Insulin unit")
        }
        return (Formatter.integerFormatter.string(from: reservoir as NSNumber) ?? "") +
            String(localized: " U", comment: "Insulin unit")
    }

    /// Sublabels stay white until the value itself needs attention: colour on a
    /// readout always means "this one is low," never decoration. So a healthy
    /// reservoir reads white (matching the countdown) instead of insulin-blue —
    /// which kept the blue from fighting a red/amber card tint.
    private var reservoirColor: Color {
        guard let reservoir else { return .secondary }
        switch reservoir {
        case ...10: return .loopRed
        case ...30: return .orange
        default: return .primary
        }
    }

    private var batteryColor: Color {
        guard let percent = battery.first?.percent else { return .secondary }
        switch percent {
        case ...10: return .loopRed
        case ...20: return .orange
        default: return .primary
        }
    }
}

// MARK: - Lane primitives

struct DeviceLaneBar {
    /// 0...1 fraction of nominal (pre-expiry) life left. Clamped at render
    /// time; goes negative once the session is into its grace window.
    let remaining: Double
    /// 0...1 fraction of the grace window left. Nil until expiry; once set,
    /// the whole bar switches to this value and drains red.
    let graceRemaining: Double?
}

struct DeviceLaneSublabel {
    let text: String
    let color: Color
}

enum DeviceLanePhase {
    case normal
    case warning
    case critical

    /// Label/icon tint. Critical is orange like warning — red text, like the
    /// red fill, is reserved for the grace period (see `DeviceLaneView`'s
    /// accent override) so red always means exactly one thing.
    var color: Color {
        switch self {
        case .normal: return .primary
        case .critical,
             .warning: return .orange
        }
    }

    /// The gauge fill is always chromatic (the label handles neutral), so
    /// normal gets green rather than `.primary`. Critical stays orange —
    /// red fill is reserved for the grace period, so a red bar has exactly
    /// one meaning.
    var fillColor: Color {
        switch self {
        case .normal: return .loopGreen
        case .critical,
             .warning: return .orange
        }
    }
}

private struct DeviceLaneView: View {
    let iconSystemName: String
    let name: String
    let bar: DeviceLaneBar?
    let phase: DeviceLanePhase
    let label: String
    /// Overrides the label color when set (used for CGM status, which carries
    /// its own severity color); otherwise the label follows the phase accent.
    var labelColorOverride: Color? = nil
    /// LANE-MANUAL: SF Symbol leading the label (the manual-temp hand, matching
    /// the chart's basal tag). Same colour and size as the label text.
    var labelSymbol: String? = nil
    /// LANE-MANUAL: tints the symbol alone, so the time beside it stays a plain
    /// white reading. Amber links the hand to the chart's amber manual-temp tag;
    /// nil follows the label colour.
    var labelSymbolColor: Color? = nil
    let sublabels: [DeviceLaneSublabel]

    private static let barHeight: CGFloat = 6

    /// A leading status glyph (clock for "running out", triangle for a fault) was
    /// tried on device 2026-09-20 and removed: against the coloured rim, bar and
    /// countdown it added nothing, and it cost ~16pt in a half-width lane where the
    /// device name already truncates.
    ///
    /// It was argued for as the lane's only non-colour cue. That was wrong — the bar
    /// is a *draining* gauge, so an expiring device already reads as a nearly empty
    /// bar whatever its colour. Don't reintroduce it on that reasoning.
    ///
    /// LANE-WASH (2026-09-24): reintroduced on visual grounds, not that one — as a
    /// badge that *replaces* the device icon, so it adds no width. See
    /// `DeviceLaneStatusBadge`.

    /// The accent while this lane needs attention, `nil` when it is healthy.
    ///
    /// Deliberately the same precedence as `DeviceLanesView.sensorCardTint`, which
    /// drives the outline — so the icon is coloured in exactly the cases the lane is
    /// outlined, and the two can never disagree about whether something is wrong.
    ///
    /// A CGM status whose own colour is `.secondary` is informational, not an alert,
    /// and is filtered out here for the same reason the card tint filters it.
    private var alertAccent: Color? {
        if bar?.graceRemaining != nil { return .loopRed }
        if let labelColorOverride, labelColorOverride != .secondary { return labelColorOverride }
        switch phase {
        case .critical,
             .warning: return phase.color
        case .normal: return nil
        }
    }

    /// Once the grace window is running the lane's accent goes red — the
    /// only time red appears; phases only reach orange.
    private var accentColor: Color {
        bar?.graceRemaining != nil ? .loopRed : phase.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeviceLaneMetrics.rowSpacing) {
            // Row 1: icon + device name (identity, neutral). Small and grey,
            // matching the "No Active Adjustment" panel; yields first (ellipsis).
            HStack(spacing: 6) {
                // Takes the accent while the lane needs attention, as this file's header
                // has always specified — the code had drifted to a hardcoded `.secondary`.
                // Falls back to that grey when healthy, so a normal lane is unchanged:
                // `accentColor` is `.primary` in the normal phase, and using it unguarded
                // would brighten every healthy icon to white.
                //
                // The *name* beside it stays neutral in every phase — identity, not status.
                // LANE-WASH: an alert lane swaps the device icon for a filled status
                // badge. It *replaces* the icon rather than adding a glyph beside it,
                // so it costs ~3pt, not the ~16pt that sank the 2026-09-20 attempt.
                if let alertAccent {
                    DeviceLaneStatusBadge(
                        accent: alertAccent,
                        systemName: alertAccent == .loopRed ? "exclamationmark.triangle.fill" : "clock.fill"
                    )
                } else {
                    Image(systemName: iconSystemName)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Text(name)
                    .font(.footnote).fontWeight(.medium).fontDesign(.rounded)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }

            // Row 2: the draining gauge, full width.
            if let bar {
                laneBar(bar)
            } else {
                // No session clock — keep the track so the row reads as a lane,
                // just without fill or playhead.
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: Self.barHeight)
            }

            // Row 3: sub-readouts (reservoir units, battery) on the left, the
            // countdown / status on the right — same font size, so they read as a
            // pair. The countdown is white in the normal state, colouring on
            // warning/grace so alerts still read. (CGM has no units, so its
            // countdown simply sits on the right, matching the pump.)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ForEach(sublabels.indices, id: \.self) { index in
                    Text(sublabels[index].text)
                        .font(.footnote).fontWeight(.semibold).fontDesign(.rounded)
                        .foregroundStyle(sublabels[index].color)
                        .lineLimit(1)
                        // LANE-MANUAL: never truncate a reading — "5…" is worse than
                        // nothing. When the row is short, the label gives way instead.
                        .fixedSize()
                }

                Spacer(minLength: 6)

                // A heavier weight while alerting was tried (LANE-WASH, 2026-09-24) and
                // dropped: with the wash and badge in place it added nothing.
                Group {
                    if let labelSymbol {
                        Text(Image(systemName: labelSymbol))
                            .foregroundStyle(labelSymbolColor ?? labelColorOverride ?? accentColor)
                            + Text(" ") + Text(label)
                    } else {
                        Text(label)
                    }
                }
                .font(.footnote).fontWeight(.semibold).fontDesign(.rounded)
                .foregroundStyle(labelColorOverride ?? accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            }
        }
    }

    @ViewBuilder private func laneBar(_ bar: DeviceLaneBar) -> some View {
        // Once the grace window is running, the whole bar becomes the grace
        // gauge: refilled red at expiry, draining toward hard shutdown.
        let inGrace = bar.graceRemaining != nil
        let fraction = max(0, min(1, bar.graceRemaining ?? bar.remaining))

        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                if fraction > 0 {
                    Capsule()
                        .fill(inGrace ? Color.loopRed : phase.fillColor)
                        // Keep a sliver visible right up to the end.
                        .frame(width: max(width * fraction, Self.barHeight))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: Self.barHeight)
        .animation(.easeInOut(duration: 0.25), value: fraction)
    }
}

// MARK: - LANE-WASH: alert badge

/// LANE-WASH: filled circle in the lane's accent with a dark glyph, standing in
/// for the device icon while the lane needs attention. Sized to the footnote line
/// so row 1 doesn't grow.
private struct DeviceLaneStatusBadge: View {
    let accent: Color
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.75))
            .frame(width: 15, height: 15)
            .background(Circle().fill(accent))
    }
}

/// Empty-state row: the device's way in when there is no device. Mirrors the
/// lane layout so the two states read as the same slot.
private struct AddDeviceLaneView: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.callout)
                .foregroundStyle(Color.secondary)

            Text(label)
                .font(.footnote).fontWeight(.semibold).fontDesign(.rounded)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
    }
}

// MARK: - Previews

/// The device lanes' remaining-time text: `2d 18h` over a day, `18h 59m` under
/// one, `45m` under an hour.
///
/// A local copy of upstream's `SensorRemainingTimeFormatter` (in
/// `CGMSensorDisplayState.swift`), differing only in the under-a-day case. That
/// one keeps the two largest units and so drops the minutes whenever there are
/// hours: 18 h 59 m read `18h`, an hour short of the truth. Copied rather than
/// edited because its file exists upstream and this one does not, so the change
/// can never conflict on a merge.
///
/// Over a day the minutes are still dropped, by choice (Gary, 2026-09-23): they
/// add width and nothing a decision hangs on. Like the original it floors, so it
/// never shows more time left than there is.
enum DeviceLaneRemainingTimeFormatter {
    static func format(until expiresAt: Date, now: Date = Date()) -> String {
        let remaining = max(0, expiresAt.timeIntervalSince(now))
        let totalMinutes = Int(remaining) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        let d = String(localized: "d", comment: "Abbreviation for Days")
        let h = String(localized: "h", comment: "Abbreviation for Hours")
        let m = String(localized: "m", comment: "Abbreviation for Minutes")
        if days > 0, hours > 0 { return "\(days)\(d) \(hours)\(h)" }
        if days > 0 { return "\(days)\(d)" }
        if hours > 0, minutes > 0 { return "\(hours)\(h) \(minutes)\(m)" }
        if hours > 0 { return "\(hours)\(h)" }
        if minutes > 0 { return "\(minutes)\(m)" }
        return "<" + "\u{00A0}" + "1" + "\u{00A0}" + m
    }
}

#Preview("Lanes — G7 midlife, pod fresh") {
    let start = Date().addingTimeInterval(-5 * 24 * 3600)
    return DeviceLanesView(
        timerDate: Date(),
        cgmAvailable: true,
        cgmName: "Dexcom G7",
        sensorTimeline: SensorLifecycleTimeline(
            start: start,
            expiresAt: start.addingTimeInterval(10 * 24 * 3600),
            endsAt: start.addingTimeInterval(10 * 24 * 3600 + 12 * 3600),
            finalPhaseDuration: SensorLifecycleTimeline.defaultFinalPhaseDuration
        ),
        sensorProgress: nil,
        sensorExpiresAt: nil,
        pumpAvailable: true,
        pumpName: "Omnipod DASH",
        podExpiresAt: Date().addingTimeInterval(52 * 3600),
        reservoir: 0xDEAD_BEEF,
        battery: [],
        pumpStatusHighlightMessage: nil,
        onTapSensor: {},
        onTapPump: {}
    )
    .padding(20)
    .background(Color.bgDarkBlue)
    .preferredColorScheme(.dark)
}

#Preview("Lanes — final day, pod critical") {
    let start = Date().addingTimeInterval(-(10 * 24 * 3600) + 8 * 3600)
    return DeviceLanesView(
        timerDate: Date(),
        cgmAvailable: true,
        cgmName: "Dexcom G7",
        sensorTimeline: SensorLifecycleTimeline(
            start: start,
            expiresAt: start.addingTimeInterval(10 * 24 * 3600),
            endsAt: start.addingTimeInterval(10 * 24 * 3600 + 12 * 3600),
            finalPhaseDuration: SensorLifecycleTimeline.defaultFinalPhaseDuration
        ),
        sensorProgress: nil,
        sensorExpiresAt: nil,
        pumpAvailable: true,
        pumpName: "Omnipod DASH",
        podExpiresAt: Date().addingTimeInterval(3 * 3600),
        reservoir: 12,
        battery: [],
        pumpStatusHighlightMessage: nil,
        onTapSensor: {},
        onTapPump: {}
    )
    .padding(20)
    .background(Color.bgDarkBlue)
    .preferredColorScheme(.dark)
}

#Preview("Lanes — both in grace") {
    // Sensor expired 4 h ago (8 h of its 12 h grace left); pod expired
    // 2 h ago (6 h of its 8 h grace left).
    let start = Date().addingTimeInterval(-(10 * 24 * 3600) - 4 * 3600)
    return DeviceLanesView(
        timerDate: Date(),
        cgmAvailable: true,
        cgmName: "Dexcom G7",
        sensorTimeline: SensorLifecycleTimeline(
            start: start,
            expiresAt: start.addingTimeInterval(10 * 24 * 3600),
            endsAt: start.addingTimeInterval(10 * 24 * 3600 + 12 * 3600),
            finalPhaseDuration: SensorLifecycleTimeline.defaultFinalPhaseDuration
        ),
        sensorProgress: nil,
        sensorExpiresAt: nil,
        pumpAvailable: true,
        pumpName: "Omnipod DASH",
        podExpiresAt: Date().addingTimeInterval(-2 * 3600),
        reservoir: 8,
        battery: [],
        pumpStatusHighlightMessage: nil,
        onTapSensor: {},
        onTapPump: {}
    )
    .padding(20)
    .background(Color.bgDarkBlue)
    .preferredColorScheme(.dark)
}

#Preview("Lanes — nothing paired") {
    DeviceLanesView(
        timerDate: Date(),
        cgmAvailable: false,
        cgmName: "",
        sensorTimeline: nil,
        sensorProgress: nil,
        sensorExpiresAt: nil,
        pumpAvailable: false,
        pumpName: "",
        podExpiresAt: nil,
        reservoir: nil,
        battery: [],
        pumpStatusHighlightMessage: nil,
        onTapSensor: {},
        onTapPump: {}
    )
    .padding(20)
    .background(Color.bgDarkBlue)
    .preferredColorScheme(.dark)
}

#Preview("Lanes — LANE-MANUAL manual temp") {
    let start = Date().addingTimeInterval(-3 * 24 * 3600)
    return DeviceLanesView(
        timerDate: Date(),
        cgmAvailable: true,
        cgmName: "Dexcom G7",
        sensorTimeline: SensorLifecycleTimeline(
            start: start,
            expiresAt: start.addingTimeInterval(10 * 24 * 3600),
            endsAt: start.addingTimeInterval(10 * 24 * 3600 + 12 * 3600),
            finalPhaseDuration: SensorLifecycleTimeline.defaultFinalPhaseDuration
        ),
        sensorProgress: nil,
        sensorExpiresAt: nil,
        pumpAvailable: true,
        pumpName: "Omnipod DASH",
        podExpiresAt: Date().addingTimeInterval(41 * 3600),
        reservoir: 0xDEAD_BEEF,
        battery: [],
        pumpStatusHighlightMessage: "⚠️\nManual Basal",
        pumpStatusHighlightIsManualBasal: true,
        manualTempEndsAt: Date().addingTimeInterval(47 * 60),
        onTapSensor: {},
        onTapPump: {}
    )
    .padding(20)
    .background(Color.bgDarkBlue)
    .preferredColorScheme(.dark)
}
