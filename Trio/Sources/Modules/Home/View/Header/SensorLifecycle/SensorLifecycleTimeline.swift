import Foundation
import LoopKit

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
}
