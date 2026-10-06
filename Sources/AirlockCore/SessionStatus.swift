import Foundation

/// The semantic state of a session. Drives the notch's single accent language:
/// one warm "needs you", one cool "running", one green "done".
public enum SessionStatus: String, Codable, Sendable, Hashable {
    case starting
    case running
    case needsAttention     // permission requested — warm accent
    case waitingQuestion    // question asked — warm accent
    case idle               // turn finished, session still alive
    case done               // session ended
    case error

    /// Priority for sorting: lower sorts first (most urgent on top).
    public var sortRank: Int {
        switch self {
        case .needsAttention, .waitingQuestion: return 0
        case .running, .starting: return 1
        case .idle: return 2
        case .done: return 3
        case .error: return 4
        }
    }

    public var wantsAttention: Bool {
        self == .needsAttention || self == .waitingQuestion
    }
}
