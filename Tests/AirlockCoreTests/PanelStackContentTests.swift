import XCTest
@testable import AirlockCore

/// The panel's widget region, and who is allowed to take it away.
///
/// THE BUG THIS EXISTS FOR: the region used to be dropped whenever something
/// else owned the panel, so a permission gate arriving then was not drawn at
/// all — not by the panel, and not by the gate hotkey either, which selects
/// the Agents tab that was suppressed with everything else. The agent sat
/// blocked until its timeout. That contradicts `NotchWidget.demandsAttention`,
/// which promises a blocking widget is shown whatever else is switched off.
final class PanelStackContentTests: XCTestCase {

    // MARK: - In-panel setup

    /// The wizard replaces the tab rather than sitting on it. The panel's
    /// height budget does not stretch to a five-step guide AND nine widgets,
    /// and the widgets are what the guide is explaining.
    func testSetupTakesTheTab() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, demandsAttention: false, onboarding: true),
            .none)
    }

    /// An agent stopped behind a permission gate must not be invisible behind
    /// a wizard.
    func testABlockingGateIsDrawnEvenDuringSetup() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, demandsAttention: true, onboarding: true),
            .attentionOnly,
            "an agent waiting must not be invisible behind first-run setup")
    }

    /// Setup outranks dictation. The features step names the hold key and
    /// invites you to press it, and the tab must not reappear underneath the
    /// wizard when you do.
    func testSetupOutranksDictation() {
        XCTAssertNotEqual(
            PanelStackContent.resolve(dictating: true, demandsAttention: false, onboarding: true),
            .tab)
    }

    /// And the default keeps every existing caller honest: omitting the flag
    /// must mean "not onboarding", not "onboarding".
    func testTheFlagDefaultsToOff() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, demandsAttention: false),
            PanelStackContent.resolve(dictating: false, demandsAttention: false, onboarding: false))
    }

    /// Dictation is the deliberate exception — a key is physically held and the
    /// transcript is the gesture's only feedback. Nothing is lost: releasing the
    /// key lands on `.tab` at the next evaluation and the card appears.
    func testAHeldDictationKeyStillOwnsThePanelOutright() {
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: true, demandsAttention: true),
            .none,
            "the panel is the transcript and nothing else, not an emptied tab")
    }

    /// Nothing claiming the panel means the whole tab, blocking or not.
    func testTheUninterruptedPanelDrawsTheWholeTab() {
        for attention in [true, false] {
            XCTAssertEqual(
                PanelStackContent.resolve(dictating: false, demandsAttention: attention),
                .tab)
        }
    }

    // MARK: - A question opened the panel

    /// The owner's call (2026-10-01): when the panel opened because an agent is
    /// asking, it shows the question and nothing else from the tab.
    func testAQuestionThatOpenedThePanelIsAllItShows() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, demandsAttention: true,
                                                 askingYou: true),
                       .attentionOnly)
    }

    /// Opening the tab yourself while something waits still draws all of it.
    func testATabYouOpenedYourselfIsDrawnWhole() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, demandsAttention: true,
                                                 askingYou: false),
                       .tab)
    }

    /// The flag outliving its gate for one evaluation must cost a full tab,
    /// never an empty panel.
    func testAnAnsweredQuestionGivesTheTabBack() {
        XCTAssertEqual(PanelStackContent.resolve(dictating: false, demandsAttention: false,
                                                 askingYou: true),
                       .tab)
    }

    /// The claimants that already own the panel keep it: dictation is a key
    /// physically held, and setup already draws the gate on its own terms.
    func testAskingYouChangesNothingElseOwnsThePanel() {
        for attention in [true, false] {
            for (dictating, onboarding) in [(true, false), (false, true)] {
                XCTAssertEqual(
                    PanelStackContent.resolve(dictating: dictating, demandsAttention: attention,
                                              onboarding: onboarding, askingYou: true),
                    PanelStackContent.resolve(dictating: dictating, demandsAttention: attention,
                                              onboarding: onboarding),
                    "attention=\(attention) d=\(dictating) o=\(onboarding)")
            }
        }
    }
}
