import SwiftUI

// GARMIN-REMOTE: settings for the TrioIQ Remote Edge widget. See GarminRemote.swift.

/// Section for the Garmin app settings form. Both features are off until turned on here.
struct WatchConfigGarminRemoteSection: View {
    /// The pump's max bolus; the Garmin max can't go above it
    let pumpMaxBolus: Decimal

    /// Which value's wheel is open; one at a time, like the treatment screens
    private enum Field {
        case maxCarbs
        case buttonA
        case buttonB
        case maxBolus
    }

    @State private var settings = GarminRemote.settings
    @State private var openField: Field?
    @State private var shouldDisplayHint = false
    @State private var hintDetent = PresentationDetent.large

    var body: some View {
        Section(
            header: Text("TrioIQ Remote"),
            content: {
                Toggle(String(localized: "Allow Carbs from Garmin"), isOn: $settings.isCarbsEnabled)

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
                        title: String(localized: "Button 1"),
                        value: $settings.carbPresetA,
                        options: Array(stride(from: 5, through: settings.maxCarbs, by: 5)),
                        text: { "\($0)" },
                        unit: String(localized: "g", comment: "Abbreviation for grams")
                    )
                    wheelRow(
                        .buttonB,
                        title: String(localized: "Button 2"),
                        value: $settings.carbPresetB,
                        options: Array(stride(from: 5, through: settings.maxCarbs, by: 5)),
                        text: { "\($0)" },
                        unit: String(localized: "g", comment: "Abbreviation for grams")
                    )
                }

                Toggle(String(localized: "Allow Bolus from Garmin"), isOn: $settings.isBolusEnabled)

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

                HStack(alignment: .center) {
                    Text("Log carbs or bolus from the TrioIQ Remote widget on a Garmin Edge.")
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
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: String(localized: "TrioIQ Remote"),
                hintText: Text(
                    "TrioIQ Remote is a Connect IQ widget for Garmin Edge bike computers. It can log carbs and request a bolus through Trio.\n\n" +
                        "Both are off until you turn them on here. Each request has to be confirmed on the Edge, and Trio checks it again before acting:\n\n" +
                        "• Carbs: up to the max per entry, sent within the last 15 minutes. Button 1 and Button 2 set the widget's two carb buttons.\n" +
                        "• Bolus: up to the max per request (never above the pump's max bolus), sent within the last 2 minutes, no bolus in progress, and at least 3 minutes since the last manual bolus from anywhere (app, Apple Watch or Garmin).\n\n" +
                        "A request is acted on at most once, even if the Edge sends it again."
                ),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
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
