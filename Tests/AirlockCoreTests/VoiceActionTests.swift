import XCTest
@testable import AirlockCore

/// The resolution layer: a half-heard phrase against the things that exist.
///
/// Heavy on the nil cases on purpose. A 3B model asked to fill in a struct will
/// name a device you do not own and a session that is not running, so "returns
/// nothing" is the common path, not the edge — and a card that promises
/// something impossible is worse than no card at all.
final class VoiceActionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func clip(_ text: String, app: String? = nil) -> ClipboardItem {
        ClipboardItem(payload: .text(text), fingerprint: text, copiedAt: epoch,
                      sourceAppName: app)
    }

    private func image(app: String? = nil) -> ClipboardItem {
        ClipboardItem(payload: .image(file: "a.png", width: 10, height: 10),
                      fingerprint: "img", copiedAt: epoch, sourceAppName: app)
    }

    // MARK: - VoiceMatch

    func testFoldIgnoresCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(VoiceMatch.fold("AirPods Pro,"), "airpods pro")
        XCTAssertEqual(VoiceMatch.fold("Café  —  Münster"), "cafe munster")
        XCTAssertEqual(VoiceMatch.fold("  \n hello \t world "), "hello world")
        XCTAssertEqual(VoiceMatch.fold("!!!"), "")
    }

    func testUniquePrefersExactThenPrefixThenContains() {
        let names = ["AirPods Pro", "AirPods Pro Max", "MacBook Pro Speakers"]
        XCTAssertEqual(VoiceMatch.unique("airpods pro max", in: names, name: { $0 }),
                       "AirPods Pro Max")
        // "airpods" prefixes exactly two, so it is ambiguous, not a win for the
        // first one declared.
        XCTAssertNil(VoiceMatch.unique("airpods", in: names, name: { $0 }))
        XCTAssertEqual(VoiceMatch.unique("macbook", in: names, name: { $0 }),
                       "MacBook Pro Speakers")
    }

    func testUniqueMatchesNameInsideASpokenPhrase() {
        let names = ["Kitchen TV", "Studio Display"]
        XCTAssertEqual(VoiceMatch.unique("put it on the studio display please",
                                         in: names, name: { $0 }), "Studio Display")
    }

    func testUniqueRefusesShortNamesInsideAPhrase() {
        // "Mac" is three characters: any sentence mentioning a Mac would select
        // it. See `VoiceMatch.minimumContainedNameLength`.
        XCTAssertNil(VoiceMatch.unique("send the sound to my mac mini speakers",
                                       in: ["Mac"], name: { $0 }))
    }

    func testUniqueOnEmptyInputs() {
        XCTAssertNil(VoiceMatch.unique("", in: ["A"], name: { $0 }))
        XCTAssertNil(VoiceMatch.unique("a", in: [String](), name: { $0 }))
    }

    func testOrdinals() {
        XCTAssertEqual(VoiceMatch.ordinal("3"), 3)
        XCTAssertEqual(VoiceMatch.ordinal("3rd"), 3)
        XCTAssertEqual(VoiceMatch.ordinal("the second one"), 2)
        XCTAssertEqual(VoiceMatch.ordinal("tenth"), 10)
        XCTAssertNil(VoiceMatch.ordinal("figma"))
        XCTAssertNil(VoiceMatch.ordinal(""))
        // "last" is deliberately unsupported — its meaning depends on the list.
        XCTAssertNil(VoiceMatch.ordinal("last"))
        // A sign is not read, because `fold` strips punctuation out of a raw
        // transcript before anything looks at it. Recorded rather than fixed: no
        // model emits a negative position, and a special case in the shared
        // helper would cost more than it protects.
        XCTAssertEqual(VoiceMatch.ordinal("-2"), 2)
    }

    // MARK: - Clipboard

    func testClipboardEmptyHistoryProposesNothing() {
        XCTAssertNil(VoiceClipboardAction.propose(["query": "figma"], in: VoiceContext()))
    }

    func testClipboardWithNoArgumentsTakesTheNewest() {
        let context = VoiceContext(clipboard: [clip("newest", app: "Figma"), clip("older")])
        let proposal = VoiceClipboardAction.propose([:], in: context)
        XCTAssertEqual(proposal?.effect, .copyClipboardItem(id: context.clipboard[0].id))
    }

    func testClipboardMatchesSourceApp() {
        let context = VoiceContext(clipboard: [
            clip("a note", app: "Notes"), clip("a frame", app: "Figma"),
        ])
        let proposal = VoiceClipboardAction.propose(["query": "Figma"], in: context)
        XCTAssertEqual(proposal?.effect, .copyClipboardItem(id: context.clipboard[1].id))
        XCTAssertEqual(proposal?.subject, "Figma")
    }

    func testClipboardMatchesContentAndPrefersTheNewest() {
        let context = VoiceContext(clipboard: [
            clip("the newer invoice"), clip("the older invoice"),
        ])
        let proposal = VoiceClipboardAction.propose(["query": "invoice"], in: context)
        XCTAssertEqual(proposal?.effect, .copyClipboardItem(id: context.clipboard[0].id))
    }

    /// The one that matters: a query that matches nothing must NOT fall back to
    /// the newest entry, or asking for a Figma frame silently copies a password.
    func testClipboardMissedQueryProposesNothing() {
        let context = VoiceContext(clipboard: [clip("a note", app: "Notes")])
        XCTAssertNil(VoiceClipboardAction.propose(["query": "figma"], in: context))
    }

    func testClipboardIndex() {
        let context = VoiceContext(clipboard: [clip("one"), clip("two"), clip("three")])
        XCTAssertEqual(VoiceClipboardAction.propose(["index": "2"], in: context)?.effect,
                       .copyClipboardItem(id: context.clipboard[1].id))
        XCTAssertEqual(VoiceClipboardAction.propose(["index": "third"], in: context)?.effect,
                       .copyClipboardItem(id: context.clipboard[2].id))
        XCTAssertNil(VoiceClipboardAction.propose(["index": "9"], in: context))
    }

    /// A stated index that does not parse must not become "the newest entry".
    /// `"0"` is what a model produces for "the last one"; `"banana"` is what it
    /// produces when it has misheard entirely.
    func testClipboardUnparseableIndexProposesNothing() {
        let context = VoiceContext(clipboard: [clip("one"), clip("two")])
        XCTAssertNil(VoiceClipboardAction.propose(["index": "0"], in: context))
        XCTAssertNil(VoiceClipboardAction.propose(["index": "banana"], in: context))

        // A blank argument is an ABSENT one, not a garbled one — models emit
        // empty strings for fields they had nothing to put in — so this is the
        // "nothing was specified" path and takes the newest entry.
        XCTAssertEqual(VoiceClipboardAction.propose(["index": "  "], in: context)?.effect,
                       .copyClipboardItem(id: context.clipboard[0].id))
    }

    func testClipboardTextSearchWinsOverAnOrdinalReadingOfTheSameWords() {
        let context = VoiceContext(clipboard: [clip("cover letter"), clip("second draft")])
        // "second draft" is a phrase that is present, not a jump to row two.
        XCTAssertEqual(
            VoiceClipboardAction.propose(["query": "second draft"], in: context)?.effect,
            .copyClipboardItem(id: context.clipboard[1].id))
    }

    func testClipboardOrdinalArrivingInTheQueryField() {
        // The model puts everything in one field often enough to handle.
        let context = VoiceContext(clipboard: [clip("one"), clip("two")])
        XCTAssertEqual(VoiceClipboardAction.propose(["query": "the second one"], in: context)?.effect,
                       .copyClipboardItem(id: context.clipboard[1].id))
    }

    func testClipboardSubjectFallsBackWhenTheAppIsUnknown() {
        XCTAssertEqual(
            VoiceClipboardAction.propose([:], in: VoiceContext(clipboard: [clip("x")]))?.subject,
            "Text")
        XCTAssertEqual(
            VoiceClipboardAction.propose([:], in: VoiceContext(clipboard: [image()]))?.subject,
            "Image")
    }

    func testShortContentIsQuotedInlineWithNoDetail() {
        let proposal = VoiceClipboardAction.propose(
            [:], in: VoiceContext(clipboard: [clip("npm run build", app: "Xcode")]))
        XCTAssertEqual(proposal?.summary, "Copy “npm run build” from Xcode")
        XCTAssertNil(proposal?.detail, "short content needs no second line")
    }

    /// The card must never say the same thing twice.
    ///
    /// It did: a long instruction appeared truncated in the summary AND in full
    /// in the detail directly beneath it, which reads as a bug rather than as
    /// thoroughness. Caught by rendering the card and looking at it — no test
    /// asked the question until one had.
    func testLongContentAppearsOnceInTheDetailAndNotAlsoInTheSummary() {
        let long = "fix the failing test in VoiceGrammarTests and then commit it "
            + "with a message explaining why the interrogative list needed a word"

        let clip = VoiceClipboardAction.propose(
            [:], in: VoiceContext(clipboard: [self.clip(long, app: "Xcode")]))
        XCTAssertEqual(clip?.summary, "Copy this from Xcode")
        XCTAssertEqual(clip?.detail, long)

        let agent = VoiceAgentAction.propose(["prompt": long], in: VoiceContext())
        XCTAssertEqual(agent?.summary, "Start a new session")
        XCTAssertEqual(agent?.detail, long)

        for proposal in [clip, agent].compactMap({ $0 }) {
            let opening = String(long.prefix(20))
            XCTAssertFalse(proposal.summary.contains(opening),
                           "\(proposal.toolName) repeats its detail in the summary")
        }
    }

    // MARK: - Audio output

    private let outputs = [
        AudioOutputDevice(uid: "u1", name: "MacBook Pro Speakers"),
        AudioOutputDevice(uid: "u2", name: "AirPods Pro"),
        AudioOutputDevice(uid: "u3", name: "Studio Display"),
    ]

    func testAudioOutputResolvesAPartialName() {
        let proposal = VoiceAudioOutputAction.propose(["device": "airpods"],
                                                      in: VoiceContext(audioOutputs: outputs))
        XCTAssertEqual(proposal?.effect, .selectAudioOutput(uid: "u2"))
        XCTAssertEqual(proposal?.subject, "AirPods Pro")
        XCTAssertEqual(proposal?.summary, "Send sound to AirPods Pro")
    }

    func testAudioOutputAmbiguityProposesNothing() {
        let both = [AudioOutputDevice(uid: "a", name: "AirPods Pro"),
                    AudioOutputDevice(uid: "b", name: "AirPods Pro Max")]
        XCTAssertNil(VoiceAudioOutputAction.propose(["device": "airpods"],
                                                    in: VoiceContext(audioOutputs: both)))
    }

    func testAudioOutputUnknownOrMissingProposesNothing() {
        let context = VoiceContext(audioOutputs: outputs)
        XCTAssertNil(VoiceAudioOutputAction.propose(["device": "sonos"], in: context))
        XCTAssertNil(VoiceAudioOutputAction.propose(["device": ""], in: context))
        XCTAssertNil(VoiceAudioOutputAction.propose([:], in: context))
    }

    // MARK: - Agent

    private let sessions = [
        VoiceAgentTarget(sessionID: "s1", label: "airlock"),
        VoiceAgentTarget(sessionID: "s2", label: "worker"),
    ]

    func testAgentNeedsAPrompt() {
        XCTAssertNil(VoiceAgentAction.propose([:], in: VoiceContext()))
        XCTAssertNil(VoiceAgentAction.propose(["prompt": "   "], in: VoiceContext()))
    }

    func testAgentWithNoSessionsStartsAFreshOne() {
        let proposal = VoiceAgentAction.propose(["prompt": "run the tests"], in: VoiceContext())
        XCTAssertEqual(proposal?.effect, .sendPrompt(sessionID: nil, text: "run the tests"))
        XCTAssertEqual(proposal?.subject, "new session")
    }

    func testAgentWithOneSessionNeedsNoNaming() {
        let context = VoiceContext(agentSessions: [sessions[0]])
        let proposal = VoiceAgentAction.propose(["prompt": "run the tests"], in: context)
        XCTAssertEqual(proposal?.effect, .sendPrompt(sessionID: "s1", text: "run the tests"))
    }

    /// Several running and none named. Guessing would send an instruction to the
    /// wrong checkout, which is the one outcome here that is hard to undo.
    func testAgentWithSeveralSessionsAndNoNameProposesNothing() {
        let context = VoiceContext(agentSessions: sessions)
        XCTAssertNil(VoiceAgentAction.propose(["prompt": "run the tests"], in: context))
    }

    func testAgentNamedSession() {
        let context = VoiceContext(agentSessions: sessions)
        XCTAssertEqual(
            VoiceAgentAction.propose(["prompt": "ship it", "session": "worker"], in: context)?.effect,
            .sendPrompt(sessionID: "s2", text: "ship it"))
        // Named something that is not running: the command does not exist.
        XCTAssertNil(VoiceAgentAction.propose(["prompt": "ship it", "session": "website"],
                                              in: context))
    }

    func testAgentCanNeverBeAutoApproved() {
        XCTAssertNotNil(VoiceAgentAction.riskFloorReason)
        XCTAssertNil(VoiceClipboardAction.riskFloorReason)
        XCTAssertNil(VoiceAudioOutputAction.riskFloorReason)
    }
}
