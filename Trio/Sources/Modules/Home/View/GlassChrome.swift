import SwiftUI

/// Shared chrome for the Home panels: real Liquid Glass on iOS 26,
/// material approximation below.
enum GlassChrome {
    /// system-glass panel rounding (not the design patch's 17pt)
    static let panelCornerRadius: CGFloat = 26

    static var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
    }

    /// Stand-in for glass/material when Reduce Transparency is on: no blur, so
    /// nothing behind the panel bleeds through.
    static let opaqueFill = Color(.secondarySystemGroupedBackground)

    /// Glass variant for the large Home panels — device lanes, the adjustment
    /// and stats banners, the chart readout.
    ///
    /// iOS 27 renders `.regular` markedly more frosted than iOS 26 did. The
    /// material is system-drawn, so nothing on our side changed.
    ///
    /// Tried in order on device, 2026-09-18:
    /// - `.regular` — the frosted panel iOS 27 gives by default.
    /// - `.clear` — drops the dimming pass, so the rim reads glassier, but the
    ///   interior wash stays: over a flat dark background the material's own
    ///   scattering has nothing to refract and resolves to a pale haze. Confirmed
    ///   not to be the tint — the untinted stats banner washed out identically.
    /// - `.identity` — no material at all. The only chrome left is the
    ///   `strokeBorder` overlay below (`Color.primary` at `strokeOpacity * 0.6`,
    ///   1pt — white ~18% on dark).
    ///
    /// Deliberately *not* applied to `GlassCapsuleBackground` or
    /// `GlassCircleBackground`: the header pills and the alarms button are small
    /// enough that `.regular` still reads well, and they were not part of the
    /// complaint.
    ///
    /// Revert by changing this one property back to `.regular`.
    @available(iOS 26.0, *) static var panelGlass: Glass { .identity }

    /// Compensation for `panelGlass == .identity`. Every call site's
    /// `tintOpacity` / `strokeOpacity` was tuned against a glass body that added
    /// its own luminance; with no material they read far weaker than intended.
    ///
    /// Set both back to `1` / `0` if a real material is ever restored — they
    /// exist only because the panels are now unlit.
    ///
    /// A flat tint fill on the dark background is dimmer than the same tint
    /// applied to glass was.
    static let panelTintBoost: Double = 1.5

    /// With no body the rim is the *only* chrome, so it cannot be a hairline.
    /// The adjustment panel's empty state passes `strokeOpacity: 0.08`, which
    /// the 0.6 rim factor turned into 0.048 — invisible. A deliberate `0` is
    /// still honoured (the concurrent adjustment panel draws its own halves).
    static let panelMinRimOpacity: Double = 0.15
}

/// Glass panel background with optional tint; pre-26 falls back to
/// ultraThinMaterial + tint fill + stroke, matching the compat-mode look.
///
/// Accessibility: with Reduce Transparency or Increase Contrast enabled, both the
/// glass and material paths are dropped for an opaque, higher-contrast fill so
/// low-vision users get legible chrome instead of translucent panels.
struct GlassPanelBackground: ViewModifier {
    var tint: Color?
    var tintOpacity: Double = 0.12
    var strokeOpacity: Double = 0.35
    var strokeWidth: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// True when the user has asked for reduced transparency or increased contrast.
    private var prefersOpaque: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }

    /// Rim opacity for the no-material panel: the call site's value through the
    /// 0.6 accent factor, but never so faint it disappears. `0` stays `0` so a
    /// call site can still opt out of the rim entirely.
    private var rimOpacity: Double {
        strokeOpacity == 0 ? 0 : max(strokeOpacity * 0.6, GlassChrome.panelMinRimOpacity)
    }

    func body(content: Content) -> some View {
        // Reduce Transparency / Increase Contrast skip the glass and material paths entirely
        // for a fully opaque panel; the glass path in particular cannot be made opaque.
        if prefersOpaque {
            content.background(opaquePanel)
        } else if #available(iOS 26.0, *) {
            content
                // The tint is drawn here rather than handed to `Glass.tint(_:)`:
                // `.identity` has no material to carry it, so a tinted panel
                // (an active adjustment, a bolus in progress, a device lane
                // wanting attention) would otherwise lose its colour entirely
                // and keep only the rim. Layering is glass → tint → content, so
                // this stays correct if `panelGlass` goes back to `.regular` or
                // `.clear` — the tint then sits above the material instead of
                // inside it, which reads near-identically.
                .background(GlassChrome.panelShape.fill(
                    (tint ?? .clear).opacity(tintOpacity * GlassChrome.panelTintBoost)
                ))
                .glassEffect(
                    GlassChrome.panelGlass,
                    in: .rect(cornerRadius: GlassChrome.panelCornerRadius, style: .continuous)
                )
                // with no material behind it the rim carries the panel, so it is
                // floored rather than left as the hairline accent it once was
                .overlay(GlassChrome.panelShape.strokeBorder(
                    (tint ?? Color.primary).opacity(rimOpacity),
                    lineWidth: strokeWidth
                ))
        } else {
            content
                .background(
                    GlassChrome.panelShape
                        .fill(.ultraThinMaterial)
                        .overlay(GlassChrome.panelShape.fill((tint ?? .clear).opacity(tintOpacity)))
                        .overlay(GlassChrome.panelShape.strokeBorder(
                            (tint ?? Color.primary).opacity(strokeOpacity),
                            lineWidth: strokeWidth
                        ))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.10), radius: 3, y: 1)
                )
        }
    }

    /// Opaque, higher-contrast panel used when transparency is reduced / contrast increased.
    private var opaquePanel: some View {
        GlassChrome.panelShape
            .fill(Color(.secondarySystemBackground))
            .overlay(GlassChrome.panelShape.fill((tint ?? .clear).opacity(min(tintOpacity * 1.5, 0.30))))
            .overlay(GlassChrome.panelShape.strokeBorder(
                (tint ?? Color.primary).opacity(max(strokeOpacity, 0.6)),
                lineWidth: strokeWidth + 0.5
            ))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.10), radius: 3, y: 1)
    }
}

