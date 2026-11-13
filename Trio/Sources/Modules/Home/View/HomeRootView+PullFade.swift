import SwiftUI

/// PULL-FADE: as the pull-down drags the dashboard into the bottom panels, the
/// content fades out over a short band above them and is hidden beneath them, so
/// the chart never shows through the (material-less) panels. The band ramps in
/// with the pull, so at rest the bottom of the dashboard is untouched.
///
/// Applied to the scroll *content*, not the scroll view: SwiftUI hosts the
/// `.safeAreaInset` panels inside the scroll view's layer, so a mask there clips
/// the panels themselves (seen on the simulator, 13 Nov).
///
/// The dashboard is viewport-sized, so at rest its bottom edge sits exactly on
/// the panels' top edge. Pulled down by `push`, that panel edge is `push` above
/// the content's bottom. `push` is the live pull plus the indicator padding held
/// while a forced loop runs (that padding is inside the masked content).
struct HomePullFadeMask: ViewModifier {
    let push: CGFloat

    /// height of the fade band above the panels
    static let fadeHeight: CGFloat = 70
    /// how far past the content's rest edge the fade ends: across the 10pt gap
    /// to the adjustment panel's top border. Not into the panel — the panels have
    /// no material, so anything still visible there shows through them (16pt in
    /// was tried and read as text coming through the panel).
    static let edgeDrop: CGFloat = HomeLayout.bottomZonePadding
    /// how fast the band reaches full height relative to the pull
    static let bandGrowth: CGFloat = 3
    /// unmasked room above the content for chrome that overhangs it (alarm bell)
    static let overflow: CGFloat = 200

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geo in
                let pushed = max(push, 0)
                let edge = max(geo.size.height - pushed + Self.edgeDrop, 0)
                // the band grows with the pull (zero at rest, so nothing is faded),
                // and always runs fully to transparent at the panel edge — a band
                // that stopped part-way read as a hard cut
                // grows 3x the pull so it is soft from the first few points of travel
                let band = min(pushed * Self.bandGrowth, Self.fadeHeight, edge)
                VStack(spacing: 0) {
                    // extends `overflow` above the content: a mask clips everything
                    // outside it, and the alarm bell overhangs the dashboard's top edge
                    Color.black.frame(height: Self.overflow + max(edge - band, 0))
                    // eased: most of the fade happens close to the panels
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.85), location: 0.3),
                            .init(color: .black.opacity(0.55), location: 0.6),
                            .init(color: .black.opacity(0.2), location: 0.85),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: band)
                    Spacer(minLength: 0)
                }
                .offset(y: -Self.overflow)
            }
        }
    }
}
