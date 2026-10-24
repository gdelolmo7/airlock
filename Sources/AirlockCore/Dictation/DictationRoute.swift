import Foundation

/// Where a dictation's text goes once transcribed.
///
/// Focus detection never decides what the user wants, only whether the place
/// in front of them can actually take text. A Gmail inbox reports its focused
/// element as `AXTextArea`, where every typed letter is a command, so no
/// heuristic here may ever turn into an action of its own. Its
/// worst case is now a transcript on the clipboard instead of in a document,
/// which is visible, recoverable, and does nothing on its own.
public enum DictationRoute: String, Equatable, Sendable {
    /// Type it at the cursor.
    case type
    /// Nowhere to type it — put it on the clipboard and say so.
    case copy

    /// What the focus probe managed to find out.
    public enum Probe: Equatable, Sendable {
        /// An element was focused and inspected.
        case focused(FocusTarget.Snapshot)
        /// The app was reachable and reported nothing focused — a Finder desktop,
        /// a window the user just clicked the background of.
        case nothingFocused
        /// The probe could not get an answer: no frontmost app, an AX timeout, a
        /// process that exposes no tree.
        case unknown

        /// For `dictationLog`. Shape only — never the element's value, which is
        /// the user's own text.
        public var shortDescription: String {
            switch self {
            case .focused(let snapshot):
                return "focused(\(snapshot.role.isEmpty ? "?" : snapshot.role)"
                    + " editable=\(snapshot.declaresEditable.map(String.init(describing:)) ?? "–")"
                    + " settable=\(snapshot.valueIsSettable)"
                    + " range=\(snapshot.hasSelectedTextRange)"
                    + " enabled=\(snapshot.isEnabled))"
            case .nothingFocused: return "nothingFocused"
            case .unknown: return "unknown"
            }
        }
    }

    /// `.unknown` resolves to `.type`: that is what this app did before any of
    /// this existed, so an app the probe cannot read keeps working exactly as it
    /// used to rather than quietly redirecting every dictation to the clipboard.
    /// A confidently wrong answer is the failure mode that hurt, not an absent
    /// one.
    public static func decide(_ probe: Probe) -> DictationRoute {
        switch probe {
        case .focused(let snapshot):
            return FocusTarget.containsEditableTarget(snapshot) ? .type : .copy
        case .nothingFocused:
            return .copy
        case .unknown:
            return .type
        }
    }
}
