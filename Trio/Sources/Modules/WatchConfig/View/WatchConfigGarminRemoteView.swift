import CoreData
import SwiftUI

// GARMIN-REMOTE: settings for the TrioIQ Remote Edge widget. See GarminRemote.swift.

/// Section for the Garmin app settings form. Every feature is off until turned on here.
struct WatchConfigGarminRemoteSection: View {
    /// The pump's max bolus; the Garmin max can't go above it
    let pumpMaxBolus: Decimal
    /// For describing override presets as the Adjustments screen does
    let units: GlucoseUnits
    let defaultSmbMinutes: Decimal
    let defaultUamMinutes: Decimal

    /// Which value's wheel is open; one at a time, like the treatment screens
    private enum Field {
        case maxCarbs
        case buttonA
        case buttonB
        case maxBolus
    }

    @State private var settings = GarminRemote.settings
    @State private var openField: Field?
    /// The help sheet is shown by the page (see WatchConfigGarminRemoteHint): a .sheet on
    /// a Form section is copied onto every row, and the copies close it straight away
    @Binding var shouldDisplayHint: Bool

    var body: some View {
        Section(
            header: Text("TrioIQ Remote Settings"),
            content: {
                Toggle(String(localized: "Allow Carbs"), isOn: $settings.isCarbsEnabled)

                if settings.isCarbsEnabled {
                    // Carbs in 5 g steps, as on the carb entry screen
                    wheelRow(
                        .maxCarbs,
                        title: String(localized: "Max Carbs per Entry"),
                        value: $settings.maxCarbs,
                        options: Array(stride(from: 5, through: 100, by: 5)),
                        text: { "\($0)" },
                        unit: String(localized: "g", comment: "Abbreviation for grams")
                    )

                    // The widget's two carb buttons, sent to it with each status reply
                    wheelRow(
                        .buttonA,
                        title: String(localized: "Quick Carb Amount 1"),
                        value: $settings.carbPresetA,
                        options: Array(stride(from: 5, through: settings.maxCarbs, by: 5)),
                        text: { "\($0)" },
                        unit: String(localized: "g", comment: "Abbreviation for grams")
                    )
                    wheelRow(
                        .buttonB,
                        title: String(localized: "Quick Carb Amount 2"),
                        value: $settings.carbPresetB,
                        options: Array(stride(from: 5, through: settings.maxCarbs, by: 5)),
                        text: { "\($0)" },
                        unit: String(localized: "g", comment: "Abbreviation for grams")
                    )
                }

                Toggle(String(localized: "Allow Bolus"), isOn: $settings.isBolusEnabled)

                if settings.isBolusEnabled {
                    // Insulin in 0.1 U steps, up to the pump's max bolus
                    wheelRow(
                        .maxBolus,
                        title: String(localized: "Max Bolus per Request"),
                        value: maxBolusTenths,
                        options: Array(1 ... max(1, pumpMaxTenths)),
                        text: { String(format: "%.1f", Double($0) / 10) },
                        unit: String(localized: "U", comment: "Insulin unit")
                    )
                }

                Toggle(String(localized: "Allow Overrides"), isOn: $settings.isOverridesEnabled)

                if settings.isOverridesEnabled {
                    NavigationLink {
                        GarminRemoteOverridePicker(
                            selectedIDs: $settings.overridePresetIDs,
                            units: units,
                            defaultSmbMinutes: defaultSmbMinutes,
                            defaultUamMinutes: defaultUamMinutes
                        )
                    } label: {
                        HStack {
                            Text("Available Overrides")
                            Spacer()
                            Text("\(settings.overridePresetIDs.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                HStack(alignment: .center) {
                    Text("Choose what the TrioIQ Remote widget can do from your Garmin device.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(
                        action: { shouldDisplayHint.toggle() },
                        label: {
                            Image(systemName: "questionmark.circle").accessibilityLabel(Text("More information"))
                        }
                    ).buttonStyle(BorderlessButtonStyle())
                }
            }
        )
        .listRowBackground(Color.chart)
        // The pump max may have been lowered since; keep the wheel on a real option
        .onAppear {
            if maxBolusTenths.wrappedValue > max(1, pumpMaxTenths) {
                maxBolusTenths.wrappedValue = max(1, pumpMaxTenths)
            }
        }
        .onChange(of: settings) { _, newValue in
            GarminRemote.settings = newValue
        }
        // Lowering the max pulls the buttons down with it, so neither is ever over the limit
        .onChange(of: settings.maxCarbs) { _, newMax in
            settings.carbPresetA = min(settings.carbPresetA, newMax)
            settings.carbPresetB = min(settings.carbPresetB, newMax)
        }
    }

    /// A value row that opens an inline wheel when tapped, the same as the alarm and
    /// treatment settings
    private func wheelRow(
        _ field: Field,
        title: String,
        value: Binding<Int>,
        options: [Int],
        text: @escaping (Int) -> String,
        unit: String
    ) -> some View {
        let isOpen = openField == field
        return VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(text(value.wrappedValue))
                    .foregroundColor(isOpen ? .accentColor : .primary)
                Text(unit)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { openField = isOpen ? nil : field }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text("\(text(value.wrappedValue)) \(unit)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openField = isOpen ? nil : field }

            if isOpen {
                Picker(title, selection: value) {
                    ForEach(options, id: \.self) { option in
                        Text(text(option)).tag(option)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var pumpMaxTenths: Int {
        Int(NSDecimalNumber(decimal: pumpMaxBolus * 10).doubleValue.rounded(.down))
    }

    /// Max bolus as whole tenths for the wheel; stored as Decimal so 0.1 steps don't drift
    private var maxBolusTenths: Binding<Int> {
        Binding(
            get: { Int(NSDecimalNumber(decimal: settings.maxBolus * 10).doubleValue.rounded()) },
            set: { settings.maxBolus = Decimal($0) / 10 }
        )
    }
}

/// Help for the TrioIQ Remote section, shown from the page's own .sheet like the
/// page's other help
struct WatchConfigGarminRemoteHint: View {
    @Binding var hintDetent: PresentationDetent
    @Binding var shouldDisplayHint: Bool

    var body: some View {
        SettingInputHintView(
            hintDetent: $hintDetent,
            shouldDisplayHint: $shouldDisplayHint,
            hintLabel: String(localized: "TrioIQ Remote"),
            hintText: Text(
                "TrioIQ Remote is a Connect IQ widget for Garmin Edge bike computers. It can log carbs, request a bolus and start or stop an override through Trio.\n\n" +
                    "Each is off until you turn it on here. Each request has to be confirmed on the device, and Trio checks it again before acting:\n\n" +
                    "• Carbs: up to the max per entry, sent within the last 15 minutes. Quick Carb Amount 1 and 2 set the widget's two carb buttons.\n" +
                    "• Bolus: up to the max per request (never above the pump's max bolus), sent within the last 2 minutes, no bolus in progress, and at least 3 minutes since the last manual bolus from anywhere (app, Apple Watch or Garmin).\n" +
                    "• Overrides: only the presets chosen under Available Overrides (up to \(GarminRemote.maxOverrides)), sent within the last 5 minutes. The widget can stop any running override.\n\n" +
                    "A request is acted on at most once, even if the device sends it again."
            ),
            sheetTitle: String(localized: "Help", comment: "Help sheet title")
        )
    }
}

/// Ticks which override presets the widget offers, listed in Trio's preset order
private struct GarminRemoteOverridePicker: View {
    @Binding var selectedIDs: [String]
    let units: GlucoseUnits
    let defaultSmbMinutes: Decimal
    let defaultUamMinutes: Decimal

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "orderPosition", ascending: true)],
        predicate: NSPredicate.allOverridePresets
    ) private var presets: FetchedResults<OverrideStored>

    var body: some View {
        List {
            Section(
                footer: Text(
                    "Choose up to \(GarminRemote.maxOverrides) to show on the device, in Trio's order. Tapping one there starts it straight away; Stop appears at the top while one is running."
                )
            ) {
                if presets.isEmpty {
                    Text("No override presets yet. Add them on the Adjustments screen.")
                        .foregroundColor(.secondary)
                }
                ForEach(presets, id: \.objectID) { preset in
                    row(preset)
                }
            }
        }
        .navigationTitle("Available Overrides")
        // A preset deleted since it was chosen no longer counts toward the limit
        .onAppear {
            let existing = Set(presets.compactMap(\.id))
            selectedIDs.removeAll { !existing.contains($0) }
        }
    }

    private func row(_ preset: OverrideStored) -> some View {
        let id = preset.id ?? ""
        let isSelected = selectedIDs.contains(id)
        let isFull = selectedIDs.count >= GarminRemote.maxOverrides
        return Button {
            if isSelected {
                selectedIDs.removeAll { $0 == id }
            } else if !isFull {
                selectedIDs.append(id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(preset.name ?? "Override")
                        .foregroundColor(.primary)
                    let labels = labels(preset)
                    HStack(spacing: 5) {
                        ForEach(labels, id: \.self) { label in
                            Text(label)
                            if label != labels.last {
                                Divider().frame(width: 1, height: 20)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
        .disabled(id.isEmpty || (!isSelected && isFull))
    }

    /// The same details, in the same order and wording, as each preset on the
    /// Adjustments screen (AdjustmentsRootView+Overrides overridesView): length,
    /// percentage with ISF/CR, target, SMBs off, and SMB / UAM minutes that differ
    /// from the defaults. "Until stopped" stands in when there's nothing else.
    private func labels(_ preset: OverrideStored) -> [String] {
        let durationString: String = {
            guard !preset.indefinite else { return "" }
            let minutes = preset.duration?.doubleValue ?? 0
            guard minutes.isFinite, minutes > 0, minutes <= Double(Int.max) else { return "" }
            return hoursAndMinutes(Int(minutes))
        }()

        let isfAndCrString: String = {
            switch (preset.isfAndCr, preset.isf, preset.cr) {
            case (_, true, true),
                 (true, _, _):
                return " ISF/CR"
            case (false, true, false):
                return " ISF"
            case (false, false, true):
                return " CR"
            default:
                return ""
            }
        }()

        let percentageString: String = {
            let percentage = preset.percentage
            guard percentage != 100, percentage.isFinite, percentage.magnitude <= Double(Int.max) else { return "" }
            return "\(Int(percentage))%\(isfAndCrString)"
        }()

        let targetString: String = {
            guard let target = preset.target, target != 0 else { return "" }
            return "\(target.decimalValue.formatted(for: units)) \(units.rawValue)"
        }()

        let smbString: String = {
            guard preset.smbIsOff || preset.smbIsScheduledOff else { return "" }
            let schedule = preset.smbIsScheduledOff && preset.start != preset.end
                ? " \(formatTimeRange(start: preset.start?.stringValue, end: preset.end?.stringValue))" : ""
            return "SMBs Off\(schedule)"
        }()

        let smbMinutes = preset.smbMinutes?.decimalValue ?? 0
        let maxSmbMinsString = smbMinutes != 0 && preset.advancedSettings && !preset.smbIsOff && smbMinutes != defaultSmbMinutes
            ? "\(smbMinutes.formatted()) min SMB" : ""

        let uamMinutes = preset.uamMinutes?.decimalValue ?? 0
        let maxUamMinsString = uamMinutes != 0 && preset.advancedSettings && !preset.smbIsOff && uamMinutes != defaultUamMinutes
            ? "\(uamMinutes.formatted()) min UAM" : ""

        let labels = [durationString, percentageString, targetString, smbString, maxSmbMinsString, maxUamMinsString]
            .filter { !$0.isEmpty }
        return labels.isEmpty ? [String(localized: "until stopped")] : labels
    }

    /// As AdjustmentsStateModel.formatHoursAndMinutes: "45 m", "2 h", "1 h 30 m"
    private func hoursAndMinutes(_ durationInMinutes: Int) -> String {
        let hours = durationInMinutes / 60
        let minutes = durationInMinutes % 60
        let h = String(localized: "h", comment: "h")
        let m = String(localized: "m", comment: "Abbreviation for Minutes")
        switch (hours, minutes) {
        case let (0, mins):
            return "\(mins)\u{00A0}\(m)"
        case let (hrs, 0):
            return "\(hrs)\u{00A0}\(h)"
        default:
            return "\(hours)\u{00A0}\(h)\u{00A0}\(minutes)\u{00A0}\(m)"
        }
    }
}
