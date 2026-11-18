import Foundation

/// Whether typed words actually reached a text box, and what to do when they
/// may not have.
///
/// **Why this exists: typing "succeeding" proved nothing.** `TypeService.type`
/// posts keystrokes and returns true once they are posted; it cannot know
/// whether anything received them. The focus probe at key-down guards the
/// obvious case, but some apps report a focused, writable text box while
/// nothing on screen has the cursor (the owner, 2026-11-16: "I don't have an
/// input selected, and I try to dictate stuff, and when I finish dictating,
/// it isn't written anywhere, but it isn't copied on my clipboard"). The
/// dictation log showed every such hold routed to `.type` with a settable
/// `AXTextArea`, typed, and gone.
///
/// So after typing, the box with the focus is read again and compared with
/// what it held before. The rule the delivery keeps is the same one
/// `DictationDelivery` keeps: **a transcript is never discarded.** When the
/// words cannot be seen landing and nothing at key-down vouched for the box,
/// they go on the clipboard as well, and the notch says so.
///
/// Pure and value-typed; the Accessibility reads live in the app target.
public enum DictationLanding {
    /// One look at the focused element, flattened to what the verdict needs.
    /// The text is the person's own and is never logged.
    public enum Look: Equatable, Sendable {
        /// Accessibility answered, and nothing has the focus.
        case nothingFocused
        /// Something has the focus, but its text could not be read: a
        /// password box, a very long document, an app that exposes no value,
        /// a timeout.
        case unreadable
        /// The focused element's text.
        case text(String)

        /// For `dictationLog`: shape only, never the text.
        public var shortDescription: String {
            switch self {
            case .nothingFocused: return "nothingFocused"
            case .unreadable: return "unreadable"
            case .text(let text): return "text(\(text.utf16.count))"
            }
        }
    }

    public enum Verdict: String, Equatable, Sendable {
        /// The words are visibly in the box.
        case landed
        /// They are visibly not: nothing has the focus, or the box is exactly
        /// as it was before typing.
        case missed
        /// The box can't be read well enough to tell.
        case cannotTell
    }

    /// How many letters and digits from the end of the typed text must turn
    /// up in the box for the words to count as seen. Short enough to survive
    /// an autocorrection near the start, long enough not to match by chance.
    static let tailLength = 12

    /// Compares the focused box before and after typing.
    ///
    /// With a "before" to compare against, any change counts as landed:
    /// rich editors restyle quotes and dashes, autocorrect changes the last
    /// word, and a box that changed right after Airlock typed is far more
    /// likely to hold the dictation than not. Without one, the box must show
    /// the end of what was typed.
    public static func judge(typed: String, before: Look, after: Look) -> Verdict {
        switch after {
        case .nothingFocused:
            return .missed
        case .unreadable:
            return .cannotTell
        case .text(let now):
            // Unchanged comes first: a box that already held these words
            // (the same sentence dictated twice) must not pass for one that
            // just took them.
            if case .text(let was) = before {
                return was == now ? .missed : .landed
            }
            return contains(now, tailOf: typed) ? .landed : .cannotTell
        }
    }

    /// Whether the words must go on the clipboard as well as having been typed.
    ///
    /// - `missed`: always. Nothing took them.
    /// - `cannotTell`: only when nothing at key-down vouched for the box
    ///   either (`targetWasConfirmed` false: the focus probe could not read
    ///   the app, or had not answered yet). An app the probe saw a real text
    ///   box in but whose value is unreadable (a terminal with a long
    ///   scrollback) keeps working as it always has, without its clipboard
    ///   being replaced on every dictation.
    public static func copiesToo(_ verdict: Verdict, targetWasConfirmed: Bool) -> Bool {
        switch verdict {
        case .landed: return false
        case .missed: return true
        case .cannotTell: return !targetWasConfirmed
        }
    }

    /// Whether `text` holds the last `tailLength` letters and digits of
    /// `typed`, ignoring case, spacing and punctuation.
    static func contains(_ text: String, tailOf typed: String) -> Bool {
        let tail = String(letters(typed).suffix(tailLength))
        guard !tail.isEmpty else { return false }
        return letters(text).contains(tail)
    }

    private static func letters(_ text: String) -> String {
        String(text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }
}
