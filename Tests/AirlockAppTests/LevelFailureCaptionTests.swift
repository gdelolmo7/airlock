import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// The sentence under a row whose level stopped reaching its app, laid out
/// where the card is narrowest.
///
/// It is the only thing saying that the slider reads 40 while the app plays at
/// its normal volume, and its second half is the instruction — so a caption cut
/// off at "Move the slider…" has lost the part that says what to do. Each
/// sentence is laid out by SwiftUI itself, through an `NSHostingView` the way
/// `LevelsRowsSnapshot` measures heights, in the row's own caption font, in a
/// side column of the narrowest panel the width setting allows. Counting
/// characters would be a guess about a proportional font; this is not.
///
/// Two budgets. At the default text size, two lines: a failure grows the card
/// by a line or two, not by a paragraph. At the largest, the caption's own line
/// limit — nothing cut off where the text is biggest.
@MainActor
final class LevelFailureCaptionTests: XCTestCase {

    /// The caption's width in the narrowest panel: a side column, less the
    /// card's 10pt padding either side (`FaderConsoleView`), less the indent
    /// that lines the caption up with the name.
    private static var captionWidth: CGFloat {
        LevelsRowsSnapshot.sideColumn(NotchAppearanceModel.requestedWidthRange.lowerBound)
            - 2 * 10 - LevelRow.failureIndent
    }

    func testEverySentenceFitsTwoLinesAtTheDefaultTextSize() {
        defer { Theme.setTextScale(1) }
        Theme.setTextScale(1)
        for sentence in AppVolumeModel.failureSentences {
            let lines = Self.lines(sentence)
            XCTAssertLessThanOrEqual(lines, 2, """
                "\(sentence)" takes \(lines) lines in the narrowest card at the default text size \
                (\(Self.captionWidth)pt). Shorten it rather than raise the limit: a failure should \
                grow the card by a line or two, and it is the instruction at the end that gets cut.
                """)
        }
    }

    func testNothingIsCutOffAtTheLargestTextSize() {
        defer { Theme.setTextScale(1) }
        Theme.setTextScale(Theme.maxTextScale)
        for sentence in AppVolumeModel.failureSentences {
            let lines = Self.lines(sentence)
            XCTAssertLessThanOrEqual(lines, LevelRow.failureLineLimit, """
                "\(sentence)" takes \(lines) lines in the narrowest card at the largest text size, \
                and the caption stops at \(LevelRow.failureLineLimit) — the end would be cut off \
                for exactly the people who asked for larger text.
                """)
        }
    }

    /// How many lines SwiftUI gives `text` in the caption's font at `captionWidth`.
    private static func lines(_ text: String) -> Int {
        let line = height(Text("Ag").font(LevelRow.failureFont).fixedSize())
        let wrapped = height(Text(text).font(LevelRow.failureFont)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: captionWidth, alignment: .leading))
        return Int((wrapped / line).rounded())
    }

    private static func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }
}
