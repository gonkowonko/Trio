import ActivityKit
import SwiftUI
import WidgetKit

/// Loop health as a ringed dot, trailing the device capsules.
///
/// Sixth attempt at this, and the first that is always present. The five before
/// it — a border, a bar along the foot, a bar down the leading edge, a tinted
/// divider, a full-banner wash — all carried the signal on the banner's
/// *chrome*, so the healthy state was a permanent mark across the whole
/// display. Making it an object solves that by scale: a dot is small enough that
/// green costs almost nothing.
///
/// It also restores something a hidden-until-broken version gave up. A green dot
/// says the loop is *known* to be running, where an empty banner cannot be told
/// apart from one whose status never arrived.
///
/// A ringed circle rather than a capsule, deliberately. The pills beside it
/// describe hardware; this describes the app's own loop. It borrows their
/// treatment exactly — a 1pt ring at 0.5 opacity around content at 0.9 — so it
/// reads as one of the same family, while the shape keeps it identifiably a
/// different kind of thing.
///
/// Carries *severity* only. Mode — manual temp basal, suspended delivery — is a
/// separate axis with its own home in the basal tile.
///
/// One exception, added 2026-08-25: a running manual temp basal reports `.inactive`
/// rather than ageing through late to overdue. The loop is still *attempted* every
/// cycle during a manual basal and fails with `manualBasalTemp`, so `lastLoopDate`
/// stops advancing and the dot used to reach red with nothing actually wrong. Red is
/// reserved for "act on this".
struct LiveActivityCustomLoopDotView: View {
    let state: LiveActivityCustomPalette.LoopState

    /// Matched to the device capsules' height, so the row reads as three
    /// elements of one size rather than two and a smaller afterthought. This is
    /// also the status row's own height, so the dot fills it exactly.
    private static let diameter: CGFloat = LiveActivityCustomDevicePill.height

    /// The filled core inside the ring. Sized to leave a clear gap on all sides
    /// — close the gap and the two merge into a solid disc, which is the look
    /// this replaced.
    private static let coreDiameter: CGFloat = 9

    /// Ring weight and opacities lifted from `LiveActivityCustomDevicePill`, so
    /// a healthy loop sits at the same visual volume as a healthy device.
    private static let ringWidth: CGFloat = 1
    private static let ringOpacity: Double = 0.5
    private static let coreOpacity: Double = 0.9

    private var accessibilityText: Text {
        switch state {
        case .ok:
            return Text("Looping", comment: "Loop is running normally, Custom Live Activity")
        case .late:
            return Text("Loop running late", comment: "Loop is behind schedule, Custom Live Activity")
        case .overdue:
            return Text("Loop overdue", comment: "Loop has not run in a long time, Custom Live Activity")
        case .manualTemp:
            // Existing key — avoids adding one to Localizable.xcstrings.
            return Text("Manual Temp Basal", comment: "A manual temp basal is running, Custom Live Activity")
        case .inactive:
            return Text("Loop not running", comment: "Open loop or no loop data, Custom Live Activity")
        }
    }

    var body: some View {
        Circle()
            .strokeBorder(state.color.opacity(Self.ringOpacity), lineWidth: Self.ringWidth)
            .frame(width: Self.diameter, height: Self.diameter)
            .overlay {
                Circle()
                    .fill(state.color.opacity(Self.coreOpacity))
                    .frame(width: Self.coreDiameter, height: Self.coreDiameter)
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }
}
