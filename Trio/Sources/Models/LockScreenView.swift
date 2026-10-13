import Foundation

enum LockScreenView: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }
    case simple
    case detailed
    case custom

    /// Styles offered for the Watch / CarPlay Smart Stack. `custom` is an
    /// iPhone lock-screen layout only — it has no small-family rendering, so
    /// offering it there would be a setting that silently does nothing.
    static var smartStackCases: [LockScreenView] { [.simple, .detailed] }

    var displayName: String {
        switch self {
        case .simple:
            return String(localized: "Simple", comment: "")
        case .detailed:
            return String(localized: "Detailed", comment: "")
        case .custom:
            return String(localized: "Custom", comment: "")
        }
    }
}
