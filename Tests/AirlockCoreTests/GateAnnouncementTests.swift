import XCTest
@testable import AirlockCore

final class GateAnnouncementTests: XCTestCase {
    private func request(
        summary: String = "Run shell command",
        command: String? = nil,
        question: QuestionPrompt? = nil
    ) -> PermissionRequest {
        PermissionRequest(id: "r1", toolName: "Bash", summary: summary,
                          command: command, question: question, createdAt: Date())
    }

    // MARK: - Shape

    func testPermissionNamesAgentAndSummary() {
        let text = GateAnnouncement.text(agent: "Claude Code", request: request(),
                                         risk: nil, hotkey: nil)
        XCTAssertEqual(text, "Claude Code needs permission: Run shell command.")
    }

    func testQuestionIsSpokenAsAQuestion() {
        let prompt = QuestionPrompt(question: "Which database first?", options: [])
        let text = GateAnnouncement.text(agent: "Claude Code",
                                         request: request(question: prompt),
                                         risk: nil, hotkey: nil)
        XCTAssertEqual(text, "Claude Code asks: Which database first?")
    }

    /// The card steps through them, and "1 of 2" is drawn, not spoken.
    func testSeveralQuestionsAreCounted() {
        var gate = request()
        gate.questions = [QuestionPrompt(question: "Which auth method?", options: []),
                          QuestionPrompt(question: "Which database?", options: [])]
        let text = GateAnnouncement.text(agent: "Claude Code", request: gate, risk: nil, hotkey: nil)
        XCTAssertEqual(text, "Claude Code asks 2 questions, starting with: Which auth method?")
    }

    /// A synthesiser runs the next clause straight on without it.
    func testSentenceIsTerminated() {
        let text = GateAnnouncement.text(agent: "Codex", request: request(summary: "Edit main.swift"),
                                         risk: nil, hotkey: nil)
        XCTAssertTrue(text.hasSuffix("."))
    }

    func testExistingTerminatorIsNotDoubled() {
        let prompt = QuestionPrompt(question: "Proceed?", options: [])
        let text = GateAnnouncement.text(agent: "Codex", request: request(question: prompt),
                                         risk: nil, hotkey: nil)
        XCTAssertFalse(text.contains("?."))
    }

    // MARK: - Risk

    /// The card signals risk with a coloured dot and nothing else. If this is
    /// dropped, a listener approves `rm -rf` in the same tone as a file read.
    func testRiskIsSpoken() {
        let text = GateAnnouncement.text(
            agent: "Claude Code", request: request(),
            risk: RiskAssessor.Risk(reason: "recursive delete"), hotkey: nil)
        XCTAssertTrue(text.contains("Risky — recursive delete."), text)
    }

    func testNoRiskAddsNothing() {
        let text = GateAnnouncement.text(agent: "Claude Code", request: request(),
                                         risk: nil, hotkey: nil)
        XCTAssertFalse(text.contains("Risky"))
    }

    // MARK: - Hotkey

    func testHotkeyIsSpokenSoTheGateCanBeReached() {
        let text = GateAnnouncement.text(agent: "Claude Code", request: request(),
                                         risk: nil, hotkey: "Control-Option-Command-A")
        XCTAssertTrue(text.hasSuffix("Press Control-Option-Command-A to answer."), text)
    }

    /// Promising a shortcut that is switched off would be worse than silence.
    func testNoHotkeyPromisesNothing() {
        let text = GateAnnouncement.text(agent: "Claude Code", request: request(),
                                         risk: nil, hotkey: nil)
        XCTAssertFalse(text.contains("Press"))
    }

    // MARK: - Clamping

    func testLongDetailIsTruncatedOnAWordBoundary() {
        let long = String(repeating: "delete everything ", count: 40)
        let text = GateAnnouncement.text(agent: "Claude Code", request: request(summary: long),
                                         risk: nil, hotkey: nil)
        XCTAssertTrue(text.contains("…"), text)
        XCTAssertLessThan(text.count, 160, "a listener should not wait out a wall of speech")
        XCTAssertFalse(text.contains("everyth…"), "should cut between words")
    }

    /// A path or URL longer than the limit has no space to back up to.
    func testUnbrokenTokenStillTruncates() {
        let path = "/" + String(repeating: "a", count: 300)
        let text = GateAnnouncement.text(agent: "Claude Code", request: request(summary: path),
                                         risk: nil, hotkey: nil)
        XCTAssertTrue(text.contains("…"))
        XCTAssertLessThan(text.count, 160)
    }

    /// Diffs and wrapped commands arrive full of newlines, which become pauses.
    func testWhitespaceIsCollapsed() {
        let text = GateAnnouncement.text(
            agent: "Claude Code",
            request: request(summary: "Run\n\n  git   push\n--force"),
            risk: nil, hotkey: nil)
        XCTAssertEqual(text, "Claude Code needs permission: Run git push --force.")
    }

    func testShortDetailIsUntouched() {
        let text = GateAnnouncement.text(agent: "Claude Code", request: request(summary: "Read README"),
                                         risk: nil, hotkey: nil)
        XCTAssertFalse(text.contains("…"))
    }

    // MARK: - Together

    func testFullSentenceOrdersWhatThenRiskThenKey() {
        let text = GateAnnouncement.text(
            agent: "Claude Code", request: request(summary: "Run shell command"),
            risk: RiskAssessor.Risk(reason: "elevated privileges"),
            hotkey: "Control-Option-Command-A")
        XCTAssertEqual(text, "Claude Code needs permission: Run shell command. "
                       + "Risky — elevated privileges. Press Control-Option-Command-A to answer.")
    }
}
