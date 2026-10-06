import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// The latch, which is the whole safety argument for a card with two forms.
///
/// The card may change shape only between panel sessions. If it can change while
/// the panel is open, then a third app starting rotates every control in the
/// card 90° under a pointer that may already be travelling to one — the same
/// hazard `AppMix.slots`' 30s linger exists to prevent, at card scale.
///
/// **At the shipped knob there is nothing for it to hold** — every count is rows
/// (`LevelsFormTests`) — so most of these drive it with the ORIGINAL split,
/// three (5cfcc96), through `SoundWidgetModel(formThreshold:)`. That is the
/// state the latch was built for and the one a reversal of the knob would bring
/// back, and it lets these use real counts on both sides of a real threshold.
/// While the console was the only form anything reached, the counts here had to
/// be a synthetic zero instead.
@MainActor
final class LevelsFormLatchTests: XCTestCase {

    /// Two sources are rows, three are the console.
    private func splitCard() -> SoundWidgetModel { SoundWidgetModel(formThreshold: 3) }

    func testFormIsDecidedWhenThePanelOpens() {
        let sound = splitCard()
        sound.setPanelVisible(true, sourceCount: 4)
        XCTAssertEqual(sound.form, .console)
    }

    /// THE test. Sources arriving mid-session must not restyle the card.
    func testSourcesArrivingWhileOpenCannotChangeTheForm() {
        let sound = splitCard()
        sound.setPanelVisible(true, sourceCount: 2)
        XCTAssertEqual(sound.form, .rows)

        // A third app starts playing while the panel is on screen.
        sound.setPanelVisible(true, sourceCount: 3)
        XCTAssertEqual(sound.form, .rows, "the card restyled itself while being looked at")
    }

    /// And the reverse: sources leaving cannot collapse it either.
    func testSourcesLeavingWhileOpenCannotChangeTheForm() {
        let sound = splitCard()
        sound.setPanelVisible(true, sourceCount: 3)
        XCTAssertEqual(sound.form, .console)
        sound.setPanelVisible(true, sourceCount: 1)
        XCTAssertEqual(sound.form, .console)
    }

    /// Closing decides nothing — the count at dismissal is not the count at the
    /// next opening, and choosing on the falling edge would style the card for a
    /// moment nobody saw.
    func testClosingDoesNotDecideAnything() {
        let sound = splitCard()
        sound.setPanelVisible(true, sourceCount: 2)
        sound.setPanelVisible(false, sourceCount: 5)
        XCTAssertEqual(sound.form, .rows)
    }

    /// The next opening does decide, which is what makes this a latch rather
    /// than a one-shot.
    func testTheNextOpeningRedecides() {
        let sound = splitCard()
        sound.setPanelVisible(true, sourceCount: 2)
        XCTAssertEqual(sound.form, .rows)
        sound.setPanelVisible(false, sourceCount: 2)
        sound.setPanelVisible(true, sourceCount: 4)
        XCTAssertEqual(sound.form, .console)
    }

    // MARK: - The shipped card

    /// Before the panel has ever opened the card must still be drawable, and in
    /// the form the shipped knob wants, so the pre-session frame agrees with
    /// every frame after it instead of being one blink of the other shape.
    func testTheShippedCardDefaultsToRows() {
        XCTAssertEqual(SoundWidgetModel().form, .rows)
    }

    /// Rows at every opening, whatever is playing — the property the owner
    /// asked for, through the model the app actually builds.
    func testTheShippedCardIsRowsAtEveryOpening() {
        let sound = SoundWidgetModel()
        for count in [0, 1, 2, 3, 5, 9] {
            sound.setPanelVisible(true, sourceCount: count)
            XCTAssertEqual(sound.form, .rows, "\(count) sources")
            sound.setPanelVisible(false, sourceCount: count)
        }
    }

    /// The pre-session default is derived from the knob rather than written
    /// down beside it, so moving the knob cannot leave the two disagreeing —
    /// which would be the blink above, reintroduced by the reversal itself.
    func testTheDefaultFollowsTheKnob() {
        XCTAssertEqual(SoundWidgetModel(formThreshold: 1).form, .console)
        XCTAssertEqual(SoundWidgetModel(formThreshold: 3).form, .rows)
    }
}
