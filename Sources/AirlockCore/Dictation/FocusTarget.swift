import Foundation

/// Whether the thing the user is focused on can take typed text.
///
/// This is the question that decides where a dictation goes: into the frontmost
/// app as keystrokes, or into the notch as a question. Getting it wrong in one
/// direction types a sentence into a window that treats single letters as
/// commands; getting it wrong in the other hijacks a dictation the user meant to
/// type. So the decision is a pure predicate over a value type, testable against
/// fixtures, and the Accessibility I/O that builds that value lives in the app
/// target where it belongs.
///
/// The attribute semantics here are Apple's public AX API. The traversal shape —
/// check the focused element, descend only into focused children, bound the
/// depth — is a documented pattern rather than anyone's code.
public enum FocusTarget {
    /// One Accessibility element, flattened into something with no references
    /// and no I/O.
    ///
    /// `declaresEditable` is an optional on purpose: AX distinguishes "this
    /// element says it is not editable" from "this element has no opinion", and
    /// collapsing those to `false` would lose the difference that
    /// `DictationRoute` needs to tell a definite answer from an absent one.
    public struct Snapshot: Equatable, Sendable {
        public var role: String
        public var isEnabled: Bool
        public var declaresEditable: Bool?
        public var valueIsSettable: Bool
        public var hasSelectedTextRange: Bool
        public var isFocused: Bool
        public var children: [Snapshot]

        public init(role: String = "",
                    isEnabled: Bool = true,
                    declaresEditable: Bool? = nil,
                    valueIsSettable: Bool = false,
                    hasSelectedTextRange: Bool = false,
                    isFocused: Bool = true,
                    children: [Snapshot] = []) {
            self.role = role
            self.isEnabled = isEnabled
            self.declaresEditable = declaresEditable
            self.valueIsSettable = valueIsSettable
            self.hasSelectedTextRange = hasSelectedTextRange
            self.isFocused = isFocused
            self.children = children
        }
    }

    /// Roles that take typed text by definition, whatever else they report.
    ///
    /// `AXSecureTextField` is in here deliberately, and the reason is privacy
    /// rather than completeness. Treating a password field as "not editable"
    /// would route a spoken password to the assistant — sent to a language model
    /// and then rendered on screen in the notch. Typing it is what happens today
    /// and is by far the lesser evil.
    public static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXSearchField",
    ]

    /// How far to descend before giving up. Web and Electron trees are deep, and
    /// an unbounded walk is an unbounded number of cross-process AX calls.
    public static let maximumDepth = 6

    /// Whether this single element takes typed text.
    ///
    /// A disabled element never does, whatever it claims — that check comes
    /// first because a disabled text field still reports a text-field role and a
    /// settable value.
    ///
    /// **Role is not evidence on its own, and that was measured the hard way.**
    /// Chrome reports the focused element of a Gmail inbox as `AXTextArea` while
    /// every keystroke is a single-letter shortcut — so a dictation was typed
    /// into it, and Gmail read the words as commands (`?` opened the shortcut
    /// overlay; `e` archives, `#` deletes). An `OR` over the role set turns every
    /// web app that focuses a hidden element into a keyboard-shortcut minefield.
    ///
    /// What actually distinguishes a text box is that you can *put text in it*:
    /// an explicit `AXEditable`, or a settable `AXValue`. A role and a selection
    /// range corroborate; neither carries the decision alone.
    ///
    /// The bias is deliberate. Too strict routes a real text field to `.ask` —
    /// visible in the pill before you speak, and abortable by releasing inside
    /// `HoldGesture.minimumHold`. Too loose types your sentence into a command
    /// interpreter, which is destructive and silent.
    public static func isEditable(_ snapshot: Snapshot) -> Bool {
        guard snapshot.isEnabled else { return false }
        // The one role trusted on its own, and the exception proves the rule:
        // nothing reports `AXSecureTextField` except an actual password field,
        // so it carries none of the ambiguity that made the general role test
        // dangerous. It gets the carve-out because both failures are bad here
        // and typing is the milder one — the alternative leaves a spoken
        // password sitting on the pasteboard for whatever pastes next.
        if snapshot.role == "AXSecureTextField" { return true }
        if let declared = snapshot.declaresEditable { return declared }
        if snapshot.valueIsSettable { return true }
        // A selection range only counts alongside a text role: read-only web
        // content exposes ranges too.
        return snapshot.hasSelectedTextRange && editableRoles.contains(snapshot.role)
    }

    /// Whether this element, or a focused descendant of it, takes typed text.
    ///
    /// Only *focused* children are followed. A window full of text fields is not
    /// a reason to type — exactly one thing has the caret, and descending into
    /// unfocused siblings would find an editable target in almost every app.
    public static func containsEditableTarget(_ snapshot: Snapshot,
                                              depth: Int = maximumDepth) -> Bool {
        if isEditable(snapshot) { return true }
        guard depth > 0 else { return false }
        return snapshot.children.contains {
            $0.isFocused && containsEditableTarget($0, depth: depth - 1)
        }
    }
}
