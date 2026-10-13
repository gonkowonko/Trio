import Foundation

struct DeterminationData {
    let cob: Int
    let tdd: Decimal
    let target: Decimal
    let date: Date?
    /// Temp basal rate the loop enacted, when one is running.
    let rate: Decimal?
    let minForecast: [Int]
    let maxForecast: [Int]
    let forecastLines: [(type: String, values: [Int])]
}
