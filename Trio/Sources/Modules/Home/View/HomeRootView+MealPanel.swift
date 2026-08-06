import Foundation
import SwiftUI

// MARK: - Alarms control (compact button pinned to the header's top-trailing corner)

extension Home.RootView {
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
        let isSnoozed = alarmsSnoozeUntil > state.timerDate
        let remainingMinutes = max(Int(ceil(alarmsSnoozeUntil.timeIntervalSince(state.timerDate) / 60)), 0)

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
    }
}
