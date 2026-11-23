import SwiftUI

// MARK: - Header pills, device lanes, and basal tag (redesign grafted onto Home Layout v2)

/// Moved here from `LoopView.swift` on 2026-09-15, when the loop pill was switched to
/// upstream's dosing-mode design wholesale. The loop pill no longer uses it; the IOB,
/// COB and eventual-BG pills below still do.
///
/// Shared geometry for the four pills flanking the bobble (IOB, COB, loop,
/// eventual BG). Every pill sizes its text slot to the same hidden template
/// string — the widest realistic value — so all four render identically
/// without a hard-coded width that would leave dead space or fight Dynamic
/// Type.
enum HeaderPill {
    /// Sized for the common case; rarer wide values ("12.35 U", "looping")
    /// compress via `minimumScaleFactor` instead of stretching every pill.
    static let widthTemplate = "8.88 U"
    static let iconWidth: CGFloat = 16
    static let verticalPadding: CGFloat = 7
    static let horizontalPadding: CGFloat = 9
    /// Extra padding on each side of the readout pills only. The loop pill's outline is
    /// upstream's centred `.stroke(lineWidth: 2)`, which overhangs its frame by 1pt all
    /// round; growing the readouts by the same 1pt lines their outside edges up with it,
    /// without touching `LoopView`.
    static let loopOutlineOverhang: CGFloat = 1
    /// Ghost capsule drawn behind the loop ring *outside* closed loop.
    ///
    /// `LoopView` only draws its capsule when `showsCaption` — i.e. full
    /// automation. In open loop, LGS and Basal Testing it collapses to a bare
    /// 26pt ring, so the loop slot loses the footprint the three readout pills
    /// keep and the column visibly shrinks around it. That is what makes the
    /// alarms bell look disjointed in those modes: the bell is pinned to the
    /// header frame, so it has nothing stable to line up against.
    ///
    /// The ghost reserves a pill-sized slot and fills it at the same faint
    /// opacity the readout pills use, so the loop element holds one footprint in
    /// every dosing mode. It is a fill only, never a stroke — a stroke would read
    /// as a control and compete with the real closed-loop capsule.
    ///
    /// Set to 0 to disable: the slot collapses back to the bare ring and nothing
    /// else changes.
    static let ghostCapsuleOpacity: Double = 0.05
}

extension Home.RootView {
    /// Read-only readout: a faint fill capsule — no stroke, no glass rim — so it
    /// reads as a quiet container rather than a hard pill. Glass is reserved for
    /// the controls (tinted loop pill, alarms button), so the readouts stay a
    /// step quieter without floating loose. Shares `HeaderPill`'s width template
    /// so IOB/COB/eventual render at identical sizes.
    @ViewBuilder private func headerReadoutPill(
        iconSystemName: String,
        iconColor: Color,
        text: String
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconSystemName)
                .font(.callout)
                .foregroundColor(iconColor)
                .frame(width: HeaderPill.iconWidth, alignment: .center)
            ZStack(alignment: .center) {
                // Invisible width template — see `HeaderPill`.
                Text(HeaderPill.widthTemplate).hidden()
                Text(text)
            }
            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .padding(.vertical, HeaderPill.verticalPadding + HeaderPill.loopOutlineOverhang)
        .padding(.horizontal, HeaderPill.horizontalPadding + HeaderPill.loopOutlineOverhang)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    /// Invisible stand-in with a readout pill's exact geometry — icon slot, text
    /// template, paddings — used to size the ghost capsule. Built from the same
    /// `HeaderPill` constants as `headerReadoutPill`, so the two can't drift.
    @ViewBuilder private var loopSlotTemplate: some View {
        HStack(spacing: 5) {
            // A real `Image`, exactly as `headerReadoutPill` uses — NOT `Color.clear`.
            // Colour is infinitely flexible, so `.frame(width:)` pins only the width and
            // it stretches to whatever height is offered, dragging the capsule with it.
            Image(systemName: "circle")
                .font(.callout)
                .frame(width: HeaderPill.iconWidth, alignment: .center)
            Text(HeaderPill.widthTemplate)
                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.vertical, HeaderPill.verticalPadding + HeaderPill.loopOutlineOverhang)
        .padding(.horizontal, HeaderPill.horizontalPadding + HeaderPill.loopOutlineOverhang)
        .hidden()
    }

