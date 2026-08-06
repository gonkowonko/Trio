import CoreData
import SwiftDate
import SwiftUI
import UIKit

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
}

struct LoopView: View {
    @Environment(\.colorScheme) var colorScheme

    private enum Config {
        static let lag: TimeInterval = 30
    }

    let closedLoop: Bool
    let timerDate: Date
    let isLooping: Bool
    let lastLoopDate: Date
    let manualTempBasal: Bool

    let determination: [OrefDetermination]

    private let rect = CGRect(x: 0, y: 0, width: 18, height: 18)

    /// Tinted capsule, same dimensions as the read-only pills around the
    /// bobble: the filled background is what marks this one as a control,
    /// and its color carries loop freshness.
    var body: some View {
        loopStatusWithMinutes
            .padding(.vertical, HeaderPill.verticalPadding)
            .padding(.horizontal, HeaderPill.horizontalPadding)
            // tinted glass marks this pill as the column's control; the tint
            // still carries loop freshness (green / yellow / red)
            .glassCapsule(tint: color, tintOpacity: 0.18, strokeOpacity: 0.5, strokeWidth: 1.5)
    }

    private var loopStatusWithMinutes: some View {
        HStack(alignment: .center, spacing: 5) {
            ZStack {
                Image(systemName: (!closedLoop || manualTempBasal) ? "circle.and.line.horizontal" : "circle")
                    .frame(width: HeaderPill.iconWidth, alignment: .center)
                if isLooping {
                    ProgressView()
                }
            }
            // All four header pills center their value in the template slot.
            ZStack(alignment: .center) {
                // Invisible width template — see `HeaderPill`.
                Text(HeaderPill.widthTemplate).hidden()
                if isLooping {
                    Text("looping")
                } else if manualTempBasal {
                    Text("Manual")
                } else if determination.first?
                    .deliverAt !=
                    nil
                {
                    // previously the .timestamp property was used here because this only gets updated when the reportenacted function in the aps manager gets called
                    Text(timeString)
                } else {
                    Text("--")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .font(.callout).fontWeight(.bold).fontDesign(.rounded)
        .foregroundColor(color)
    }

    private var timeString: String {
        let minutesAgo = TimeAgoFormatter.minutesAgoValue(from: lastLoopDate)
        if minutesAgo > 1440 {
            return "--"
        } else {
            return TimeAgoFormatter.minutesAgo(from: lastLoopDate)
        }
    }

    private var color: Color {
        guard determination.first?.timestamp != nil
        else {
            // previously the .timestamp property was used here because this only gets updated when the reportenacted function in the aps manager gets called
            return .secondary
        }
        guard manualTempBasal == false else {
            return .loopManualTemp
        }
        guard closedLoop == true else {
            return .secondary
        }

        let delta = timerDate.timeIntervalSince(lastLoopDate) - Config.lag

        if delta <= 5.minutes.timeInterval {
            guard determination.first?.timestamp != nil else {
                return .loopYellow
            }
            return .loopGreen
        } else if delta <= 10.minutes.timeInterval {
            return .loopYellow
        } else {
            return .loopRed
        }
    }
}

extension View {
    func animateForever(
        using animation: Animation = Animation.easeInOut(duration: 1),
        autoreverses: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        let repeated = animation.repeatForever(autoreverses: autoreverses)

        return onAppear {
            withAnimation(repeated) {
                action()
            }
        }
    }
}
