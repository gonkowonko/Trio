import SwiftUI

/// PULL-LIFT: during the pull-down the adjustment panel "lifts" — a soft shadow
/// fades in along its edge, so the dashboard reads as sliding *under* the panel
/// rather than just fading out above it. Pairs with PULL-FADE, whose fade ends on
/// this panel's top border.
///
/// Drawn behind the adjustment panel slot as a panel-shaped fill in the page
/// background colour carrying the shadow (a clear fill casts no shadow). The
/// fill is the same colour as the page, so the panel looks unchanged; it fades
/// in with the pull, so at rest nothing is drawn at all.
struct HomePullLift<Background: ShapeStyle>: View {
    let push: CGFloat
    let background: Background

    /// pull distance over which the lift reaches full strength
    static var rampDistance: CGFloat { 30 }
    /// shadow strength at full lift
    static var shadowOpacity: Double { 0.28 }

    var body: some View {
        let strength = min(max(push, 0) / Self.rampDistance, 1)
        GlassChrome.panelShape
            .fill(background)
            .shadow(color: .black.opacity(Self.shadowOpacity * strength), radius: 10, y: -3)
            .opacity(strength)
            .frame(height: HomeLayout.bottomPanelHeight)
            // match the adjustment panel's slot inside `bottomControls()`
            .padding(.top, HomeLayout.bottomZonePadding)
            .padding(.horizontal, 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
