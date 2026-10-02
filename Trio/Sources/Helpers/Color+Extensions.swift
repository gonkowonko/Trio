import SwiftUI
import UIKit

extension Color {
    static let carbs = Color("carbs")

    static let fresh = Color("fresh")

    static let glucose = Color("glucose")

    static let insulin =
        // workaround for 'No color named 'Insulin' found in asset catalog' error which is most likely a bug
        Color(
            UIColor(named: "Insulin") ??
                UIColor(red: 0.118, green: 0.588, blue: 0.988, alpha: 1.0) // these are RGB of our insulin color
        )

    // The loopAccent color is intended to be use as the app accent color.
    public static let loopAccent = Color("accent")

    public static let warning = Color("warning")
}

// Color version of the UIColor context colors
public extension Color {
    static let agingColor = warning

    static let axisLabelColor = secondary

    static let axisLineColor = clear

    #if os(iOS)
        static let cellBackgroundColor = Color(UIColor.cellBackgroundColor)
        static let gridColor = Color(UIColor.gridColor)
        static let unknownColor = Color(UIColor.unknownColor)
    #endif

    static let carbTintColor = carbs

    static let critical = red

    static let destructive = critical

    static let glucoseTintColor = glucose

    static let invalid = critical

    static let insulinTintColor = insulin

    static let pumpStatusNormal = insulin

    static let staleColor = critical
}

extension Color {
    static let loopGray = Color("LoopGray")
    static let loopGreen = Color("LoopGreen")
    static let loopYellow = Color("LoopYellow")
    static let loopRed = Color("LoopRed")
    static let loopManualTemp = Color("ManualTempBasal")
    static let bgDarkBlue = Color("Background_DarkBlue")
    static let bgDarkerDarkBlue = Color("Background_DarkerDarkBlue")
    static let chart = Color("Chart")
    static let tabBar = Color("TabBar")
    //   static let insulin = Color("Insulin")
    static let uam = Color("UAM")
    static let zt = Color("ZT")
    static let tempBasal = Color("TempBasal")
    static let basal = Color("Basal")
    static let darkerBlue = Color("DarkerBlue")
    static let minus = Color("minus")
    static let darkGray = Color("darkGray")
    static let darkGreen = Color("darkGreen")
    static let darkOrange = Color("darkOrange")
}

// MARK: - Shared loop freshness

/// The single source of truth for "how is the loop doing right now", used by every
/// surface that paints loop status: the Home header pill and the contact image's
/// loop ring.
///
/// These were three independent copies of one ladder — `LoopView.color`,
/// `ContactPicture.ringColor`, and `ContactImageManager`'s render cache — each with
/// its own `30` and its own 5/10-minute thresholds. Two of them drifting apart makes
/// the pill and the contact photo disagree on screen. The third drifting is worse:
/// the cache decides whether a re-render is even worth writing, so if its ladder and
/// the renderer's ever disagreed, the ring would freeze on a stale colour while the
/// cache insisted nothing had changed.
enum LoopFreshness: Equatable {
    /// The loop has never completed, so there is no age to band yet.
    case never
    /// Closed loop is off — the loop is not driving delivery.
    case openLoop
    /// A manual temp basal is running; the user is driving, not the loop.
    case manualTemp
    case fresh
    case aging
    case stale

    /// Subtracted from the loop's age before banding, so a loop running in step with
    /// the CGM's own 5-minute cadence doesn't spend the tail of every cycle amber.
    static let lag: TimeInterval = 30

    private static let freshLimit: TimeInterval = 5 * 60
    private static let agingLimit: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - lastLoopDate: when the loop last *completed*; `nil` if it never has.
    ///     Callers holding the `.distantPast` sentinel should map it to `nil`.
    ///   - now: passed in rather than read here, so a view driven by a tick timer and
    ///     an offscreen renderer are each classified against their own clock.
    static func classify(
        lastLoopDate: Date?,
        now: Date,
        closedLoop: Bool,
        manualTempBasal: Bool
    ) -> LoopFreshness {
        // Order matters, and reproduces the Home pill's existing behaviour exactly:
        // open loop outranks a manual temp basal. `reportEnacted` is only called in
        // closed loop, so the pill's old "no enacted determination" guard already
        // painted open loop grey whether or not a manual temp was running. Verified
        // against the previous implementation over every reachable combination of
        // the four inputs.
        guard let lastLoopDate = lastLoopDate else { return .never }
        guard closedLoop else { return .openLoop }
        guard !manualTempBasal else { return .manualTemp }

        let age = now.timeIntervalSince(lastLoopDate) - lag
        if age <= freshLimit {
            return .fresh
        } else if age <= agingLimit {
            return .aging
        } else {
            return .stale
        }
    }

