import Foundation

struct OverrideData {
    let isActive: Bool
    let overrideName: String
    let date: Date
    let duration: Decimal
    let target: Decimal
    /// Runs until cancelled. Held separately from `duration` because that is
    /// what CoreData does — switching an override to indefinite sets this flag
    /// and leaves the old duration in place, so `duration` alone cannot say
    /// whether there is an end to count down to.
    let indefinite: Bool
}