/// Material fill for small glass affordances (rate capsule, chart-info circle) that
/// becomes an opaque fill under Reduce Transparency / Increase Contrast.
struct GlassMaterialFill<S: InsettableShape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        if reduceTransparency || colorSchemeContrast == .increased {
            content.background(shape.fill(Color(.secondarySystemBackground)))
        } else {
            content.background(shape.fill(.ultraThinMaterial))
        }
    }
}

extension View {
    func glassPanel(
        tint: Color? = nil,
        tintOpacity: Double = 0.12,
        strokeOpacity: Double = 0.35,
        strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(GlassPanelBackground(
            tint: tint,
            tintOpacity: tintOpacity,
            strokeOpacity: strokeOpacity,
            strokeWidth: strokeWidth
        ))
    }

    /// Material fill for a small shape (capsule/circle) that turns opaque under
    /// Reduce Transparency / Increase Contrast.
    func glassMaterialFill(_ shape: some InsettableShape) -> some View {
        modifier(GlassMaterialFill(shape: shape))
    }
}

/// Capsule glass, for the header pills. Same behaviour as `GlassPanelBackground`
/// in a capsule shape: clear glass reads as a read-only pill, a tint marks it
/// as a control (e.g. the loop pill).
struct GlassCapsuleBackground: ViewModifier {
    var tint: Color?
    var tintOpacity: Double = 0.12
    var strokeOpacity: Double = 0.35
    var strokeWidth: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    tint.map { Glass.regular.tint($0.opacity(tintOpacity)) } ?? .regular,
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(
                    (tint ?? Color.primary).opacity(strokeOpacity * 0.6),
                    lineWidth: strokeWidth
                ))
        } else {
            content
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill((tint ?? .clear).opacity(tintOpacity)))
                        .overlay(Capsule().strokeBorder(
                            (tint ?? Color.primary).opacity(strokeOpacity),
                            lineWidth: strokeWidth
                        ))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 2, y: 1)
                )
        }
    }
}

/// Circle glass, for icon-sized controls such as the alarms button.
struct GlassCircleBackground: ViewModifier {
    var tint: Color?
    var tintOpacity: Double = 0.12
    var strokeOpacity: Double = 0.35
    var strokeWidth: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    tint.map { Glass.regular.tint($0.opacity(tintOpacity)) } ?? .regular,
                    in: Circle()
                )
                .overlay(Circle().strokeBorder(
                    (tint ?? Color.primary).opacity(strokeOpacity * 0.6),
                    lineWidth: strokeWidth
                ))
        } else {
            content
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill((tint ?? .clear).opacity(tintOpacity)))
                        .overlay(Circle().strokeBorder(
                            (tint ?? Color.primary).opacity(strokeOpacity),
                            lineWidth: strokeWidth
                        ))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 2, y: 1)
                )
        }
    }
}

extension View {
    func glassCapsule(
        tint: Color? = nil,
        tintOpacity: Double = 0.12,
        strokeOpacity: Double = 0.35,
        strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(GlassCapsuleBackground(
            tint: tint,
            tintOpacity: tintOpacity,
            strokeOpacity: strokeOpacity,
            strokeWidth: strokeWidth
        ))
    }

    func glassCircle(
        tint: Color? = nil,
        tintOpacity: Double = 0.12,
        strokeOpacity: Double = 0.35,
        strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(GlassCircleBackground(
            tint: tint,
            tintOpacity: tintOpacity,
            strokeOpacity: strokeOpacity,
            strokeWidth: strokeWidth
        ))
    }
}