    /// Gives the loop element a constant, pill-sized footprint in every dosing
    /// mode. See `HeaderPill.ghostCapsuleOpacity`.
    ///
    /// In closed loop `LoopView` draws its own capsule at exactly this size, so
    /// this passes straight through — wrapping it there would double the chrome.
    /// Outside closed loop the hidden template claims the slot and the ring
    /// centres inside it; the `ZStack` (not `.background`) is what makes the slot
    /// real, since a background paints outside the layout and the column would
    /// still collapse around the bare ring.
    @ViewBuilder private func loopSlot(@ViewBuilder _ content: () -> some View) -> some View {
        if LoopView.showsCaption(automation: state.dosingMode.automation) || HeaderPill.ghostCapsuleOpacity <= 0 {
            content()
        } else {
            ZStack {
                loopSlotTemplate
                content()
            }
            .background(Capsule().fill(Color.primary.opacity(HeaderPill.ghostCapsuleOpacity)))
        }
    }

    /// IOB and COB readout pills. Device state (pod timer, reservoir,
    /// battery) lives in the device lanes above the chart.
    @ViewBuilder func leftHeaderPanel(_: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            headerReadoutPill(
                iconSystemName: "syringe.fill",
                iconColor: Color.insulin,
                text: (
                    Formatter.decimalFormatterWithTwoFractionDigits
                        .string(from: state.currentIOB as NSNumber) ?? "0"
                ) +
                    String(localized: " U", comment: "Insulin unit")
            )

            headerReadoutPill(
                iconSystemName: "fork.knife",
                iconColor: .loopYellow,
                text: (
                    Formatter.decimalFormatterWithTwoFractionDigits.string(
                        from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                    ) ?? "0"
                ) +
                    String(localized: " g", comment: "gram of carbs")
            )
        }
    }

    /// The device lanes, or — while the chart is scrubbed — the readout for the point under
    /// the finger.
    ///
    /// Upstream (#1455) moved that readout out of the chart and into its IOB / COB row. This
    /// layout has no such row: IOB and COB are header pills, and the lanes hold the slot. So
    /// the readout takes the lanes' slot instead, with the pattern upstream uses for its row —
    /// both halves stay mounted and cross-fade on `opacity`, because a removal transition
    /// does not play over a glass background. `ChartSelectionRow`, the scrub state and
    /// `updateChartReadout` are all upstream's, unchanged.
    @ViewBuilder var deviceLanesOrChartReadout: some View {
        ZStack {
            deviceLanes
                .padding(.horizontal, 10)
                .opacity(isChartReadoutVisible ? 0 : 1)
                .allowsHitTesting(!isChartReadoutVisible)

            // Renders from the last resolved selection, which is deliberately not cleared on
            // decay: the row keeps its values to fade out with, and stays invisible and
            // untouchable while no readout is showing.
            if let readoutDate = chartReadoutDate,
               let selectedGlucose = ChartSelectionLookup.glucose(at: readoutDate, in: state.glucoseFromPersistence)
            {
                ChartSelectionRow(
                    selectedGlucose: selectedGlucose,
                    determination: chartReadoutDeterminationDate.flatMap {
                        ChartSelectionLookup.determination(at: $0, in: state.enactedAndNonEnactedDeterminations)
                    },
                    units: state.units,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    isSmoothingEnabled: state.settingsManager.settings.smoothGlucose
                )
                .padding(.horizontal)
                .opacity(isChartReadoutVisible ? 1 : 0)
                .allowsHitTesting(isChartReadoutVisible)
            }
        }
    }

    /// The session lanes above the chart. Each lane is its device's tap
    /// target — the pump column is gone, so the pod lane is the pump's
    /// entry point (including setup, via the "Add pump" empty state).
    var deviceLanes: some View {
        DeviceLanesView(
            timerDate: state.timerDate,
            cgmAvailable: state.cgmAvailable,
            cgmName: state.cgmName,
            sensorTimeline: state.cgmSensorTimeline,
            sensorProgress: state.cgmProgressHighlight,
            sensorExpiresAt: state.cgmSensorExpiresAt,
            cgmStatus: state.cgmDisplayState,
            cgmWarmupEndsAt: state.cgmWarmupEndsAt,
            pumpAvailable: state.pumpDisplayState != nil,
            pumpName: state.pumpName,
            podExpiresAt: state.pumpExpiresAtDate,
            reservoir: state.reservoir,
            battery: state.batteryFromPersistence,
            pumpStatusHighlightMessage: state.pumpStatusHighlightMessage,
            pumpStatusHighlightIsManualBasal: state.pumpStatusHighlightIsManualBasal,
            manualTempEndsAt: state.manualTempBasalEndsAt,
            onTapSensor: {
                if !state.cgmAvailable {
                    showCGMSelection.toggle()
                } else {
                    state.shouldDisplayCGMSetupSheet.toggle()
                }
            },
            onTapPump: {
                if state.pumpDisplayState == nil {
                    // shows user confirmation dialog with pump model choices, then proceeds to setup
                    showPumpSelection.toggle()
                } else {
                    // sends user to pump settings
                    state.shouldDisplayPumpSetupSheet.toggle()
                }
            }
        )
    }

    /// What is driving delivery right now. This is a case rather than a
    /// style flag because it decides the tag's *shape* — filled when the
    /// algorithm picked the rate, outlined when the pump is only walking
    /// the basal profile — which is readable without a second tag to
    /// compare against.
    enum BasalTagKind {
        case temp
        case manualTemp
        case scheduled
    }

    struct BasalTagContent {
        let rate: Decimal
        let kind: BasalTagKind
    }

    /// What the pump is actually delivering right now, from upstream's resolver (#1556).
    ///
    /// This used to fall back to `state.tempBasals.last` whenever
    /// `apsManager.isScheduledBasal` wasn't true — the newest temp in history whether or
    /// not it was still running. The flag protected it when the pump reported scheduled
    /// delivery promptly, but a temp that expired on its own, or the gap before the next
    /// pump status, left a stale rate on screen: the bug upstream fixed as #1544.
    /// `activeBasalDelivery` works each temp's end time out from its start and duration
    /// and resolves against the real clock, and it is backed by upstream's tests.
    ///
    /// Only the data source changed. The tag's design — fill vs outline for loop-set vs
    /// scheduled, amber for a manual temp, the Suspended capsule — is untouched.
    var basalTagContent: BasalTagContent? {
        switch state.activeBasalDelivery {
        case .none,
             .suspended:
            // suspended has its own capsule in `basalRateTag`
            return nil
        case let .temp(rate):
            let isManual = state.apsManager?.isManualTempBasal ?? false
            return BasalTagContent(rate: rate, kind: isManual ? .manualTemp : .temp)
        case let .scheduled(rate):
            return BasalTagContent(rate: rate, kind: .scheduled)
        }
    }

    // Returns the scheduled basal rate for the current time based on the saved basal scheduled.
    // Would be better if in the future BasalDeliveryStatus could be updated to include this info.
    func scheduledBasalDeliveryRate(at when: Date) -> NSNumber? {
        let calendar = Calendar(identifier: .gregorian)
        // calendar.timeZone = timeZone /// should come from pumpManager in case it's different!

        let hours = calendar.component(.hour, from: when)
        let minutes = calendar.component(.minute, from: when)
        let totalMinutes = hours * 60 + minutes

        if let rate = findBasalRateForOffset(for: totalMinutes, in: state.basalProfile) {
            return NSDecimalNumber(decimal: rate)
        }
        return nil
    }

    @ViewBuilder func rightHeaderPanel(_: GeometryProxy) -> some View {
        // Centred, as upstream's own panel is ("Centre the loop ring over the forecast
        // row"). Outside closed loop upstream's LoopView is a bare ring with no capsule,
        // and trailing alignment pinned it flush against the screen edge.
        VStack(alignment: .center, spacing: 12) {
            /// Loop status — upstream's `LoopView`, unmodified; the ghost readout pills
            /// (IOB/COB/eventual) stay fill-only.
            loopSlot {
                LoopView(
                    dosingMode: state.dosingMode,
                    timerDate: state.timerDate,
                    isLooping: state.isLooping,
                    lastLoopDate: state.lastLoopDate,
                    manualTempBasal: state.manualTempBasal,
                    lastGlucoseDate: state.lastGlucoseDate,
                    lastPumpCommsDate: state.lastPumpCommsDate,
                    hasDeviceIssue: state.hasDeviceIssue,
                    determination: state.determinationsFromPersistence
                )
            }
            // on the slot, not the ring, so the whole pill-sized area is tappable
            // outside closed loop — matching the capsule's target in closed loop
            .contentShape(Capsule())
            .onTapGesture {
                state.isLoopStatusPresented = true
            }
            // Same accessibility as upstream's call site in HomeRootView+Header.swift.
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(String(localized: "Opens loop status", comment: "Accessibility hint")))
            .accessibilityAction { state.isLoopStatusPresented = true }

            headerReadoutPill(
                iconSystemName: "arrow.right.circle",
                iconColor: .primary,
                text: {
                    if let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG {
                        let eventualGlucose = eventualBG as Decimal
                        return eventualGlucose.formatted(for: state.units)
                    }
                    return "--"
                }()
            )
        }
    }

    /// Basal-rate tag overlaid on the chart's basal strip — the rate is
    /// already drawn there as a curve, so the number labels the "now" edge
    /// of the line it describes instead of duplicating it as a header pill.
    /// (The "Max IOB is 0" warning is owned by the multi-use panel banner.)
    @ViewBuilder var basalRateTag: some View {
        /// Only describe delivery if the pump is actually available
        /// (e.g. pod paired & not faulted). `apsManager` is an implicitly-
        /// unwrapped optional, so unwrap it safely — this tag is evaluated on
        /// every chart layout pass, possibly before injection has resolved it.
        /// Upstream PR 1681 removed `APSManager.isScheduledBasal`, whose `nil` meant the
        /// same two states as below, so read them from the pump's status directly.
        if let apsManager = state.apsManager,
           let delivery = apsManager.pumpManager?.status.basalDeliveryState,
           delivery != .pumpInoperable, delivery != .active(.distantPast)
        {
            if state.activeBasalDelivery == .suspended {
                /// Suspension is the loudest thing the strip can say, so
                /// it takes the slot rather than leaving it empty.
                basalTagCapsule(tint: .loopRed, filled: false) {
                    Image(systemName: "pause.circle.fill")
                    Text(String(localized: "Suspended", comment: "Pump has suspended insulin delivery"))
                }
            } else if let content = basalTagContent {
                /// Amber, not `.loopManualTemp` — that asset is a hair
                /// away from `Insulin` (#1E95FB vs #1E96FC), so it would
                /// make "you set this" look like "the loop set this".
                /// The loop pill keeps the blue asset: there, blue reads
                /// against green/yellow/red, and amber would collide with
                /// its "loop running late" state.
                let tint: Color = content.kind == .manualTemp ? .loopYellow : .insulinTintColor
                basalTagCapsule(tint: tint, filled: content.kind != .scheduled) {
                    if content.kind == .manualTemp {
                        Image(systemName: "hand.raised.fill")
                    }
                    Text(
                        Formatter.decimalFormatterWithThreeFractionDigits
                            .string(from: content.rate as NSNumber) ?? "0"
                    )
                    Text(String(localized: "U/hr", comment: "Insulin units per hour"))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .opacity(0.7)
                }
            }
        }
    }

    /// The basal strip's tag. Tinted to the curve it labels and backed by
    /// material so the scheduled-basal line shows through instead of being
    /// severed. `filled` carries the delivery mode: solid when the loop
    /// chose the rate, outline when it's just the profile.
    @ViewBuilder private func basalTagCapsule(
        tint: Color,
        filled: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .font(.footnote)
        .fontWeight(.bold)
        .fontDesign(.rounded)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .allowsTightening(true)
        .foregroundStyle(filled ? Color.bgDarkBlue : tint)
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        // Liquid Glass: a strong tint reads as the "loop chose this" fill; a
        // faint tint + stroke as the outlined scheduled-profile rate. The glass
        // keeps the basal line legible through the tag either way.
        .glassCapsule(
            tint: tint,
            tintOpacity: filled ? 0.9 : 0.14,
            strokeOpacity: filled ? 0.3 : 0.55,
            strokeWidth: filled ? 1 : 1.5
        )
    }
}

