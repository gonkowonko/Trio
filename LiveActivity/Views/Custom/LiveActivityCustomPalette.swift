import SwiftUI

/// Colours for the Custom lock-screen layout.
///
/// Values match the app's asset catalog (`LoopGreen`, `LoopRed`), pinned
/// numerically because only `LoopGreen` exists in the LiveActivity target's
/// asset catalog. Kept private to the Custom stream rather than shared with the
/// device-status pills, so either can be reverted without disturbing the other.
enum LiveActivityCustomPalette {
    static let green = Color(red: 0.435, green: 0.812, blue: 0.592)
    static let red = Color(red: 0.922, green: 0.341, blue: 0.341)

    /// `red` with the pink taken out, for use **on the frosted pill ground only**.
    ///
    /// `red` is `LoopRed`, and it is a *soft* red: green and blue both sit at
    /// 0.341, giving saturation 0.63. Across a device lane's large surface that
    /// still reads red; inside a 19pt capsule on a warm frosted base it reads
    /// salmon, which is what Gary saw ("still pinky", 2026-09-11).
    ///
    /// Saturation is the axis that fixes that, and it is the *opposite* axis to
    /// the one tried before — see the note below, where four goes at making red
    /// brighter produced pink and orange. Brightness and saturation trade against
    /// each other in red, so the choice is which one the design needs. On the bare
    /// dark banner it needed brightness and could not have it. Now that the frost
    /// supplies a light ground, the text can spend luminance to buy saturation:
    ///
    ///     `red`        lum 0.252   sat 0.63   <- reads salmon at this size
    ///     this         lum 0.215   sat 0.81   <- reads red
    ///
    /// Dimmer in isolation, but a saturated red on a *light* ground is the pairing
    /// that works — the same reason the lanes read correctly. Do not use this on
    /// the dark banner or as a fill under white text; it is darker than `red` and
    /// would be worse at both.
    static let redVivid = Color(red: 0.95, green: 0.18, blue: 0.18)

    // MARK: - Why there is no second, brighter red here

    // Measured relative luminance of this palette: amber 0.579, green 0.503,
    // `red` 0.252. Red is half as bright as the green beside it, so a 1pt red
    // ring and its 10.5pt label read markedly fainter than the amber pill in the
    // same slot. Nothing was wrong with `red` while it was only ever a *fill* —
    // a solid capsule carries colour by area, and area forgives luminance. A
    // hairline does not.
    //
    // Four attempts were burned trying to make `red` legible as a thin outline on
    // the banner's dark ground, and every one was rejected on device:
    //
    //     pure red (1, 0, 0)   lum 0.213  sat 1.00   <- red's ceiling
    //     `red` (LoopRed)      lum 0.252  sat 0.63
    //     (1.0, 0.50, 0.47)    lum 0.379  sat 0.53   -> "it's pink"
    //     (1.0, 0.45, 0.28)    lum 0.339  sat 0.72   -> "it's orange"
    //     (1.0, 0.38, 0.36)    lum 0.306  sat 0.64   -> "back where we started"
    //     ...plus a 0.22 tint behind it                -> "washed out"
    //
    // **A fully saturated red is darker than `red` already is.** Luminance weights
    // green 71.5% and red 21.3%, so every step brighter must borrow green: raise
    // green and blue together and it desaturates to pink, raise green alone and
    // the hue walks to orange. Those are the only two directions, which is why
    // green and amber read fine in the same slot and red cannot be made to.
    //
    // **Red is a dark colour — the fix is the ground, not the red.** Gary pointed
    // at the Home screen's device lanes, which use this exact `red` (they are
    // both `LoopRed`) and read perfectly: `DeviceLanesView` puts it on
    // `.ultraThinMaterial`, so the red sits on a *light* frosted base instead of
    // a dark one. `LiveActivityCustomDevicePillsView` now copies that recipe.
    //
    // So: if red ever looks weak again, change what is behind it. Do not add
    // another red.
    /// `ManualTempBasal` from the app's catalog, pinned for the same reason as the
    /// others — the asset does not exist in the LiveActivity target.
    static let manualTemp = Color(red: 0.118, green: 0.588, blue: 0.988)

