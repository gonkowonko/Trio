import Foundation

struct ContactImageState: Codable {
    var glucose: String?
    /// Latest glucose reading in display units, matching the color threshold values below.
    var glucoseValue: Decimal?
    var trend: String?
    var direction: BloodGlucose.Direction?
    var delta: String?
    /// Timestamp of the glucose reading behind `glucose`/`trend`/`delta`.
    /// Used to mute those pieces once the CGM reading goes stale.
    var glucoseDate: Date?
    var lastLoopDate: Date?
    /// Both feed `LoopFreshness` alongside `lastLoopDate`, so the ring mirrors the
    /// Home loop pill's grey (open loop) and blue (manual temp) states rather than
    /// showing a confident green/amber/red for a loop that is not actually driving.
    var closedLoop: Bool = false
    var manualTempBasal: Bool = false
    var iob: Decimal?
    var iobText: String?
    var cob: Decimal?
    var cobText: String?
    var eventualBG: String?
    var maxIOB: Decimal = 10.0
    var maxCOB: Decimal = 120.0
    var highGlucoseColorValue: Decimal = 180.0
    var lowGlucoseColorValue: Decimal = 70.0
    var glucoseColorScheme: GlucoseColorScheme = .staticColor
    var targetGlucose: Decimal = 100.0
}
