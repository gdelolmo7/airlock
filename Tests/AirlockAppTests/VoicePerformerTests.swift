import XCTest
import AirlockCore
@testable import AirlockApp

/// Every effect a registered action can actually produce must be performed —
/// enforced, not asserted in prose.
///
/// This exists because a comment tried to do the job and failed, the same way
/// `SendableExemptionTests` exists. `VoiceActionCatalog.registered` grew to
/// three actions; the switch in `AppDelegate` still answered `false` for two of
/// them, under a comment that said they were unregistered. Nothing crashed.
/// "Copy the last thing I copied from Figma" quietly became a question, and
/// "tell claude to run the tests" put a card on screen and then said the session
/// had gone away.
///
/// The test drives the REAL path — `VoiceGrammar.match` → `VoiceActionCatalog.propose`
/// → `VoicePerformer.perform` — over the shared `ActionEvaluation` case set, so
/// it fails the moment a registered action produces an effect nobody performs.
@MainActor
final class VoicePerformerTests: XCTestCase {

    /// Effect kinds the app knowingly does not perform, and why.
    ///
    /// The reason travels with the entry so the failure message can carry it:
    /// someone under deadline who sees a bare list deletes the failing line
    /// instead of the gap. Adding an entry here is a product decision, not a way
    /// to make this test green.
    private static let knownGaps: [String: String] = [
        "sendPrompt(to an existing session)": """
            No mechanism, deliberately. `TerminalJumpService` says twice that it \
            will not put text into a session somebody already owns — it opens "a \
            new window on purpose" — so `VoicePerformer.sendToExistingSession` is \
            nil and `AppDelegate` leaves `VoiceContext.agentSessions` empty to \
            match. In the app this effect is therefore unreachable: with no \
            session named, `VoiceAgentAction` always proposes a fresh one. This \
            test reaches it only because `ActionEvaluation.context` names a \
            session, which is what makes the gap visible instead of theoretical.
            """,
    ]

    /// The label used to look a produced effect up in `knownGaps`.
    private static func gapKey(for effect: VoiceEffect) -> String? {
        switch effect {
        case .sendPrompt(let sessionID, _) where sessionID != nil:
            return "sendPrompt(to an existing session)"
        default:
            return nil
        }
    }

    /// A performer whose arms all succeed, so the only way to get `false` is an
    /// arm the app does not have.
    private static func recordingPerformer(into log: Recorder) -> VoicePerformer {
        VoicePerformer(
            copyClipboardItem: { log.copied.append($0); return true },
            selectAudioOutput: { log.selected.append($0); return true },
            startSession: { log.started.append($0); return true },
            runShortcut: { log.ran.append($0); return true },
            setVolume: { log.volume.append($0); return true },
            media: { log.media.append($0); return true },
            open: { log.opened.append(String(describing: $0)); return true })
        // `sendToExistingSession` left nil on purpose — this mirrors the app.
    }

    private final class Recorder {
        var copied: [UUID] = []
        var selected: [String] = []
        var started: [String] = []
        var ran: [String] = []
        var opened: [String] = []
        var volume: [Double] = []
        var media: [VoiceMediaCommand] = []
    }

    // MARK: - The drift catcher

