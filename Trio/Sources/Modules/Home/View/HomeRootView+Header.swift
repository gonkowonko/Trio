import SwiftUI
import UIKit

// MARK: - Zone B: header (pump panel / glucose bobble / loop status)

extension Home.RootView {
    var cgmSelectionButtons: some View {
        ForEach(cgmOptions, id: \.name) { option in
            if let cgm = state.listOfCGM.first(where: option.predicate) {
                Button(option.name) {
                    state.addCGM(cgm: cgm)
                }
            }
        }
    }

    var glucoseView: some View {
        CurrentGlucoseView(
            timerDate: state.timerDate,
            units: state.units,
            alarm: state.alarm,
            lowGlucose: state.lowGlucose,
            highGlucose: state.highGlucose,
            cgmAvailable: state.cgmAvailable,
            currentGlucoseTarget: state.currentGlucoseTarget,
            glucoseColorScheme: state.glucoseColorScheme,
            glucose: state.latestTwoGlucoseValues
        )
        .onTapGesture {
            if !state.cgmAvailable {
                showCGMSelection.toggle()
            } else {
                state.shouldDisplayCGMSetupSheet.toggle()
            }
        }
        .onLongPressGesture {
            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
            impactHeavy.impactOccurred()
            showSnoozeSheet = true
        }
    }

    var pumpView: some View {
        PumpView(
            reservoir: state.reservoir,
            name: state.pumpName,
            expiresAtDate: state.pumpExpiresAtDate,
            activatedAtDate: state.pumpActivatedAtDate,
            timerDate: state.timerDate,
            pumpStatusHighlightMessage: state.pumpStatusHighlightMessage,
            battery: state.batteryFromPersistence
        )
        .onTapGesture {
            if state.pumpDisplayState == nil {
                // shows user confirmation dialog with pump model choices, then proceeds to setup
                showPumpSelection.toggle()
            } else {
                // sends user to pump settings
                state.shouldDisplayPumpSetupSheet.toggle()
            }
        }
    }

    // NOTE: rightHeaderPanel() (loop status + evBG) is superseded by the pill-based
    // rightHeaderPanel(_:) in HomeRootView+HeaderPills.swift.
}
