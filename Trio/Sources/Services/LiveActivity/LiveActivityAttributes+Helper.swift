import Foundation
import LoopKit

extension UserDefaults {
    private enum Keys {
        static let liveActivityOrder = "liveActivityOrder"
    }

    func loadLiveActivityOrderFromUserDefaults() -> [LiveActivityAttributes.LiveActivityItem]? {
        if let itemStrings = stringArray(forKey: Keys.liveActivityOrder) {
            return itemStrings.map { string in
                if string == "" {
                    return .empty
                } else {
                    return LiveActivityAttributes.LiveActivityItem(rawValue: string) ?? .empty
                }
            }
        }
        return nil
    }
}

extension LiveActivityAttributes.ContentState {
    static func formatGlucose(_ value: Int, units: GlucoseUnits, forceSign: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        if units == .mmolL {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
        }
        if forceSign {
            formatter.positivePrefix = formatter.plusSign
        }
        formatter.roundingMode = .halfUp

        return formatter
            .string(from: units == .mmolL ? value.asMmolL as NSNumber : NSNumber(value: value))!
    }

    static func calculateChange(chart: [GlucoseData], units: GlucoseUnits) -> String {
        guard chart.count > 2 else { return "" }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "  +"
        formatter.negativePrefix = "  -"

        var lastGlucose = Decimal(chart.first?.glucose ?? 0)
        var secondLastGlucose = Decimal(chart.dropFirst().first?.glucose ?? 0)
        if units == .mmolL {
            lastGlucose = lastGlucose.asMmolL
            secondLastGlucose = secondLastGlucose.asMmolL

            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
        }

        let delta = lastGlucose - secondLastGlucose
        return formatter.string(from: delta as NSNumber) ?? "--"
    }

    init(
        new bg: GlucoseData,
        prev _: GlucoseData?,
        units: GlucoseUnits,
        chart: [GlucoseData],
        settings: TrioSettings,
        determination: DeterminationData?,
        iob: Decimal?,
        override: OverrideData?,
        tempTarget: TempTargetData?,
        widgetItems: [LiveActivityAttributes.LiveActivityItem]?,
        cgmLifecycle: LiveActivityAttributes.DeviceLifecycle?,
        pumpLifecycle: LiveActivityAttributes.DeviceLifecycle?,
        loopStatus: LiveActivityAttributes.LoopStatus?,
        cgmStatus: LiveActivityAttributes.DeviceStatusMessage?,
        pumpStatus: LiveActivityAttributes.DeviceStatusMessage?,
        basal: LiveActivityAttributes.BasalStatus?
    ) {
        let glucose = bg.glucose
        let formattedBG = Self.formatGlucose(Int(glucose), units: units, forceSign: false)
        var rotationDegrees = 0.0

        switch bg.direction {
        case .doubleUp,
             .singleUp,
             .tripleUp:
            rotationDegrees = -90
        case .fortyFiveUp:
            rotationDegrees = -45
        case .flat:
            rotationDegrees = 0
        case .fortyFiveDown:
            rotationDegrees = 45
        case .doubleDown,
             .singleDown,
             .tripleDown:
            rotationDegrees = 90
        case nil,
             .notComputable,
             .rateOutOfRange:
            rotationDegrees = 0
        default:
            rotationDegrees = 0
        }

        let trendString = bg.direction?.symbol as? String
        let change = Self.calculateChange(chart: chart, units: units)

        let detailedState = LiveActivityAttributes.ContentAdditionalState(
            chart: chart.map { LiveActivityAttributes.ChartItem(value: Decimal($0.glucose), date: $0.date) },
            rotationDegrees: rotationDegrees,
            cob: Decimal(determination?.cob ?? 0),
            iob: iob ?? 0 as Decimal,
            tdd: determination?.tdd ?? 0 as Decimal,
            isOverrideActive: override?.isActive ?? false,
            overrideName: override?.overrideName ?? "Override",
            // LA-COALESCE: a fixed sentinel, not `Date()`. This field is only
            // read when `isOverrideActive`, so its value is meaningless while no
            // override is running — but `Date()` made it *different on every
            // construction*, which meant two states describing an identical
            // screen never compared equal. That silently defeated the dedupe in
            // `pushUpdate`: it logged zero skips across a full day.
            overrideDate: override?.date ?? Date(timeIntervalSince1970: 0),
            // An indefinite override is normalised to a zero duration here
            // rather than carried as its own field, because zero already means
            // "no end to count down to" everywhere downstream, and the pushed
            // state has a size budget worth not spending on a second flag.
            // CoreData keeps `indefinite` and `duration` independent, so an
            // override switched to indefinite retains its old duration and would
            // otherwise keep counting down to an end that no longer exists.
            overrideDuration: (override?.indefinite ?? false) ? 0 : (override?.duration ?? 0),
            overrideTarget: override?.target ?? 0,
            isTempTargetActive: tempTarget?.isActive ?? false,
            tempTargetName: tempTarget?.tempTargetName ?? "Temp Target",
            // LA-COALESCE: same reason as `overrideDate` above.
            tempTargetDate: tempTarget?.date ?? Date(timeIntervalSince1970: 0),
            tempTargetDuration: tempTarget?.duration ?? 0,
            tempTargetTarget: tempTarget?.target ?? 0,
            widgetItems: widgetItems ?? [], // set empty array here to silence compiler; this can never be nil
            minForecast: settings.displayGlucoseForecasts && settings.forecastDisplayType == .cone
                ? (determination?.minForecast ?? []) : [],
            maxForecast: settings.displayGlucoseForecasts && settings.forecastDisplayType == .cone
                ? (determination?.maxForecast ?? []) : [],
            forecastLines: settings.displayGlucoseForecasts && settings.forecastDisplayType == .lines
                ? (determination?.forecastLines ?? [])
                .map { LiveActivityAttributes.ForecastLine(type: $0.type, values: $0.values) }
                : [],
            forecastDisplayType: settings.forecastDisplayType.rawValue,
            cgmLifecycle: cgmLifecycle,
            pumpLifecycle: pumpLifecycle,
            loopStatus: loopStatus,
            cgmStatus: cgmStatus,
            pumpStatus: pumpStatus,
            basal: basal
        )

        self.init(
            unit: settings.units.rawValue,
            bg: formattedBG,
            direction: trendString,
            change: change,
            date: determination?.date ?? nil,
            highGlucose: settings.high,
            lowGlucose: settings.low,
            target: determination?.target ?? 100 as Decimal,
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            lockScreenStyleIOS: LiveActivityAttributes.LockScreenStyle(
                rawValue: settings.lockScreenView.rawValue
            ) ?? .simple,
            lockScreenStyleWatchOS: LiveActivityAttributes.LockScreenStyle(
                rawValue: settings.smartStackView.rawValue
            ) ?? .simple,
            detailedViewState: detailedState,
            isInitialState: false
        )
    }
}

