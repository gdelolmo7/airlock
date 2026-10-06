import XCTest
@testable import AirlockCore

/// Mono is quarantined to code — the codebase's own rule, which the clipboard
/// list broke for every row.
///
/// The asymmetry is what these pin. Prose set in mono looks like a command you
/// might run, which is misleading; a command set in prose merely looks plain.
/// So the tests lean on the direction that actually costs something.
final class ClipboardTextKindTests: XCTestCase {
    // MARK: - Prose must never read as a command

    func testOrdinarySentencesAreProse() {
        for text in [
            "Remember to email Marc about the invoice",
            "make sure the build passes before you push",
            "test the new onboarding copy with someone",
            "Comida Casa Abuela",
            "42",
            "Kaze — Hablan de Unión, Pt. 2",
        ] {
            XCTAssertEqual(ClipboardTextKind.of(text), .prose, "\(text) is not code")
        }
    }

    /// Two paragraphs of notes are multi-line and are not code. Treating
    /// newlines as evidence was most of the old behaviour.
    func testAMultiLineNoteIsStillProse() {
        XCTAssertEqual(ClipboardTextKind.of("First thought.\n\nSecond thought, longer."),
                       .prose)
    }

    /// A sentence that mentions a link is prose about a link.
    func testASentenceContainingAURLIsNotALink() {
        XCTAssertEqual(ClipboardTextKind.of("see https://example.com for the details"),
                       .prose)
    }

    // MARK: - Links

    func testWholeURLsAreLinks() {
        for text in ["https://example.com/a/b?c=1", "http://localhost:3000",
                     "mailto:someone@example.com", "file:///Users/x/notes.md"] {
            XCTAssertEqual(ClipboardTextKind.of(text), .link, text)
        }
    }

    func testABareDomainIsNotALink() {
        // No scheme, so nothing here knows what activating it would do.
        XCTAssertEqual(ClipboardTextKind.of("example.com"), .prose)
    }

    // MARK: - Code

    func testShellAndPathsAreCode() {
        for text in ["git push --force origin main",
                     "$ swift build",
                     "/usr/local/bin/airlock-hook",
                     "~/Library/Application Support/Airlock",
                     "./scripts/package-app.sh",
                     "brew install --cask ghostty",
                     "npm run dev"] {
            XCTAssertEqual(ClipboardTextKind.of(text), .code, text)
        }
    }

    func testPunctuationDenseSnippetsAreCode() {
        XCTAssertEqual(ClipboardTextKind.of("if (a && b) { return c[0]; }"), .code)
    }

    /// The seven that shipped as code, all ordinary English. Every one came from
    /// a real clipboard: a calendar entry, a song title, a note to self, an email.
    ///
    /// Two rules did it. `contains(" -")` treated any spaced hyphen as a flag,
    /// and the "density" check counted `[`, `]`, `<`, `>` and `&` — prose
    /// characters — without dividing by length, so a LONGER entry was more
    /// likely to be called code.
    func testDashesAndBracketsInProseAreNotCode() {
        for text in ["Lunch - 13:00",
                     "Call Marta - she has the invoice",
                     "The plan - as we discussed - is to ship on Friday.",
                     "Toby Romeo - Lose U",
                     "R&D and Q&A at AT&T",
                     "See the notes [1], [2] and [3] for context.",
                     "Dear Guillermo,\n\nThanks for your note - I'll review it today.\n\nBest,\nAna"] {
            XCTAssertEqual(ClipboardTextKind.of(text), .prose, text)
        }
    }

    /// A flag is a token that starts with a hyphen and continues with a letter.
    /// A lone dash between words is punctuation, and a negative number is a
    /// number.
    func testFlagsAreStillCodeButLoneDashesAreNot() {
        XCTAssertEqual(ClipboardTextKind.of("airlock-setup install --force"), .code)
        XCTAssertEqual(ClipboardTextKind.of("tail -f log.txt"), .code)
        XCTAssertEqual(ClipboardTextKind.of("it was -5 degrees this morning"), .prose)
        XCTAssertEqual(ClipboardTextKind.of("a well-known e-mail address"), .prose)
    }

    /// Density means per length. Three semicolons in an essay is an essay.
    func testDensityIsRelativeToLength() {
        let essay = String(repeating: "This is an ordinary sentence about nothing. ", count: 40)
        XCTAssertEqual(ClipboardTextKind.of(essay + "One; two; three;"), .prose)
        XCTAssertEqual(ClipboardTextKind.of("a{b};c|d=e"), .code)
    }

    func testEmptyIsProseRatherThanACrash() {
        XCTAssertEqual(ClipboardTextKind.of(""), .prose)
        XCTAssertEqual(ClipboardTextKind.of("   \n "), .prose)
    }
}
