import Foundation

struct ContactImageState: Codable {
    var glucose: String?
    var trend: String?
    var direction: BloodGlucose.Direction?
    var glucoseDate: Date?
    var delta: String?
    /// Timestamp of the glucose reading behind `glucose`/`trend`/`delta`.
    /// Used to mute those pieces once the CGM reading goes stale.
    var glucoseDate: Date?
    var lastLoopDate: Date?
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
