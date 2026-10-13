import SwiftUI
import WidgetKit

/// The Custom layout's banner chrome: padding, background and tint.
///
/// A deliberate copy of `LiveActivityModifiers` rather than a call to it. The
/// only difference is `backgroundOpacity` — but that value is shared by Simple
/// and Detailed, and thinning it for this layout must not thin it for theirs.
/// Copying keeps the whole Custom stream removable with its folder.
///
/// **Legibility note.** This backdrop is what the secondary-grey text is read
/// against — the tile captions, the chart's axis labels, the loop age. Over a
/// dark wallpaper they hold up at almost any opacity; over a bright one they are
/// the first thing to fail. If this value drops much further, those elements
/// need a fixed white opacity instead of `.secondary`, which adapts to the
/// interface style rather than to what is actually behind the banner.
struct LiveActivityCustomModifiers: ViewModifier {
    /// Strength of the black scrim behind the banner. Below 1 it stays
    /// translucent; higher is darker and hides more wallpaper.
    ///
    /// Black rather than the shared modifier's `BackgroundStyle.background`.
    /// That one is a *semantic* colour: it follows the interface style, not
    /// what is behind the banner, so over a bright photo it goes milky and
    /// washes out the `.secondary` text. Black can only ever darken, which
    /// pulls that text's contrast up instead of eating it.
    static let backgroundOpacity: Double = 0.5

    /// Second, weaker lever: the tint iOS composites behind the activity.
    ///
    /// Left `.clear` — the same value the shared modifier uses — so the scrim
    /// above is the only thing controlling the look. Black here did measurably
    /// darken the banner in the simulator, but only slightly, and stacking two
    /// darkening layers makes the result hard to reason about. Reach for this
    /// only if `backgroundOpacity` alone cannot go dark enough.
    static let backgroundTint: Color = .clear

    // Loop health was carried here for a while — first as a border, then a bar
    // along the foot, then a bar down the leading edge, then a wash over this
    // backdrop. All four put the signal on the banner's chrome, which meant the
    // healthy state was a permanent mark across the whole display. See
    // `LiveActivityCustomLoopDotView`, which owns it now. This modifier is back
    // to being chrome and nothing else.

    func body(content: Content) -> some View {
        content
            .padding(.all, 14)
            .frame(minHeight: 0, maxHeight: .infinity)
            .privacySensitive()
            .foregroundStyle(Color.primary)
            .background(Color.black.opacity(Self.backgroundOpacity))
            .activityBackgroundTint(Self.backgroundTint)
    }
}

extension View {
    func addCustomLiveActivityModifiers() -> some View {
        modifier(LiveActivityCustomModifiers())
    }
}
