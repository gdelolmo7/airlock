import Foundation

/// Whether Apple's on-device language model can be used, and what to tell the
/// user when it cannot.
///
/// Shared because two features now depend on the same model — transcript cleanup
/// and answering a spoken question — and the same condition must not grow two
/// different explanations. The mapping from `SystemLanguageModel.availability`
/// into this lives in the app target; this is the vocabulary and the sentences.
///
/// `feature` is the noun the sentence is built around ("cleanup", "answering"),
/// so one condition reads naturally wherever it surfaces.
public enum ModelAvailability: Equatable, Sendable {
    case ready
    /// Present, but the user has to do something.
    case needsAppleIntelligence
    case deviceNotEligible
    case modelNotReady
    case unknown(String)

    public var isReady: Bool { self == .ready }

    /// True when there is no on-device model to wait for.
    ///
    /// The difference between a redirect and an error. `.modelNotReady` is a
    /// download that will finish, so "try again shortly" is honest; these two
    /// never resolve on their own, and dressing them as a fault implies a
    /// retry that will never work. What is left is a real choice — escalate,
    /// or stop being asked — which is a redirect, not a failure.
    public var hasNoModel: Bool {
        switch self {
        case .needsAppleIntelligence, .deviceNotEligible: return true
        case .ready, .modelNotReady, .unknown: return false
        }
    }

    public func message(feature: String) -> String? {
        switch self {
        case .ready:
            return nil
        case .needsAppleIntelligence:
            return "Turn on Apple Intelligence in System Settings to enable \(feature)."
        case .deviceNotEligible:
            return "This Mac can't run Apple's on-device model, so \(feature) is unavailable."
        case .modelNotReady:
            return "Apple's on-device model is still downloading. "
                + "\(Self.capitalised(feature)) will start working once it finishes."
        case .unknown:
            // Not the reason: it is the framework's own enum case, which reads
            // as code. Dictation logs it at start (`DictationModel.start`).
            return "\(Self.capitalised(feature)) isn't available on this Mac right now."
        }
    }

    /// First letter only. `String.capitalized` would turn "asking the notch"
    /// into "Asking The Notch".
    private static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