    /// When the band will next change for a loop that completed at `lastLoopDate`,
    /// or `nil` once nothing further can change.
    ///
    /// Exists for surfaces that cannot re-evaluate themselves on a timer. A Live
    /// Activity is the case in point: its body does not re-run on a timer, and — per
    /// the 2026-08-24 report — not dependably on screen wake either, so it has to be
    /// *told* when to refresh rather than working it out as it draws.
    static func nextBoundary(lastLoopDate: Date, after now: Date) -> Date? {
        [
            lastLoopDate.addingTimeInterval(lag + freshLimit),
            lastLoopDate.addingTimeInterval(lag + agingLimit)
        ].first { $0 > now }
    }

    /// On-screen colour, resolved against the viewer's trait collection.
    var color: Color {
        switch self {
        case .never,
             .openLoop: .secondary
        case .manualTemp: .loopManualTemp
        case .fresh: .loopGreen
        case .aging: .loopYellow
        case .stale: .loopRed
        }
    }

    /// Colour for the contact image, which is drawn into a trait-less bitmap where
    /// dynamic colours resolve to their light-mode variant and a nominal grey can
    /// come out near-white. Only the two inactive states differ from `color`; every
    /// state that carries loop *timing* is the same asset on both surfaces, so the
    /// ring and the pill show identical green, amber, red and manual-temp blue.
    var bitmapColor: Color {
        switch self {
        case .never,
             .openLoop: .loopGray
        default: color
        }
    }
}

// MARK: - Shared glucose freshness

/// How old the current CGM reading is, in the steps the contact image draws it.
///
/// The 12-minute boundary is not a taste decision: `APSManager` refuses to dose on
/// glucose older than that ("Glucose data is stale. The most recent glucose reading is
/// from more than 12 minutes ago.", `APSManager.swift`), and the Home bobble masks its
/// value to dashes at the same point (`CurrentGlucoseView.isReadingFresh`). Aligning
/// to it means the contact image dims exactly when the app stops trusting the reading.
///
/// Both of those still hold their own copy of the number, and this is a third —
/// deliberately, because the alternative was editing core dosing code for a display
/// concern. If that constant ever moves upstream, it has to move here too.
enum GlucoseFreshness: Equatable {
    /// Current — drawn at full strength.
    case fresh
    /// >= 6 min. One CGM cycle past due: getting old, still worth reading.
    case aging
    /// >= 12 min. The algorithm will not dose on this any more.
    case stale
    /// >= 20 min, or no reading at all. No longer drawn as a number.
    case expired

    private static let agingInterval: TimeInterval = 6 * 60
    private static let staleInterval: TimeInterval = 12 * 60
    private static let expiredInterval: TimeInterval = 20 * 60

    static func classify(glucoseDate: Date?, now: Date = Date()) -> GlucoseFreshness {
        guard let glucoseDate = glucoseDate else { return .expired }
        // Deliberately *not* offset by `LoopFreshness.lag`. That grace exists so a loop
        // landing on the CGM's 5-minute cadence doesn't flicker amber; it has nothing to
        // do with a reading's own age, and neither `APSManager` nor the bobble applies
        // it. Carrying it here pushed this ladder 30s later than the app's, which is
        // precisely the drift these shared classifiers exist to prevent.
        let age = now.timeIntervalSince(glucoseDate)
        if age >= expiredInterval {
            return .expired
        } else if age >= staleInterval {
            return .stale
        } else if age >= agingInterval {
            return .aging
        } else {
            return .fresh
        }
    }

    /// How strongly to draw the glucose-derived pieces. Two dim levels rather than one,
    /// because "a cycle late" and "too old to dose on" are different messages and the
    /// contact image has no age readout to tell them apart — `ContactImageValue` offers
    /// `lastLoopDate` but nothing for the reading's own age.
    var opacity: Double {
        switch self {
        case .fresh: 1
        case .aging: 0.55
        case .stale: 0.32
        // Never applied: `.expired` replaces the text rather than fading it.
        case .expired: 1
        }
    }

    /// Whether the reading is still inside the window the algorithm will dose on —
    /// younger than `staleInterval`.
    ///
    /// The two display surfaces diverge here *by choice*, not by accident: the Home
    /// bobble masks its value to dashes the moment this goes false, mirroring
    /// `APSManager`'s gate, while the contact image keeps drawing the number, dimmed
    /// further, because a glanceable "what it was" is worth having on a surface read
    /// without the app in front of you. Sharing the boundary means they cross it at
    /// the same instant regardless of what each then chooses to draw.
    var isWithinDosingWindow: Bool {
        self == .fresh || self == .aging
    }

    /// Whether the reading is still drawn as a number at all.
    ///
    /// Past `expiredInterval` it is not. Dimming alone is unbounded — with no age shown
    /// beside it, a faded number is indistinguishable at 25 minutes and at 5 hours, and
    /// the contact photo is read *without* the app, on a call screen or in Contacts,
    /// where there is nothing else to correct the impression.
    var showsValue: Bool { self != .expired }
}
