import SwiftUI
import XCTest
@testable import AirlockApp

/// The agent marks are vendor artwork embedded as path data, and the failure
/// mode is silent: a parser that drops a command, or a transcription that loses
/// one space between two numbers, still produces *a* shape. It is just the
/// wrong one, and nothing crashes.
///
/// Transcribing this by hand did exactly that — `2.491 1.833` became
/// `2.4911.833` — so these check the geometry rather than trusting the string.
@MainActor
final class SVGPathTests: XCTestCase {
    private let box = CGRect(x: 0, y: 0, width: 24, height: 24)

    /// Fitted to the frame, which is what the app draws.
    private func bounds(_ commands: String) -> CGRect {
        SVGPath(commands: commands).path(in: box).boundingRect
    }

    /// The artwork's OWN coordinates, unscaled. Ink-fitting normalises every
    /// path to the same box, so anything about where geometry actually lands
    /// has to be measured before that happens.
    private func rawBounds(_ commands: String) -> CGRect {
        SVGPath(commands: commands, fitsInk: false).path(in: box).boundingRect
    }

    // MARK: - The marks

    /// Whatever their artwork's own padding, both marks END UP the same size on
    /// screen — which is the whole point of fitting the ink. Codex is drawn
    /// inset because it used to sit on a tile; scaled by its viewBox it read
    /// visibly smaller than Claude beside it.
    func testBothMarksFillTheFrameTheyAreGiven() {
        for (name, data) in [("claude", AgentMarks.claude), ("codex", AgentMarks.codexGlyph)] {
            let rect = bounds(data)
            XCTAssertEqual(max(rect.width, rect.height), 24, accuracy: 0.01,
                           "\(name) does not fill its frame")
        }
    }

    /// And the raw artwork really does differ — so the test above is measuring
    /// something rather than restating an identity.
    func testCodexArtworkIsInsetWhereClaudeIsNot() {
        XCTAssertGreaterThan(rawBounds(AgentMarks.claude).width, 23)
        XCTAssertLessThan(rawBounds(AgentMarks.codexGlyph).width, 22,
                          "Codex is drawn with the margin its tile needed")
    }

    /// Nothing may escape the box. A merged pair of numbers throws a control
    /// point far outside it, which is the signature of the transcription bug
    /// this file exists because of.
    func testNothingEscapesTheViewBox() {
        for (name, data) in [("claude", AgentMarks.claude), ("codex", AgentMarks.codexGlyph)] {
            // RAW, deliberately: fitting the ink would rescale a stray point
            // back inside the frame and hide exactly the fault this catches.
            let rect = rawBounds(data)
            XCTAssertGreaterThanOrEqual(rect.minX, -0.5, "\(name) runs off the left")
            XCTAssertGreaterThanOrEqual(rect.minY, -0.5, "\(name) runs off the top")
            XCTAssertLessThanOrEqual(rect.maxX, 24.5, "\(name) runs off the right")
            XCTAssertLessThanOrEqual(rect.maxY, 24.5, "\(name) runs off the bottom")
        }
    }

    func testTheMarksScaleWithTheFrame() {
        let small = SVGPath(commands: AgentMarks.claude).path(in: box).boundingRect
        let large = SVGPath(commands: AgentMarks.claude)
            .path(in: CGRect(x: 0, y: 0, width: 48, height: 48)).boundingRect
        XCTAssertEqual(large.width / small.width, 2, accuracy: 0.01)
    }

    /// Uniform, and centred. A logo is the one image that must never be
    /// stretched to fit.
    func testANonSquareFrameDoesNotDistort() {
        let rect = SVGPath(commands: AgentMarks.claude)
            .path(in: CGRect(x: 0, y: 0, width: 48, height: 24)).boundingRect
        let square = bounds(AgentMarks.claude)
        XCTAssertEqual(rect.width, square.width, accuracy: 0.01)
        XCTAssertEqual(rect.height, square.height, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 24, accuracy: 0.5, "should be centred in the wider frame")
    }

    // MARK: - The parser

    func testAbsoluteAndRelativeAgree() {
        let absolute = bounds("M2 2 L22 2 L22 22 L2 22 Z")
        let relative = bounds("m2 2 l20 0 l0 20 l-20 0 z")
        XCTAssertEqual(absolute, relative)
    }

    /// A repeated command with no letter — `l` followed by six numbers is three
    /// line-tos — which is how most of this artwork is written.
    func testImplicitRepeatedCommands() {
        XCTAssertEqual(bounds("M2 2 l10 0 l0 10 l-10 0 z"),
                       bounds("M2 2 l10 0 0 10 -10 0 z"))
    }

    /// A second pair after a move-to is a LINE, not another move. Getting this
    /// wrong leaves an open subpath and loses an edge.
    func testARepeatedMoveIsALine() {
        XCTAssertEqual(bounds("M2 2 12 12"), bounds("M2 2 L12 12"))
    }

    func testHorizontalAndVerticalCommands() {
        XCTAssertEqual(bounds("M2 2 H22 V22 H2 Z"), bounds("M2 2 L22 2 L22 22 L2 22 Z"))
    }

    /// Arc flags pack against what follows — `0 01-.104` is largeArc 0, sweep 1,
    /// then −0.104 — so the flag scanner must take exactly one digit.
    func testArcFlagsAreSingleDigits() {
        let rect = bounds("M2 12 a10 10 0 0112 0")
        XCTAssertGreaterThan(rect.width, 8, "the arc collapsed — flags were misread")
        XCTAssertLessThanOrEqual(rect.maxX, 24.5)
    }

    func testAnArcSweepsTheExpectedWay() {
        // Same endpoints, opposite sweep flags: one bulges up, the other down.
        // Raw: fitting normalises two congruent arcs onto the same box.
        let up = rawBounds("M4 12 a8 8 0 0116 0")
        let down = rawBounds("M4 12 a8 8 0 0016 0")
        XCTAssertNotEqual(up.minY, down.minY, accuracy: 0.001)
    }

    func testMalformedDataDegradesRatherThanCrashing() {
        _ = bounds("M2")
        _ = bounds("")
        _ = bounds("Q1 2 3 4")
        _ = bounds("M2 2 a1 1")
    }
}
