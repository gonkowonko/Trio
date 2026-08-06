import SwiftUI
import UIKit

// MARK: - Header pills, device lanes, and basal tag (redesign grafted onto Home Layout v2)

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
        .padding(.vertical, HeaderPill.verticalPadding)
        .padding(.horizontal, HeaderPill.horizontalPadding)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
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

    var basalTagContent: BasalTagContent? {
        guard let apsManager = state.apsManager else {
            return nil
        }

        if apsManager.isScheduledBasal == true {
            guard let scheduledRate = scheduledBasalDeliveryRate(at: Date())?.decimalValue else {
                return nil
            }
            return BasalTagContent(rate: scheduledRate, kind: .scheduled)
        }

        guard let tempRate = state.tempBasals.last?.tempBasal?.rate as? Decimal else {
            return nil
        }

        return BasalTagContent(
            rate: tempRate,
            kind: apsManager.isManualTempBasal ? .manualTemp : .temp
        )
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
        // Right-aligned so every pill keeps its right edge on the margin; a wider
        // loop pill ("looping" / "Manual") then grows leftward instead of
        // shoving the narrower eventual pill off the edge.
        VStack(alignment: .trailing, spacing: 12) {
            /// Loop pill — tinted/stroked to mark it tappable; the ghost readout
            /// pills (IOB/COB/eventual) stay fill-only.
            LoopView(
                closedLoop: state.closedLoop,
                timerDate: state.timerDate,
                isLooping: state.isLooping,
                lastLoopDate: state.lastLoopDate,
                manualTempBasal: state.manualTempBasal,
                determination: state.determinationsFromPersistence
            )
            .onTapGesture {
                state.isLoopStatusPresented = true
            }
            .onLongPressGesture {
                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                impactHeavy.impactOccurred()
                state.runLoop()
            }

            headerReadoutPill(
                iconSystemName: "arrow.right.circle",
                iconColor: .primary,
                text: {
                    if let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG {
                        let eventualGlucose = eventualBG as Decimal
                        return state.units == .mgdL ? eventualGlucose.description : eventualGlucose.formattedAsMmolL
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
        if let apsManager = state.apsManager, apsManager.isScheduledBasal != nil {
            if apsManager.isSuspended {
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
