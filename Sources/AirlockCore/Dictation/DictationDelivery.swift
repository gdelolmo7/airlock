/// Where a finished transcript actually goes.
///
/// **This exists because the answer was spread across two `if`s in
/// `DictationModel`, and one of them lost the words.** The `.copy` route had a
/// clipboard fallback; the not-trusted-by-Accessibility path had a status
/// message and a `return`. So a dictation that was heard, transcribed and
/// scored at 0.923 confidence was deleted, and the only thing saying so was a
/// line in the notch panel — which is by construction not where the user is
/// looking, since dictation types into OTHER apps.
///
/// The Permissions pane had promised the opposite in as many words: "dictation
/// still listens and still transcribes — it just puts the result on the
/// clipboard instead of typing it". This is that promise, as one decision that
/// can be tested.
public enum DictationDelivery: String, Equatable, Sendable {
    /// Post it as keystrokes at the cursor.
    case type
    /// Put it on the clipboard and say so.
    case copy

    /// The only rule: **a transcript is never discarded.** Typing needs both
    /// somewhere to type and permission to do it; failing either means the
    /// clipboard, never nothing.
    public static func decide(route: DictationRoute, isAccessibilityTrusted: Bool) -> DictationDelivery {
        guard route == .type, isAccessibilityTrusted else { return .copy }
        return .type
    }
}
