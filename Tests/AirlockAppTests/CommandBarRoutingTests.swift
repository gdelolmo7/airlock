import XCTest
import AirlockCore
@testable import AirlockApp

/// What typing at the notch does, as distinct from speaking at it.
///
/// `AIRLOCK_POLICY_HOME` is redirected in `setUp` because `AssistantModel.propose`
/// reaches the real `PolicyEngine`, which reads `~/.airlock/policy.yaml`. Without
/// it these tests would be scored against whatever rules the developer happens to
/// have written, and the Always assertions could write to them.
@MainActor
final class CommandBarRoutingTests: XCTestCase {
    private var policyHome: URL!

    override func setUp() {
        super.setUp()
        policyHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commandbar-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: policyHome, withIntermediateDirectories: true)
        setenv("AIRLOCK_POLICY_HOME", policyHome.path, 1)
    }

    override func tearDown() {
        unsetenv("AIRLOCK_POLICY_HOME")
        try? FileManager.default.removeItem(at: policyHome)
        super.tearDown()
    }

    /// One audio device, so "put the sound on the airpods" resolves.
    private func model() -> AssistantModel {
        let assistant = AssistantModel()
        assistant.contextProvider = {
            VoiceContext(audioOutputs: [AudioOutputDevice(uid: "u2", name: "AirPods Pro")])
        }
        assistant.onPerform = { _ in true }
        return assistant
    }

    // MARK: - Which switch gates which channel

    /// The two consents are separate. Someone who left spoken actions off said
    /// something about their microphone, not about a bar they turned on.
    func testTypingActsOnItsOwnSwitchNotTheMicrophoneOne() {
        let assistant = model()
        assistant.actionsEnabled = false
        assistant.commandBarEnabled = true

        assistant.commandText = "put the sound on the airpods"
        assistant.submitCommand()

        XCTAssertNotNil(assistant.pending, "a typed command was gated by the microphone switch")
        XCTAssertEqual(assistant.pending?.proposal.subject, "AirPods Pro")
    }

    /// And the reverse: the bar's switch must not quietly enable spoken actions.
    func testTheBarSwitchDoesNotEnableSpokenActions() {
        let assistant = model()
        assistant.actionsEnabled = false
        assistant.commandBarEnabled = true

        assistant.ask("put the sound on the airpods")

        XCTAssertNil(assistant.pending, "the bar's switch let a spoken phrase act")
    }

    // MARK: - Provenance

    /// A `Voice.` rule claims a microphone on its face, so a keyboard may not
    /// write one — see `VoiceAction.toolName`.
    func testTypingIsNeverOfferedAlways() throws {
        let assistant = model()
        assistant.commandBarEnabled = true
        assistant.commandText = "put the sound on the airpods"
        assistant.submitCommand()

        let pending = try XCTUnwrap(assistant.pending)
        guard case .ask(let risk, let always) = pending.outcome else { return XCTFail("expected ask") }
        XCTAssertNil(risk)
        XCTAssertNil(always, "the bar offered a rule claiming spoken provenance")
    }

    /// The spoken path is untouched by all of this.
    func testSpeakingStillGetsAlways() throws {
        let assistant = model()
        assistant.actionsEnabled = true
        assistant.ask("put the sound on the airpods")

        let pending = try XCTUnwrap(assistant.pending)
        guard case .ask(_, let always) = pending.outcome else { return XCTFail("expected ask") }
        XCTAssertNotNil(always)
    }

    // MARK: - Routing

    /// An unrecognised line is ANSWERED, exactly as a spoken question is. It must
    /// not fall through to `submitQuickPrompt` — opening a terminal because the
    /// grammar did not recognise something is a different product.
    func testAnUnrecognisedLineIsNotAnAction() {
        let assistant = model()
        assistant.commandBarEnabled = true
        assistant.commandText = "what is the capital of France"
        assistant.submitCommand()

        XCTAssertNil(assistant.pending, "a question became a card")
        XCTAssertTrue(assistant.isPresenting, "the question left no trace on screen")
    }

    /// The bar stands aside once it has handed something over — the panel is a
    /// narrow strip and the card is the thing to read.
    func testSubmittingClosesTheBar() {
        let assistant = model()
        assistant.commandBarEnabled = true
        assistant.openCommandBar()
        XCTAssertTrue(assistant.isCommandBarOpen)

        assistant.commandText = "put the sound on the airpods"
        assistant.submitCommand()

        XCTAssertFalse(assistant.isCommandBarOpen)
        XCTAssertEqual(assistant.commandText, "")
    }

    /// Enter on an empty field closes rather than asking nothing.
    func testEmptySubmitJustCloses() {
        let assistant = model()
        assistant.commandBarEnabled = true
        assistant.openCommandBar()

        assistant.commandText = "   "
        assistant.submitCommand()

        XCTAssertFalse(assistant.isCommandBarOpen)
        XCTAssertFalse(assistant.isPresenting, "an empty line put something on screen")
    }

    /// The switch is load-bearing, not decorative: off means the bar cannot be
    /// summoned at all, including by a hotkey that outlived the toggle.
    func testTheBarCannotBeOpenedWhileSwitchedOff() {
        let assistant = model()
        assistant.commandBarEnabled = false
        assistant.openCommandBar()
        XCTAssertFalse(assistant.isCommandBarOpen)
    }

    // MARK: - Escape

    /// The ladder, driven through the model rather than the pure enum: a card
    /// first, then the text, then the bar.
    func testEscapeWalksTheLadder() {
        let assistant = model()
        assistant.commandBarEnabled = true
        assistant.openCommandBar()
        assistant.commandText = "put the sound"

        XCTAssertTrue(assistant.handleEscape())
        XCTAssertEqual(assistant.commandText, "", "first Escape should clear the text")
        XCTAssertTrue(assistant.isCommandBarOpen, "first Escape should not also close the bar")

        XCTAssertTrue(assistant.handleEscape())
        XCTAssertFalse(assistant.isCommandBarOpen, "second Escape should close the bar")

        XCTAssertFalse(assistant.handleEscape(), "a third Escape is not ours to swallow")
    }

    /// An unanswered proposal is dropped, never performed.
    func testEscapeOnACardDropsItWithoutPerforming() {
        let assistant = model()
        assistant.commandBarEnabled = true
        var performed = 0
        assistant.onPerform = { _ in performed += 1; return true }

        assistant.commandText = "put the sound on the airpods"
        assistant.submitCommand()
        XCTAssertNotNil(assistant.pending)

        XCTAssertTrue(assistant.handleEscape())
        XCTAssertNil(assistant.pending)
        XCTAssertEqual(performed, 0, "Escape performed the action it was dismissing")
    }
}
