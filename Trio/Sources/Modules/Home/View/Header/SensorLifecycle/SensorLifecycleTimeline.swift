import CGMBLEKit
import CGMBLEKitUI
import Foundation
import G7SensorKit
import LibreLoop
import LibreTransmitter
import LoopKit
import LoopKitUI

/// Anchor dates describing a sensor's full lifespan, used to drive the
/// always-on countdown ring around the glucose bobble. Populated per-CGM in
/// `Home.StateModel` (currently G7 only; other CGMs fall back to the legacy
/// last-48h `cgmProgress` arc).
///
/// The ring shows *time remaining* (full → empty) in three phases, each of
/// which drains evenly across its own window:
/// - **normal life**: green, drains linearly over the full `start...expiresAt` span
/// - **final window** (`finalPhaseDuration` before expiry): refills to full
///   orange, drains to empty at `expiresAt`
/// - **grace period** (`expiresAt...endsAt`): refills to full red, drains to
///   empty at `endsAt`
struct SensorLifecycleTimeline: Equatable {
    /// Sensor activation — session start, including warmup.
    let start: Date
    /// End of normal sensor life.
    let expiresAt: Date
    /// True end of the session, including any grace period. Equals `expiresAt`
    /// when the sensor has no grace period.
    let endsAt: Date
    /// Length of the highlighted "final" window immediately before expiry.
    let finalPhaseDuration: TimeInterval

    /// Dexcom G7 uses a 24 h final window.
    static let defaultFinalPhaseDuration: TimeInterval = 24 * 60 * 60

    /// Fill fraction (1 = full, 0 = empty) and color state for the ring at
    /// `now`. Returns `nil` once the session is fully over (past `endsAt`) so
    /// the ring hides and leaves the status tag to report expiry.
    func arcState(now: Date) -> (fraction: Double, state: DeviceLifecycleProgressState)? {
        // Fully expired, past any grace period — nothing left to count down.
        if now >= endsAt { return nil }

        // Grace period: red, drains evenly to the real end.
        if now >= expiresAt {
            let graceSpan = endsAt.timeIntervalSince(expiresAt)
            guard graceSpan > 0 else { return nil }
            let remaining = endsAt.timeIntervalSince(now)
            return (Self.clamp(remaining / graceSpan), .critical)
        }

        // Final window: orange, refills to full and drains to empty at expiry.
        if finalPhaseDuration > 0 {
            let finalStart = expiresAt.addingTimeInterval(-finalPhaseDuration)
            if now >= finalStart {
                let remaining = expiresAt.timeIntervalSince(now)
                return (Self.clamp(remaining / finalPhaseDuration), .warning)
            }
        }

        // Normal life: green, drains evenly over the full lifespan.
        let span = expiresAt.timeIntervalSince(start)
        guard span > 0 else { return nil }
        let remaining = expiresAt.timeIntervalSince(now)
        return (Self.clamp(remaining / span), .normalCGM)
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }

    /// Builds a timeline from a CGM manager. Currently G7 only — it is the one
    /// manager exposing activation, lifetime *and* grace end. Other CGMs return
    /// `nil`, leaving callers to fall back to a bare expiry date.
    static func resolve(manager: CGMManagerUI?) -> SensorLifecycleTimeline? {
        guard let g7 = manager as? G7CGMManager,
              let start = g7.sensorActivatedAt,
              let expiresAt = g7.sensorExpiresAt,
              let endsAt = g7.sensorEndsAt
        else { return nil }
        return SensorLifecycleTimeline(
            start: start,
            expiresAt: expiresAt,
            endsAt: endsAt,
            finalPhaseDuration: defaultFinalPhaseDuration
        )
    }
}

/// Resolves a sensor's expiry date across the CGM managers Trio supports.
///
/// Shared by the home-screen header and the Live Activity's device pills so
/// both agree on when a sensor is running out. `SensorLifecycleTimeline.resolve`
/// is the richer source — it knows the grace end too — but only G7 exposes the
/// anchors it needs, so everything else falls back to this bare date.
enum SensorExpiryResolver {
    /// Prefers manager-reported dates; reverse-derives from
    /// `lifecycle.percentComplete` when not available. `activatedAt` must be
    /// session start, not transmitter activation.
    static func expiresAt(
        manager: CGMManagerUI?,
        glucoseSource: GlucoseSource?,
        lifecycle: DeviceLifecycleProgress?,
        now: Date = Date()
    ) -> Date? {
        if let sim = glucoseSource as? GlucoseSimulatorSource {
            return sim.simulatedSensorExpiresAt
        }
        guard let manager else { return nil }
        // Once a G7 enters grace period, `sensorExpiresAt` is in the past and
        // would collapse the bobble countdown to "<1m" while the arc (driven by
        // lifecycle.percentComplete against `sensorEndsAt`) is still mid-
        // progress. Fall back to `sensorEndsAt` so bobble and arc agree, and
        // the user sees grace-period time remaining.
        if let g7 = manager as? G7CGMManager {
            if let exp = g7.sensorExpiresAt, exp > now { return exp }
            return g7.sensorEndsAt ?? g7.sensorExpiresAt
        }
        if let g6 = manager as? G6CGMManager, let exp = g6.latestReading?.sessionExpDate { return exp }
        if let g5 = manager as? G5CGMManager, let exp = g5.latestReading?.sessionExpDate { return exp }

        // LibreLoop reports time remaining rather than an expiry date, so it is
        // resolved forward from `now`. Added when upstream introduced the
        // manager; the other arms above all read a date off the manager.
        if let libreLoop = manager as? LibreLoopCGMManager {
            if case let .active(remaining, _) = libreLoop.sensorLifecycle, remaining > 0 {
                return now.addingTimeInterval(remaining)
            }
            // Warmup / initializing / expired — no meaningful expiry yet.
            return nil
        }

        let activatedAt: Date?
        if let libre = manager as? LibreTransmitterManagerV3 {
            activatedAt = libre.sensorInfoObservable.activatedAt
        } else {
            activatedAt = nil
        }

        guard let activatedAt,
              let lifecycle,
              lifecycle.percentComplete > 0.001
        else { return nil }
        let elapsed = now.timeIntervalSince(activatedAt)
        guard elapsed > 0 else { return nil }
        return activatedAt.addingTimeInterval(elapsed / lifecycle.percentComplete)
    }
}
