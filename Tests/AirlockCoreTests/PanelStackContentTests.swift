import XCTest
@testable import AirlockCore

/// The panel's widget region, and who is allowed to take it away.
///
/// THE BUG THIS EXISTS FOR: the region used to be dropped on
/// `assistant.isPresenting` alone, so a permission gate arriving while an answer
/// was on screen was not drawn at all — not by the panel, and not by the gate
/// hotkey either, which selects the Agents tab that was suppressed with
/// everything else. The agent sat blocked for the answer's whole 45-second idle
/// timeout. That contradicts `NotchWidget.demandsAttention`, which promises a
/// blocking widget is shown whatever else is switched off.
final class PanelStackContentTests: XCTestCase {

    // MARK: - In-panel setup

    /// The wizard replaces the tab rather than sitting on it. The panel's
    /// height budget does not stretch to a five-step guide AND nine widgets,
    /// and the widgets are what the guide is explaining.
    func testSetupTakesTheTab() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, answering: false,
                                      demandsAttention: false, onboarding: true),
            .none)
    }

    /// The same safety rule the answer case exists for, now that setup is
    /// another thing that can own the panel: an agent stopped behind a
    /// permission gate must not be invisible behind a wizard either.
    func testABlockingGateIsDrawnEvenDuringSetup() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, answering: false,
                                      demandsAttention: true, onboarding: true),
            .attentionOnly,
            "an agent waiting must not be invisible behind first-run setup")
    }

    /// Setup outranks the other two claimants. Both are reachable from inside
    /// it — the features step names the hold key and invites you to press it —
    /// and the tab must not reappear underneath the wizard when you do.
    func testSetupOutranksDictationAndAnswers() {
        for dictating in [true, false] {
            for answering in [true, false] {
                XCTAssertNotEqual(
                    PanelStackContent.resolve(dictating: dictating, answering: answering,
                                              demandsAttention: false, onboarding: true),
                    .tab,
                    "dictating=\(dictating) answering=\(answering)")
            }
        }
    }

    /// And the default keeps every existing caller honest: omitting the flag
    /// must mean "not onboarding", not "onboarding".
    func testTheFlagDefaultsToOff() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, answering: false, demandsAttention: false),
            PanelStackContent.resolve(dictating: false, answering: false,
                                      demandsAttention: false, onboarding: false))
    }
    /// THE regression. An answer owns the panel; a gate outranks it.
    func testABlockingGateIsDrawnEvenWhileAnAnswerOwnsThePanel() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, answering: true, demandsAttention: true),
            .attentionOnly,
            "an agent waiting on an answer must not be invisible behind one")
    }

    /// And the other half of the same fix: the answer is not destroyed to make
    /// room for the gate. `.attentionOnly` is a share of the panel, not a
    /// replacement — deleting somebody's answer because an unrelated agent hit a
    /// permission check is a worse bug than the one being fixed.
    func testTheGateNarrowsTheRegionRatherThanTakingTheWholePanel() {
        let content = PanelStackContent.resolve(dictating: false, answering: true,
                                                demandsAttention: true)
        XCTAssertNotEqual(content, .tab, "the whole tab under an answer is what was too tall")
        XCTAssertNotEqual(content, .none, "and dropping it is what hid the gate")
    }

    /// The layout reason the region is dropped rather than emptied: an empty
    /// ScrollView is greedy and claims the whole budget, which measured as a
    /// two-line answer over a screen of black.
    func testAnAnswerWithNothingBlockingStillDropsTheRegion() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, answering: false, demandsAttention: false),
            .tab)
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, answering: true, demandsAttention: false),
            .none)
    }

    /// Dictation is the deliberate exception — a key is physically held and the
    /// transcript is the gesture's only feedback. Nothing is lost: releasing the
    /// key sets `isPresenting` synchronously, so the next evaluation is the
    /// `answering` row above and the card appears.
    func testAHeldDictationKeyStillOwnsThePanelOutright() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: true, answering: false, demandsAttention: true),
            .none,
            "the panel is the transcript and nothing else, not an emptied tab")
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: true, answering: true, demandsAttention: true),
            .none,
            "an answer from a previous question does not get to reappear mid-hold")
    }

    /// Nothing claiming the panel means the whole tab, blocking or not.
    func testTheUninterruptedPanelDrawsTheWholeTab() {
        for attention in [true, false] {
            XCTAssertEqual(
                PanelStackContent.resolve(dictating: false, answering: false,
                                          demandsAttention: attention),
                .tab)
        }
    }

    /// A guide takes the panel the way setup does, and yields to a gate the
    /// same way.
    func testAGuideTakesThePanelButNotFromAGate() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, answering: false,
                                                 demandsAttention: false, guiding: true), .none)
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, answering: false,
                                                 demandsAttention: true, guiding: true), .attentionOnly)
    }

    // MARK: - The typing bar

    /// ⌥Space opens a text field, not the Home tab with a text field under it.
    func testTheTypingBarOpensAnEmptyNotch() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, answering: false,
                                                 demandsAttention: false, typing: true), .none)
    }

    /// The safety rule holds here too: a waiting agent is never hidden.
    func testABlockingGateIsDrawnUnderTheTypingBar() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, answering: false,
                                                 demandsAttention: true, typing: true), .attentionOnly)
    }

    /// The bar never shows while a key is held, so dictation keeps its own rule.
    func testDictationOutranksTheTypingBar() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: true, answering: false,
                                                 demandsAttention: false, typing: true),
                       PanelStackContent.resolve(dictating: true, answering: false,
                                                 demandsAttention: false))
    }

    // MARK: - A question opened the panel

    /// The owner's call (2026-10-01): when the panel opened because an agent is
    /// asking, it shows the question and nothing else from the tab.
    func testAQuestionThatOpenedThePanelIsAllItShows() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, answering: false,
                                                 demandsAttention: true, askingYou: true),
                       .attentionOnly)
    }

    /// Opening the tab yourself while something waits still draws all of it.
    func testATabYouOpenedYourselfIsDrawnWhole() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, answering: false,
                                                 demandsAttention: true, askingYou: false),
                       .tab)
    }

    /// The flag outliving its gate for one evaluation must cost a full tab,
    /// never an empty panel.
    func testAnAnsweredQuestionGivesTheTabBack() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, answering: false,
                                                 demandsAttention: false, askingYou: true),
                       .tab)
    }

    /// The claimants that already own the panel keep it: dictation is a key
    /// physically held, and setup, the guide, an answer and the typing bar
    /// already draw the gate on their own terms.
    func testAskingYouChangesNothingElseOwnsThePanel() {
        for attention in [true, false] {
            for (dictating, answering, onboarding, guiding, typing) in [
                (true, false, false, false, false), (false, true, false, false, false),
                (false, false, true, false, false), (false, false, false, true, false),
                (false, false, false, false, true),
            ] {
                XCTAssertEqual(
                    PanelStackContent.resolve(dictating: dictating, answering: answering,
                                              demandsAttention: attention, onboarding: onboarding,
                                              guiding: guiding, typing: typing, askingYou: true),
                    PanelStackContent.resolve(dictating: dictating, answering: answering,
                                              demandsAttention: attention, onboarding: onboarding,
                                              guiding: guiding, typing: typing),
                    "attention=\(attention) d=\(dictating) a=\(answering) o=\(onboarding) g=\(guiding) t=\(typing)")
            }
        }
    }
}
