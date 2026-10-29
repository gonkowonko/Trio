import Foundation
import SwiftUI

// MARK: - Alarms control (compact button pinned to the header's top-trailing corner)

extension Home.RootView {
    // Upstream's `updateChartReadout`, kept verbatim and where upstream has it, so its future
    // edits still merge here. Its `mealPanel` / `liveMealPanel` are not: this layout has no
    // IOB / COB row, and the readout shows in the device-lanes slot instead
    // (`deviceLanesOrChartReadout` in HomeRootView+HeaderPills.swift).
    /// Decays the readout instead of dropping it: readings and determinations have holes, and
    /// not the same ones, so each half remembers the last selection that resolved it and the
    /// slot only lets go once nothing has resolved for `ChartSelectionLookup.decay`. Run as
    /// `.task(id: chartSelection)`, so the next scrub step cancels a pending decay and
    /// crossing a hole never reaches the timeout.
    ///
    /// Only `isChartReadoutVisible` is cleared when it does let go; the dates it renders from
    /// stay, so the row keeps its values while fading out.
    ///
    /// `@MainActor` because the continuation after the decay sleep would otherwise resume off
    /// the main actor, writing view state from the wrong one.
    @MainActor func updateChartReadout() async {
        if let selection = chartSelection {
            var resolvedAnything = false

            if ChartSelectionLookup.glucose(at: selection, in: state.glucoseFromPersistence) != nil {
                chartReadoutDate = selection
                resolvedAnything = true
            }

            if ChartSelectionLookup.determination(
                at: selection,
                in: state.enactedAndNonEnactedDeterminations
            ) != nil {
                chartReadoutDeterminationDate = selection
                resolvedAnything = true
            } else if let held = chartReadoutDeterminationDate,
                      abs(held.timeIntervalSince(selection)) > ChartSelectionLookup.determinationHold
            {
                // a hop to a different part of the chart, not a hole: don't carry the values over
                chartReadoutDeterminationDate = nil
            }

            if resolvedAnything {
                isChartReadoutVisible = true
                return
            }
        }

        guard isChartReadoutVisible else { return }
        try? await Task.sleep(for: .seconds(ChartSelectionLookup.decay))
        guard !Task.isCancelled else { return }
        isChartReadoutVisible = false
    }

    func refreshAlarmsSnooze() {
        alarmsSnoozeUntil = UserDefaults.standard
            .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast
    }

    /// Global snooze control. Following the convention for a mute/snooze
    /// affordance, it lives in the top-trailing corner as an icon-sized target
    /// rather than in the readout pill column: a bell while armed, expanding to
    /// bell.slash + countdown while alarms are snoozed.
    @ViewBuilder var alarmsButton: some View {
        // timerDate keeps the countdown ticking
        // measure from now, so calculation is not based off stale tick date
        // cf. https://github.com/nightscout/Trio/issues/1381
        let isSnoozed = alarmsSnoozeUntil > state.timerDate
        let remainingMinutes = max(Int(ceil(alarmsSnoozeUntil.timeIntervalSince(max(state.timerDate, Date())) / 60)), 0)

        Button {
            showSnoozeSheet = true
        } label: {
            if isSnoozed {
                HStack(spacing: 4) {
                    Image(systemName: "bell.slash.fill")
                    Text("\(remainingMinutes) m")
                        .font(.footnote).fontWeight(.bold).fontDesign(.rounded)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .glassCapsule(strokeOpacity: 0.22)
            } else {
                Image(systemName: "bell.fill")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .glassCircle(strokeOpacity: 0.18)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Alarms"))
        .accessibilityValue(Text(
            isSnoozed
                ? String(
                    format: String(localized: "snoozed, %d minutes remaining", comment: "Accessibility: alarm snooze"),
                    remainingMinutes
                )
                : String(localized: "active", comment: "Accessibility: alarms active")
        ))
        .accessibilityHint(Text(String(localized: "Opens snooze options", comment: "Accessibility hint")))
        .accessibilityAddTraits(.isButton)
    }
}
