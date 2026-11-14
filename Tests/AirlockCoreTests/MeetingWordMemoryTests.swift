import XCTest
@testable import AirlockCore

/// A word answered under "Check these words" is answered the same way in
/// every later call, and only when the question is the same one.
final class MeetingWordMemoryTests: XCTestCase {
    private let ordinary: Set<String> = ["cloud", "code", "clout", "napa"]
    private func isWord(_ word: String) -> Bool { ordinary.contains(word) }

    // MARK: - Remembering

    func testUseIsAnsweredAgainForTheSameWaysOfHearingIt() {
        let memory = MeetingWordMemory().remembering("Claude", heard: ["Claudio", "Cloud"], use: true)
        XCTAssertEqual(memory.answer(for: "Claude", heard: ["Cloud"]), .use("Claude"))
        XCTAssertEqual(memory.answer(for: "claude", heard: ["claudio", "CLOUD"]), .use("Claude"))
    }

    func testANewWayOfHearingItIsStillAsked() {
        let memory = MeetingWordMemory().remembering("Claude", heard: ["Cloud"], use: true)
        XCTAssertNil(memory.answer(for: "Claude", heard: ["Cloud", "Clod"]))
    }

    func testAnotherWordHeardTheSameWayIsStillAsked() {
        let memory = MeetingWordMemory().remembering("Claude", heard: ["Cloud"], use: true)
        XCTAssertNil(memory.answer(for: "Cloudflare", heard: ["Cloud"]))
    }

    func testLeaveItIsRememberedToo() {
        let memory = MeetingWordMemory().remembering("Claude", heard: ["Cloud"], use: false)
        XCTAssertEqual(memory.answer(for: "Claude", heard: ["Cloud"]), .leave)
    }

    func testTypeItIsRememberedUnderTheListedWord() {
        let memory = MeetingWordMemory().remembering("Klod", heard: ["Cloud"], use: true, listed: "Claude")
        XCTAssertEqual(memory.answer(for: "Claude", heard: ["Cloud"]), .use("Klod"))
    }

    func testALaterAnswerReplacesTheEarlierOne() {
        let memory = MeetingWordMemory()
            .remembering("Claude", heard: ["Cloud", "Claudio"], use: false)
            .remembering("Claude", heard: ["Cloud"], use: true)
        XCTAssertEqual(memory.answer(for: "Claude", heard: ["Cloud"]), .use("Claude"))
        XCTAssertEqual(memory.answer(for: "Claude", heard: ["Claudio"]), .leave)
        // The two disagree: asked again.
        XCTAssertNil(memory.answer(for: "Claude", heard: ["Cloud", "Claudio"]))
    }

    func testTheOldestGoFirst() {
        var memory = MeetingWordMemory()
        for index in 0...MeetingWordMemory.most {
            memory = memory.remembering("Word\(index)", heard: ["heard"], use: true)
        }
        XCTAssertEqual(memory.answers.count, MeetingWordMemory.most)
        XCTAssertNil(memory.answer(for: "Word0", heard: ["heard"]))
        XCTAssertNotNil(memory.answer(for: "Word\(MeetingWordMemory.most)", heard: ["heard"]))
    }

    func testItSurvivesBeingSaved() throws {
        let memory = MeetingWordMemory().remembering("Claude", heard: ["Cloud"], use: true)
        let back = try JSONDecoder().decode(MeetingWordMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(back, memory)
    }

    // MARK: - Always write X as Y

    func testSeveralWordsAndNoWordAtAllAreAlwaysWritten() {
        XCTAssertEqual(MeetingWordMemory.alwaysWritten(["Cloud Code", "clout code"], as: "Claude Code",
                                                       isDictionaryWord: isWord),
                       ["Cloud Code", "clout code"])
        XCTAssertEqual(MeetingWordMemory.alwaysWritten(["Claudio", "Cloud"], as: "Claude",
                                                       isDictionaryWord: isWord),
                       ["Claudio"])
    }

    func testFiguresCapitalsAndLongPhrasesAreNotAlwaysWritten() {
        XCTAssertEqual(MeetingWordMemory.alwaysWritten(["forty"], as: "40 €", isDictionaryWord: isWord), [])
        XCTAssertEqual(MeetingWordMemory.alwaysWritten(["claude"], as: "Claude", isDictionaryWord: isWord), [])
        XCTAssertEqual(MeetingWordMemory.alwaysWritten(["the cloud code app"], as: "Claude Code",
                                                       isDictionaryWord: isWord), [])
    }

    /// The pairs it makes do what the person asked in the next call.
    func testAnAlwaysWrittenPairFixesTheNextCall() {
        let heard = MeetingWordMemory.alwaysWritten(["Cloud Code", "Claudio"], as: "Claude Code",
                                                    isDictionaryWord: isWord)
        let words = MeetingKnownWords(typed: [], replacements: heard.map { ($0, "Claude Code") })
        XCTAssertEqual(words.respelled("open cloud code now"), "open Claude Code now")
        XCTAssertEqual(words.respelled("the cloud is up"), "the cloud is up")
    }

    // MARK: - The words on a page

    func testThePageListsItsWords() {
        let page = """
        # Call

        Claude came up.

        ## Check these words

        - **Claude** — heard as “Claudio”, “Cloud” · 0:12
        - **Claude Code** — heard as “Cloud Code” · 1:40

        ## Your notes

        - **Nope** — heard as “nah”
        """
        let listed = MeetingWordCheck.listed(in: page)
        XCTAssertEqual(listed.map(\.best), ["Claude", "Claude Code"])
        XCTAssertEqual(listed.first?.heard, ["Claudio", "Cloud"])
    }
}