// MARK: - Therapy profile capsule (PROFILE-HEADER)

extension HeaderPill {
    /// PROFILE-HEADER: the active therapy profile sits in the header's top-leading
    /// corner, opposite the alarms bell, instead of upstream's chip on the chart's
    /// basal strip (PR 1788). Set to `false` to go back to upstream's chip: the
    /// header capsule disappears and the chart chip returns. Nothing else changes.
    static let profileInHeader = true
}

extension Home.RootView {
    /// Concrete return type on purpose: `HomeRootView.swift` calls this, and an opaque
    /// `some View` here changed type with every restyle. Incremental builds then left the
    /// caller compiled against the old layout and Home crashed on redraw (23 Nov 2026).
    /// Restyling `ProfileHeaderButton.body` doesn't change this signature.
    var profileHeaderButton: ProfileHeaderButton {
        ProfileHeaderButton(
            profileName: HeaderPill.profileInHeader ? state.activeTherapyProfileName : nil,
            action: openTherapyProfiles
        )
    }

    /// Same route as the other Home → Settings shortcuts: switch tab, push the screen.
    func openTherapyProfiles() {
        selectedTab = 3
        settingsPath.append(Screen.therapyProfiles)
    }
}

/// PROFILE-HEADER label. Only present while there is more than one profile (upstream's
/// rule: `activeTherapyProfileName` is nil while Default is the only one). On Default only
/// the icon shows, in a circle matching the bell; another profile shows the icon and its
/// name, so a name in the corner means "not Default". Tapping opens Settings → Therapy Profiles.
struct ProfileHeaderButton: View {
    let profileName: String?
    let action: () -> Void

