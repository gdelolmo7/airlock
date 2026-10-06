import XCTest
@testable import AirlockCore

/// The routing decision is a heuristic over an Accessibility tree, so these
/// fixtures are the only place it can be pinned down exactly. Wrong in one
/// direction, a dictation is typed into a window that reads single letters as
/// commands; wrong in the other, a dictation the user meant to type is swallowed
/// by the notch.
final class DictationRouteTests: XCTestCase {
    private typealias Snapshot = FocusTarget.Snapshot

    // MARK: - Single elements

    func testPlainTextFieldIsEditable() {
        XCTAssertTrue(FocusTarget.isEditable(Snapshot(role: "AXTextField", valueIsSettable: true)))
        XCTAssertTrue(FocusTarget.isEditable(Snapshot(role: "AXTextArea", valueIsSettable: true)))
    }

    /// A password field must reach the field itself rather than the clipboard —
    /// leaving a spoken password sitting on the pasteboard for the next paste is
    /// the worse of the two failures.
    func testSecureFieldTypesRatherThanCopies() {
        let secure = Snapshot(role: "AXSecureTextField")
        XCTAssertEqual(DictationRoute.decide(.focused(secure)), .type)
    }

    /// A disabled field still reports its role and a settable value. Enabled is
    /// checked first for exactly that reason.
    func testDisabledFieldIsNotEditable() {
        let disabled = Snapshot(role: "AXTextField", isEnabled: false, valueIsSettable: true)
        XCTAssertFalse(FocusTarget.isEditable(disabled))
        XCTAssertEqual(DictationRoute.decide(.focused(disabled)), .copy)
    }

    /// An explicit `AXEditable == false` outranks a role that would otherwise
    /// qualify — a read-only text view is the case that matters.
    func testExplicitlyNotEditableOutranksRole() {
        let readOnly = Snapshot(role: "AXTextArea", declaresEditable: false)
        XCTAssertFalse(FocusTarget.isEditable(readOnly))
    }

    /// And the reverse: a custom role that declares itself editable is believed.
    func testExplicitlyEditableOutranksUnknownRole() {
        let custom = Snapshot(role: "AXGroup", declaresEditable: true)
        XCTAssertTrue(FocusTarget.isEditable(custom))
    }

    /// Web and Electron views often expose neither a known role nor AXEditable;
    /// a live selected-text range is what gives them away.
    /// A range alone is not enough — read-only web content exposes them too. It
    /// counts only alongside a text role.
    func testSelectedTextRangeNeedsATextRole() {
        XCTAssertFalse(FocusTarget.isEditable(Snapshot(role: "AXGroup", hasSelectedTextRange: true)))
        XCTAssertTrue(FocusTarget.isEditable(Snapshot(role: "AXTextField", hasSelectedTextRange: true)))
    }

    func testSettableValueIsEnoughOnItsOwn() {
        XCTAssertTrue(FocusTarget.isEditable(Snapshot(role: "AXUnknown", valueIsSettable: true)))
    }

    /// The measured Chrome/Gmail failure, kept as a fixture. Chrome reports an
    /// `AXTextArea` for an inbox where every keystroke is a shortcut, so the role
    /// alone must never be enough — a dictation typed there ran as commands.
    func testChromeTextAreaWithoutASettableValueDoesNotType() {
        let gmail = Snapshot(role: "AXTextArea", valueIsSettable: false)
        XCTAssertFalse(FocusTarget.isEditable(gmail))
        XCTAssertEqual(DictationRoute.decide(.focused(gmail)), .copy)
    }

    /// And the control: a real web textarea, which reports the same role but can
    /// actually take a value, still types.
    func testRealTextAreaStillTypes() {
        let real = Snapshot(role: "AXTextArea", valueIsSettable: true)
        XCTAssertEqual(DictationRoute.decide(.focused(real)), .type)
    }

    // MARK: - Descent