    func testEveryRegisteredActionsEffectIsPerformed() throws {
        let log = Recorder()
        let performer = Self.recordingPerformer(into: log)
        let offering = VoiceActionCatalog.offered(shortcuts: true)
        var reached = 0

        for testCase in ActionEvaluation.cases where testCase.toolName != nil {
            // What the app OFFERS, not `.all` — this is about the set a user
            // can actually reach, which is exactly what drifted. Shortcuts on,
            // because a switched-off action reaching the performer is a
            // different bug and `testItIsNotOfferedWhenSwitchedOff` owns it.
            guard let match = VoiceGrammar.match(testCase.spoken, offering: offering) else {
                XCTFail("no match for \(testCase.spoken) — VoiceGrammarTests covers this, "
                        + "so something upstream broke")
                continue
            }
            guard let proposal = VoiceActionCatalog.propose(
                actionNamed: match.name, arguments: match.arguments,
                in: ActionEvaluation.context, offering: offering) else {
                XCTFail("\(testCase.spoken) matched \(match.name) and resolved to nothing")
                continue
            }

            reached += 1
            let performed = performer.perform(proposal.effect)
            if let key = Self.gapKey(for: proposal.effect) {
                let reason = try XCTUnwrap(
                    Self.knownGaps[key],
                    "\(proposal.toolName) produced \(key), which is unperformed and unexplained")
                XCTAssertFalse(performed, """
                    \(key) is on the known-gaps list but the performer handled it. \
                    If it works now, delete the entry — the list is only useful \
                    while it is true.

                    \(reason)
                    """)
                continue
            }

            XCTAssertTrue(performed, """
                `\(proposal.toolName)` is in `VoiceActionCatalog.registered` and \
                resolved to an effect the app does not perform.

                This is the exact shape of the bug this test exists for: a card \
                appears, the user approves it, and `AssistantModel.carryOut` \
                reports "Couldn't — \(proposal.subject) went away" over an action \
                that was never wired up.

                Add the arm to `VoicePerformer` and supply it in `AppDelegate`. \
                Only add a `knownGaps` entry if not performing it is a deliberate \
                product decision, and say why.
                """)
        }

        XCTAssertGreaterThan(reached, 0, "the walk reached no proposals — this test has stopped working")

        // Anti-vacuity. Without these the test would still pass if an action
        // stopped producing the effect it is for — every arm returns true, so
        // "nothing failed" is also what "nothing happened" looks like.
        XCTAssertFalse(log.copied.isEmpty,
                       "no case reached the clipboard arm — `VoiceClipboardAction` has stopped "
                       + "producing `.copyClipboardItem`, or left `registered`")
        XCTAssertFalse(log.selected.isEmpty,
                       "no case reached the audio arm — `VoiceAudioOutputAction` has stopped "
                       + "producing `.selectAudioOutput`, or left `registered`")
        XCTAssertFalse(log.ran.isEmpty,
                       "no case reached the Shortcuts arm — `VoiceShortcutAction` has stopped "
                       + "producing `.runShortcut`, or left `offered(shortcuts: true)`")
        XCTAssertFalse(log.opened.isEmpty,
                       "no case reached the open arm — `VoiceOpenAction` has stopped "
                       + "producing `.open`, or left the offered list")
        // `startSession` is deliberately NOT asserted: `ActionEvaluation.context`
        // names a session, so every agent case here resolves to the known gap
        // above. `testANilSessionStartsAFreshOne` covers the arm the app
        // actually reaches.
        XCTAssertTrue(log.started.isEmpty,
                      "an agent case started a fresh session while the fixture named one — "
                      + "that is the near-miss `VoicePerformer` exists to prevent")
    }

    /// A gap that has been closed must leave the list, or the list stops
    /// describing reality and starts excusing it.
    func testKnownGapsAreStillReachable() {
        let produced = ActionEvaluation.cases
            .filter { $0.toolName != nil }
            .compactMap {
                VoiceGrammar.match($0.spoken,
                                   offering: VoiceActionCatalog.offered(shortcuts: true))
            }
            .compactMap {
                VoiceActionCatalog.propose(actionNamed: $0.name, arguments: $0.arguments,
                                           in: ActionEvaluation.context,
                                           offering: VoiceActionCatalog.offered(shortcuts: true))
            }
            .compactMap { Self.gapKey(for: $0.effect) }

        let stale = Self.knownGaps.keys.filter { !produced.contains($0) }.sorted()
        XCTAssertTrue(stale.isEmpty,
                      "known-gap entries no action produces any more: "
                      + "\(stale.joined(separator: ", ")) — delete them")
    }

    // MARK: - The arms themselves

    func testANilSessionStartsAFreshOne() {
        let log = Recorder()
        let performer = Self.recordingPerformer(into: log)

        XCTAssertTrue(performer.perform(.sendPrompt(sessionID: nil, text: "run the tests")))
        XCTAssertEqual(log.started, ["run the tests"])
    }

    /// The card must not say "done" over nothing happening — every arm reports
    /// its own failure rather than swallowing it.
    func testAMissingSubjectIsReportedRatherThanClaimed() {
        let performer = VoicePerformer(
            copyClipboardItem: { _ in false },
            selectAudioOutput: { _ in false },
            startSession: { _ in false },
            runShortcut: { _ in false },
            setVolume: { _ in false },
            media: { _ in false },
            open: { _ in false })

        XCTAssertFalse(performer.perform(.copyClipboardItem(id: UUID())))
        XCTAssertFalse(performer.perform(.selectAudioOutput(uid: "gone")))
        XCTAssertFalse(performer.perform(.sendPrompt(sessionID: nil, text: "x")))
    }

    func testAnUnreachableSessionRefusesRatherThanStartingSomethingElse() {
        let log = Recorder()
        let performer = Self.recordingPerformer(into: log)

        // The dangerous near-miss: falling back to `startSession` here would
        // open an unrelated new terminal while the card said "Ask airlock".
        XCTAssertFalse(performer.perform(.sendPrompt(sessionID: "s1", text: "run the tests")))
        XCTAssertTrue(log.started.isEmpty)
    }
}
