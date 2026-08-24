import SwiftUI

// MARK: - Device pickers

/// Presents the "Add CGM" / "Add Pump" pickers for the home screen.
///
/// Both selections are applied in `onDismiss` rather than inline: the home view already stacks several sheets,
/// and presenting the device setup sheet while the picker is still dismissing gets dropped by SwiftUI.
private struct DevicePickersModifier: ViewModifier {
    @Binding var showPumpSelection: Bool
    @Binding var showCGMSelection: Bool
    @Binding var pendingPump: PumpCatalogEntry?
    @Binding var pendingCGM: CGMCatalogEntry?
    let state: Home.StateModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showPumpSelection, onDismiss: {
                if let entry = pendingPump {
                    pendingPump = nil
                    state.addPump(entry)
                }
            }) {
                DevicePickerView(
                    title: String(localized: "Add Pump", comment: "The title of the pump chooser in settings"),
                    entries: DeviceCatalog.pumps
                ) { entry in
                    pendingPump = entry
                    showPumpSelection = false
                }
            }
            .sheet(isPresented: $showCGMSelection, onDismiss: {
                if let entry = pendingCGM {
                    pendingCGM = nil
                    state.addCGM(cgm: CGMModel(entry))
                }
            }) {
                DevicePickerView(
                    title: String(localized: "Add CGM", comment: "The title of the CGM chooser in settings"),
                    entries: DeviceCatalog.cgms
                ) { entry in
                    pendingCGM = entry
                    showCGMSelection = false
                }
            }
    }
}

extension View {
    func devicePickers(
        showPumpSelection: Binding<Bool>,
        showCGMSelection: Binding<Bool>,
        pendingPump: Binding<PumpCatalogEntry?>,
        pendingCGM: Binding<CGMCatalogEntry?>,
        state: Home.StateModel
    ) -> some View {
        modifier(DevicePickersModifier(
            showPumpSelection: showPumpSelection,
            showCGMSelection: showCGMSelection,
            pendingPump: pendingPump,
            pendingCGM: pendingCGM,
            state: state
        ))
    }
}

// MARK: - Zone B: header (pump panel / glucose bobble / loop status)

extension Home.RootView {
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
