import ActivityKit
import Foundation

struct LiveActivityAttributes: ActivityAttributes {
    enum LiveActivityItem: String, Hashable, Codable, Equatable {
        case currentGlucoseLarge
        case currentGlucoseLargeUncolored
        case currentGlucose
        case currentGlucoseColored
        case currentGlucoseWide
        case currentGlucoseWideUncolored
        case iob
        case cob
        case updatedLabel
        case totalDailyDose
        case empty
        case wideContinuation

        static let defaultItems: [Self] = [.currentGlucoseLarge, .iob, .cob, .updatedLabel]
    }

    /// Which layout the widget should render. Mirrors the app-side
    /// `LockScreenView` setting, restated here because that type lives in the
    /// app target and the widget cannot see it.
    ///
    /// `custom` is iPhone-only; the small (Watch / Smart Stack) family falls
    /// back to `detailed` rather than rendering a layout never designed for it.
    enum LockScreenStyle: String, Codable, Hashable {
        case simple
        case detailed
        case custom
    }

    /// Loop health for the Custom layout's header. Kept as its own type so the
    /// Custom stream stays separable — nothing else reads it.
    struct LoopStatus: Codable, Hashable {
        /// How late the loop is, classified in the *app* and pushed, rather than
        /// derived from `Date()` when the widget draws itself.
        ///
        /// This used to be computed in `LiveActivityCustomPalette.loopState` at draw
        /// time, which quietly does not work: a Live Activity body re-evaluates on a
        /// push, and not dependably otherwise. Observed 2026-08-24 — the banner held a
        /// green dot at 6m11s while its system-rendered age text carried on counting,
        /// because nothing had re-run the body since the push that drew it.
        ///
        /// Carrying it in the state also repairs the LA-COALESCE dedupe: two states
        /// with identical data but different ages used to compare equal, so the very
        /// push that would have corrected the dot was the one most likely skipped.
        enum Severity: String, Codable, Hashable {
            case ok
            case late
            case overdue
            /// A user-set manual temp basal is running. Its own case rather than
            /// `.inactive`, so the dot can show the same colour the Home pill does.
            case manualTemp
            /// Open loop, or no loop has completed yet.
            case inactive
        }

        /// Last completed loop. Distinct from `ContentState.date`, which is the
        /// determination timestamp.
        let lastLoopDate: Date?
        let isClosedLoop: Bool
        let isManualTempBasal: Bool
        /// Optional purely for forward/backward compatibility across an app update.
        /// `ContentState` is encoded by the app and decoded by the *widget extension*,
        /// so an activity already running when a new build is installed carries a state
        /// encoded without this key — a non-optional would throw `keyNotFound` there and
        /// break rendering until the next push. Never written as nil; treat nil as
        /// "not yet reported".
        let severity: Severity?
    }

    /// What is driving basal delivery right now, mirroring the basal tag on the
    /// home screen's chart. `kind` decides the tile's *shape* — filled when the
    /// algorithm picked the rate, outlined when the pump is only walking the
    /// basal profile — which is readable without a second tile to compare
    /// against.
    struct BasalStatus: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            case temp
            case manualTemp
            case scheduled
        }

        let rate: Decimal?
        let kind: Kind
        /// Suspension is the loudest thing the tile can say, so it takes the
        /// slot rather than showing a rate that is not being delivered.
        let isSuspended: Bool
        /// LA-MANUAL-END: when a manual temp ends, shown in the basal tile's caption
        /// as a clock time. A clock time never goes stale between pushes, where a
        /// "30m" would sit frozen until the next update; a ticking timer would
        /// redraw the lock screen every second. Optional with a default so a
        /// state encoded by an older build still decodes. Nil unless `kind` is
        /// `.manualTemp`.
        var endsAt: Date? = nil
    }

    /// A device's live problem — warming up, signal loss, pod fault, occlusion.
    /// Outranks the lifecycle countdown while present: when a pump is in error,
    /// how long until it expires is not the useful fact.
    ///
    /// Severity is carried rather than assumed, so a warning is not painted in
    /// the red this layout otherwise reserves for genuinely critical states.
    /// It mirrors the app's ⚠️ / ‼️ prefixes without spending width on a glyph.
    struct DeviceStatusMessage: Codable, Hashable {
        let message: String
        let isCritical: Bool
    }

    struct SimpleViewStyle: Codable, Hashable {
        let fontSize: LiveActivityFontSize

        static let `default` = SimpleViewStyle(fontSize: .large)
    }

    struct ContentState: Codable, Hashable {
        let unit: String
        let bg: String
        /// Latest glucose reading in mg/dL; nil when no reading is shown.
        let glucose: Decimal?
        let direction: String?
        let change: String
        let date: Date?
        let highGlucose: Decimal
        let lowGlucose: Decimal
        let target: Decimal
        let glucoseColorScheme: String
        let lockScreenStyleIOS: LockScreenStyle
        let lockScreenStyleWatchOS: LockScreenStyle
        let simpleViewStyle: SimpleViewStyle
        let detailedViewState: ContentAdditionalState

        /// true for the first state that is set on the activity
        let isInitialState: Bool
    }

    struct ContentAdditionalState: Codable, Hashable {
        let chart: [ChartItem]
        let rotationDegrees: Double
        let cob: Decimal
        let iob: Decimal
        let tdd: Decimal
        let isOverrideActive: Bool
        let overrideName: String
        let overrideDate: Date
        let overrideDuration: Decimal
        let overrideTarget: Decimal
        let isTempTargetActive: Bool
        let tempTargetName: String
        let tempTargetDate: Date
        let tempTargetDuration: Decimal
        let tempTargetTarget: Decimal
        let widgetItems: [LiveActivityItem]
        let minForecast: [Int]
        let maxForecast: [Int]
        let forecastLines: [ForecastLine]
        let forecastDisplayType: String
        /// `nil` when the device isn't set up, or exposes no lifecycle dates at
        /// all — the pill is hidden rather than claiming a health it can't
        /// verify.
        let cgmLifecycle: DeviceLifecycle?
        let pumpLifecycle: DeviceLifecycle?
        /// Read only by the Custom layout. `nil` leaves its header dot neutral.
        let loopStatus: LoopStatus?
        /// Live device problems. `nil` during healthy operation, when the
        /// device rows show their countdowns instead.
        let cgmStatus: DeviceStatusMessage?
        let pumpStatus: DeviceStatusMessage?
        /// Read only by the Custom layout's basal tile.
        let basal: BasalStatus?
    }

    /// A device's lifecycle state, as rendered by the Live Activity's status
    /// pills. Phases mirror `DeviceLanePhase` on the home screen, plus the two
    /// post-expiry states the lane spells out in text.
    ///
    /// Deliberately carries `endsAt` rather than a formatted countdown string:
    /// the widget renders grace with `Text(timerInterval:)`, which ticks every
    /// second without an ActivityKit push, so the countdown stays honest
    /// between Trio's ~5 min state updates.
    struct DeviceLifecycle: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case ok
            case warning
            case grace
            case expired
        }

        let phase: Phase
        /// End of the *current phase's* window — nominal expiry while
        /// `warning`, hard shutdown while `grace`. Unused by `ok` and `expired`.
        let endsAt: Date?
    }

    struct ChartItem: Codable, Hashable {
        let value: Decimal
        let date: Date
    }

    struct ForecastLine: Codable, Hashable {
        let type: String
        let values: [Int]
    }

    let startDate: Date
}
