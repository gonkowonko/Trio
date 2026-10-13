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

    /// LA-TINT: what the banner is tinted to show, or `nil` for the normal look.
    ///
    /// LA-TINT-MANUAL (2026-10-13) added `.manual` and removed the loop dot, so the
    /// tint is now the only loop indicator: none = looping, amber, red, and a
    /// blue-grey for open loop or a manual temp basal — states where the loop is
    /// *meant* not to be running, which must never read as a fault.
    enum Tint {
        case late
        case overdue
        case manual
    }

    /// LA-TINT: the tint behind the banner.
    ///
    /// A seventh go at loop health on the chrome, chosen from a mockup on
    /// 2026-10-11. The full-banner wash failed because it was translucent and
    /// drawn *over* the content. This is the system background tint instead,
    /// behind the scrim and the chart rather than over them. It is *not*
    /// opaque, despite the opaque colours below: on device (iOS 27) the system
    /// still blends the wallpaper through it.
    static func backgroundTint(for tint: Tint?) -> Color {
        switch tint {
        case .late: return Color(red: 0.62, green: 0.38, blue: 0.02)
        case .overdue: return Color(red: 0.66, green: 0.09, blue: 0.09)
        // LA-TINT-MANUAL: slate blue-grey. Kept cool and low-saturation so it
        // reads as "a mode", not a warning, and stays apart from amber over a
        // warm wallpaper. Tune on device.
        case .manual: return Color(red: 0.24, green: 0.36, blue: 0.52)
        case nil: return backgroundTint
        }
    }

    /// LA-TINT: the scrim is thinned while the banner is tinted. At the full 0.5
    /// it sits over the tint and turns amber to brown (seen on device 2026-10-11).
    /// 0.35 was tried while the chart's axis labels were still `.secondary`, which
    /// 0.25 lost; they now go fixed white while tinted, so 0.25 holds. A healthy
    /// banner keeps `backgroundOpacity` unchanged.
    static let tintedBackgroundOpacity: Double = 0.25

    static func backgroundOpacity(for tint: Tint?) -> Double {
        tint == nil ? backgroundOpacity : tintedBackgroundOpacity
    }

    var tint: Tint?

    // Loop health was carried here for a while — first as a border, then a bar
    // along the foot, then a bar down the leading edge, then a wash over this
    // backdrop. All four put the signal on the banner's chrome, which meant the
    // healthy state was a permanent mark across the whole display. The dot
    // (`LiveActivityCustomLoopDotView`) took over, and LA-TINT brought it back
    // here as the system tint, clear while healthy.

    func body(content: Content) -> some View {
        content
            .padding(.all, 14)
            .frame(minHeight: 0, maxHeight: .infinity)
            .privacySensitive()
            .foregroundStyle(Color.primary)
            .background(Color.black.opacity(Self.backgroundOpacity(for: tint)))
            .activityBackgroundTint(Self.backgroundTint(for: tint))
    }
}

extension View {
    func addCustomLiveActivityModifiers(tint: LiveActivityCustomModifiers.Tint? = nil) -> some View {
        modifier(LiveActivityCustomModifiers(tint: tint))
    }
}