    var body: some View {
        if let profileName {
            let isDefault = profileName == TrioTherapyProfile.defaultName

            Button(action: action) {
                // Mirrors the bell opposite: on Default the same 34pt glass circle as the
                // idle bell; on another profile a 34pt glass capsule styled like the
                // bell's snoozed capsule (footnote bold), so the two corners match.
                if isDefault {
                    Image(systemName: "person.crop.circle")
                        .font(.callout) // same size as the readout pills' icons
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .glassCircle(strokeOpacity: 0.18)
                } else {
                    // Same layout as the readout pills below; the full name always shows.
                    // Neutral icon: a profile is a normal choice, not a warning.
                    HeaderControlPillLabel(
                        systemImage: "person.crop.circle",
                        iconColor: .secondary,
                        // Grey: a profile is a calm choice; the snooze opposite stays white.
                        textColor: .secondary,
                        text: profileName
                    )
                    // LANE-STYLE: neutral, like a healthy device lane.
                    .headerStatusCapsule(tint: nil)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Active profile \(profileName)"))
            .accessibilityHint(Text("Opens Therapy Profiles"))
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// PILL-FLOOR: label for the header's glass control capsules (profile, snoozed alarms),
/// laid out exactly like a readout pill (IOB, COB, eventual): the icon in the fixed
/// `HeaderPill.iconWidth` slot on the left, the text centred in a slot at least
/// `HeaderPill.widthTemplate` wide. So the capsule is never narrower than the pills
/// below, its icon lines up with theirs, and longer text widens only the text slot.
///
/// Deliberately a copy of `headerReadoutPill`'s geometry rather than shared with it, so
/// this stream can be pulled out alone. Keep the two in step if `HeaderPill` changes.
struct HeaderControlPillLabel: View {
    let systemImage: String
    /// Coloured like the readout pills' icons.
    let iconColor: Color
    /// White for a value that should stand out (snooze); grey for a calm one (profile).
    var textColor: Color = .primary
    let text: String

    /// Text first shrinks to this scale to stay within the pill width; only beyond that
    /// does the pill widen.
    static let minimumTextScale: CGFloat = 0.75

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.callout) // same size as the readout pills' icons
                .foregroundStyle(iconColor)
                .frame(width: HeaderPill.iconWidth, alignment: .center)
            ShrinkThenGrowLayout(minimumScale: Self.minimumTextScale) {
                // Invisible width template, in the readout pills' own font — see `HeaderPill`.
                Text(HeaderPill.widthTemplate)
                    .hidden()
                    .accessibilityHidden(true)
                Text(text)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    // Looser than `minimumTextScale` on purpose: the slot is sized for that
                    // scale, but SwiftUI shrinks in coarse steps and truncated right at the
                    // limit ("No Cycli…"). The spare range only absorbs that rounding.
                    .minimumScaleFactor(Self.minimumTextScale - 0.25)
            }
            // The readout pills' value font, so text and template are the same size.
            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
        }
        .padding(.horizontal, HeaderPill.horizontalPadding + HeaderPill.loopOutlineOverhang)
        .frame(height: 34)
    }
}

/// Two subviews: a width template, then the text. The slot is the template's width when
/// the text fits it at full size or after shrinking to `minimumScale`; otherwise it widens
/// just enough for the text at `minimumScale`. The text is then offered exactly the slot
/// width, so its `minimumScaleFactor` does the shrinking.
struct ShrinkThenGrowLayout: Layout {
    let minimumScale: CGFloat

    private func slotWidth(_ subviews: Subviews) -> CGFloat {
        guard subviews.count == 2 else { return 0 }
        let template = subviews[0].sizeThatFits(.unspecified).width
        let natural = subviews[1].sizeThatFits(.unspecified).width
        // +1 so rounding never pushes the minimum-scale text into truncation.
        return max(template, (natural * minimumScale).rounded(.up) + 1)
    }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = slotWidth(subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let slot = ProposedViewSize(width: bounds.width, height: bounds.height)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: slot)
        }
    }
}