/// Turns raw device lifecycle anchors into the `DeviceLifecycle` the Live
/// Activity's status pills render.
///
/// Thresholds are `DeviceLanesView`'s, so the pills and the home-screen lanes
/// escalate at the same moments:
/// - **CGM** — the final window is `SensorLifecycleTimeline.finalPhaseDuration`
///   (24 h on G7), then a grace period running to `endsAt`.
/// - **Pump** — orange inside the last 12 h, then an 8 h grace window past
///   nominal expiry before hard shutdown.
///
/// The lane still computes its own phases from the same constants. Collapsing
/// `DeviceLanesView.sensorPhase` / `podPhase` onto this type is the obvious
/// follow-up, and would leave one definition of when a device is "in trouble".
enum LiveActivityDeviceLifecycle {
    /// Omnipod's grace window: the pod keeps delivering for 8 h past nominal
    /// expiry before it shuts down hard.
    static let podGraceWindow: TimeInterval = 8 * 60 * 60
    /// Orange inside the last 12 h, matching `DeviceLanesView.podWarnWindow`.
    static let podWarnWindow: TimeInterval = 12 * 60 * 60
    /// Fallback final window for CGMs that expose an expiry date but no
    /// lifespan anchors, so no `SensorLifecycleTimeline` can be built.
    static let sensorFallbackWarnWindow: TimeInterval = 24 * 60 * 60

    /// - Parameters:
    ///   - timeline: Full lifespan anchors, when the manager exposes them (G7).
    ///     Preferred, because it is the only source that knows the grace end.
    ///   - expiresAt: Bare expiry date, used when there is no timeline. Without
    ///     a known grace window a sensor goes straight from `warning` to
    ///     `expired` at this date.
    static func cgm(
        timeline: SensorLifecycleTimeline?,
        expiresAt: Date?,
        now: Date = Date()
    ) -> LiveActivityAttributes.DeviceLifecycle? {
        if let timeline {
            if now >= timeline.endsAt {
                return .init(phase: .expired, endsAt: nil)
            }
            if now >= timeline.expiresAt {
                return .init(phase: .grace, endsAt: timeline.endsAt)
            }
            guard let arc = timeline.arcState(now: now) else {
                return .init(phase: .expired, endsAt: nil)
            }
            switch arc.state {
            case .critical,
                 .warning:
                return .init(phase: .warning, endsAt: timeline.expiresAt)
            default:
                return .init(phase: .ok, endsAt: timeline.expiresAt)
            }
        }

        guard let expiresAt else { return nil }
        if now >= expiresAt { return .init(phase: .expired, endsAt: nil) }
        if expiresAt.timeIntervalSince(now) <= sensorFallbackWarnWindow {
            return .init(phase: .warning, endsAt: expiresAt)
        }
        return .init(phase: .ok, endsAt: expiresAt)
    }

    /// - Parameters:
    ///   - expiresAt: Nominal end of the pod's life, *excluding* grace.
    ///     `DeviceDataManager` already normalises Medtrum's `patchExpiresAt`
    ///     (which bakes grace in) to `patchGracePeriodFrom` for this reason.
    ///   - isPumpSetUp: Whether a pump is paired at all. A pump with no session
    ///     clock (Medtronic, Dana) reports `ok` rather than disappearing.
    static func pump(
        expiresAt: Date?,
        isPumpSetUp: Bool,
        now: Date = Date()
    ) -> LiveActivityAttributes.DeviceLifecycle? {
        guard isPumpSetUp else { return nil }
        guard let expiresAt else { return .init(phase: .ok, endsAt: nil) }

        let shutdownAt = expiresAt.addingTimeInterval(podGraceWindow)
        if now >= shutdownAt { return .init(phase: .expired, endsAt: nil) }
        if now >= expiresAt { return .init(phase: .grace, endsAt: shutdownAt) }
        if expiresAt.timeIntervalSince(now) <= podWarnWindow {
            return .init(phase: .warning, endsAt: expiresAt)
        }
        return .init(phase: .ok, endsAt: expiresAt)
    }
}