    /// The bobble's ring. Copied from `CurrentGlucoseView.angularGradient` so
    /// the lock screen and the home screen show the same object.
    static let ringGradient = AngularGradient(
        colors: [
            Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
            Color(red: 0.6235294118, green: 0.4235294118, blue: 0.9803921569),
            Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765),
            Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
            Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902),
            Color(red: 0.7215686275, green: 0.3411764706, blue: 1)
        ],
        center: .center,
        startAngle: .degrees(270),
        endAngle: .degrees(-90)
    )

    /// Interior of the bobble. The home screen fills it with `Color.chart`,
    /// which has no colorset in the LiveActivity target; this is a dark disc
    /// that reads the same way against the lock screen's translucency.
    static let bobbleFill = Color.black.opacity(0.28)

    /// Tile accents. IOB and COB borrow the app's insulin/carb hues.
    /// `LoopYellow`'s value — manual temp basal, and the chart's low line.
    static let yellow = Color(red: 0.886, green: 0.780, blue: 0.400)

    static let insulin = Color(red: 0.416, green: 0.663, blue: 0.961)
    static let carbs = Color(red: 0.910, green: 0.639, blue: 0.239)

    /// Loop-health thresholds, matching `LoopView` on the home screen so both
    /// surfaces escalate at the same moment.
    static let loopFreshWindow: TimeInterval = 5 * 60
    static let loopLateWindow: TimeInterval = 10 * 60

    /// How far behind the loop is, or `nil` when there is nothing to say.
    ///
    /// Returns nothing far more often than it returns a case, which is the whole
    /// point: a healthy loop leaves the banner completely clean.
    ///
    /// This replaced a full-banner wash, which failed for a reason worth
    /// recording — it was the only treatment tried that was not *opaque*. A wash
    /// is a relative change, readable only against the untinted version, so over
    /// a warm wallpaper it read as the wallpaper. It also dragged the chart's
    /// in-range band toward olive and put an amber field behind amber device
    /// pills. No opacity works for both a ginger photo and a dark one.
    ///
    /// Deliberately narrower than the colour it replaced in a second way: that
    /// one also encoded *mode* — purple for a manual temp basal, grey for an
    /// open loop. Both are gone. Mode is not a severity, and sharing the channel
    /// meant a manual temp basal masked how long ago the loop last ran. The
    /// basal tile already carries manual and suspended delivery; an open loop is
    /// a setting rather than a fault.
    ///
    /// A missing `lastLoopDate` also returns nil. It cannot be told apart from a
    /// fresh install, and ActivityKit's own stale handling covers a banner whose
    /// data has stopped arriving.
    enum LoopState {
        case ok
        case late
        case overdue
        /// A manual temp basal is running. Distinct from `.inactive` so the dot shows
        /// the same blue as the Home pill rather than a neutral grey.
        case manualTemp
        /// Open loop, or no loop date to judge. Neutral rather than alarming —
        /// the loop is switched off or has not reported yet, neither of which is
        /// a fault.
        case inactive

        var color: Color {
            switch self {
            case .ok: return green
            case .late: return .orange
            case .overdue: return red
            // Qualified: bare `manualTemp` would resolve to this enum's own case.
            case .manualTemp: return LiveActivityCustomPalette.manualTemp
            case .inactive: return .secondary
            }
        }
    }

    /// Maps the severity the app pushed. Deliberately *not* a function of `Date()`:
    /// see `LiveActivityAttributes.LoopStatus.Severity`. The thresholds behind it now
    /// live in `LoopFreshness`, shared with the Home loop pill and the contact image,
    /// so all three cross a band at the same instant — this used to be a fourth
    /// hand-written copy of the ladder, and the only one with no 30s lag, so it turned
    /// amber a half-minute before the app did.
    static func loopState(for status: LiveActivityAttributes.LoopStatus?) -> LoopState {
        // `nil` severity means a state encoded by an older build — see the field's
        // note. Neutral rather than guessing, and it lasts one push at most.
        guard let status, let severity = status.severity else { return .inactive }
        switch severity {
        case .ok: return .ok
        case .late: return .late
        case .overdue: return .overdue
        case .manualTemp: return .manualTemp
        case .inactive: return .inactive
        }
    }

    static func phaseColor(_ phase: LiveActivityAttributes.DeviceLifecycle.Phase) -> Color {
        switch phase {
        case .ok: return green
        case .warning: return .orange
        case .expired,
             .grace: return red
        }
    }
}