    func testFocusedDescendantIsFound() {
        let tree = Snapshot(role: "AXWindow", children: [
            Snapshot(role: "AXGroup", isFocused: true, children: [
                Snapshot(role: "AXTextField", valueIsSettable: true, isFocused: true),
            ]),
        ])
        XCTAssertEqual(DictationRoute.decide(.focused(tree)), .type)
    }

    /// The check that keeps this from matching everything: almost every window
    /// contains a text field somewhere, and exactly one thing has the caret.
    func testUnfocusedTextFieldIsIgnored() {
        let tree = Snapshot(role: "AXWindow", children: [
            Snapshot(role: "AXTextField", valueIsSettable: true, isFocused: false),
        ])
        XCTAssertEqual(DictationRoute.decide(.focused(tree)), .copy)
    }

    func testDescentIsBounded() {
        // One level deeper than the limit allows.
        var deep = Snapshot(role: "AXTextField", valueIsSettable: true, isFocused: true)
        for _ in 0...FocusTarget.maximumDepth {
            deep = Snapshot(role: "AXGroup", isFocused: true, children: [deep])
        }
        XCTAssertFalse(FocusTarget.containsEditableTarget(deep))
    }

    func testDescentReachesTheLimit() {
        var deep = Snapshot(role: "AXTextField", valueIsSettable: true, isFocused: true)
        for _ in 0..<FocusTarget.maximumDepth {
            deep = Snapshot(role: "AXGroup", isFocused: true, children: [deep])
        }
        XCTAssertTrue(FocusTarget.containsEditableTarget(deep))
    }

    // MARK: - The two non-element outcomes

    func testNothingFocusedCopies() {
        XCTAssertEqual(DictationRoute.decide(.nothingFocused), .copy)
    }

    /// The load-bearing default. A probe that goes blind must degrade to what
    /// the app did before this feature existed, never into hijacking every
    /// dictation.
    func testUnknownTypes() {
        XCTAssertEqual(DictationRoute.decide(.unknown), .type)
    }

    // MARK: - Prompt gate

    func testOnlyEmptyTextIsNotAQuestion() {
        XCTAssertTrue(AssistantPrompt.isWorthAsking("why"))
        XCTAssertFalse(AssistantPrompt.isWorthAsking(""))
        XCTAssertTrue(AssistantPrompt.isWorthAsking("what's a monad"))
    }
}

/// An echoed question occupies the answer's place on screen and says nothing.
/// Measured live: "Okay, how does this work?" came back as "How does this work?".
final class AssistantEchoTests: XCTestCase {
    func testTheMeasuredEcho() {
        XCTAssertTrue(AssistantPrompt.isEcho(question: "Okay, how does this work?",
                                             answer: "How does this work?"))
    }

    func testVerbatimEcho() {
        XCTAssertTrue(AssistantPrompt.isEcho(question: "what's a monad",
                                             answer: "What's a monad?"))
    }

    /// A real answer reuses the question's words freely — that must not read as
    /// an echo, or every well-formed reply gets thrown away.
    func testRealAnswerIsNotAnEcho() {
        XCTAssertFalse(AssistantPrompt.isEcho(
            question: "what's the capital of France",
            answer: "**Paris** is the capital of France."))
        XCTAssertFalse(AssistantPrompt.isEcho(
            question: "how does this work",
            answer: "**How this works**  * **Input**: You speak into your Mac. "
                + "* **Processing**: I interpret it and generate a response."))
    }

    /// A terse but genuine answer, built almost entirely from the question's own
    /// words, still has to survive.
    func testShortGenuineAnswerSurvives() {
        XCTAssertFalse(AssistantPrompt.isEcho(question: "is Swift statically typed",
                                              answer: "Yes, Swift is statically typed."))
    }

    func testEmptyAnswerCountsAsNoAnswer() {
        XCTAssertTrue(AssistantPrompt.isEcho(question: "what's a monad", answer: "   "))
    }
}