// MARK: - Lane-style status capsule (LANE-STYLE)

extension HeaderPill {
    /// LANE-STYLE: the active header pills (non-Default profile, snoozed alarms) are drawn
    /// like the device lanes rather than as glass: they report a state, and glass is
    /// reserved for the controls at rest. Values copy `DeviceLaneMetrics` as they resolve
    /// through `GlassPanelBackground`: a healthy lane is no fill and a 0.18 neutral rim;
    /// an alert lane is an 18% wash (0.12 × `panelTintBoost` 1.5) and a 0.6 rim.
    static let statusRestingRimOpacity: Double = 0.18
    static let statusAlertWashOpacity: Double = 0.18
    static let statusAlertRimOpacity: Double = 0.6
}

extension View {
    /// LANE-STYLE capsule: `tint` nil is the neutral healthy-lane look; a tint (e.g.
    /// `.orange` for a snooze) is the alert-lane wash and rim.
    func headerStatusCapsule(tint: Color?) -> some View {
        background(
            Capsule().fill((tint ?? .clear).opacity(HeaderPill.statusAlertWashOpacity))
        )
        .overlay(
            Capsule().strokeBorder(
                (tint ?? .primary).opacity(
                    tint == nil ? HeaderPill.statusRestingRimOpacity : HeaderPill.statusAlertRimOpacity
                ),
                lineWidth: 1
            )
        )
    }
}
