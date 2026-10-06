import XCTest
@testable import AirlockCore

final class ClipboardFilterTests: XCTestCase {

    private func text(_ s: String) -> ClipboardItem {
        ClipboardItem(payload: .text(s), fingerprint: s, copiedAt: Date())
    }
    private func file(_ path: String) -> ClipboardItem {
        ClipboardItem(payload: .file(path: path), fingerprint: path, copiedAt: Date())
    }
    private func image() -> ClipboardItem {
        ClipboardItem(payload: .image(file: "shot.png", width: 100, height: 80),
                      fingerprint: "shot", copiedAt: Date())
    }

    /// One 115,000-character copy froze the panel on every filter switch,
    /// because the filter and the row read `preview` several times a redraw.
    func testAHugeCopyIsPreviewedFromItsHeadOnly() {
        let huge = text(String(repeating: "word {x}; ", count: 20_000))
        XCTAssertLessThanOrEqual(huge.preview.count, ClipboardItem.previewSource + 1)
        XCTAssertTrue(huge.preview.hasSuffix("…"))
        XCTAssertEqual(huge.textKind, .code, "judged on its head, still code")
        XCTAssertEqual(text("  short\n  note ").preview, "short note", "no ellipsis when it all fits")
    }

    func testAllMatchesEverything() {
        for item in [text("hello"), text("https://claude.ai"), text("git push"), image()] {
            XCTAssertTrue(ClipboardFilter.all.matches(item))
        }
    }

    func testImagesMatchOnlyImages() {
        XCTAssertTrue(ClipboardFilter.images.matches(image()))
        XCTAssertFalse(ClipboardFilter.images.matches(text("hello")))
        XCTAssertFalse(ClipboardFilter.images.matches(text("https://claude.ai")))
    }

    func testLinksMatchOnlyWholeURLs() {
        XCTAssertTrue(ClipboardFilter.links.matches(text("https://claude.ai/code")))
        XCTAssertFalse(ClipboardFilter.links.matches(text("see https://claude.ai for more")))
        XCTAssertFalse(ClipboardFilter.links.matches(image()))
    }

    /// Code is text. The filter answers "what did I copy", and a command is
    /// something you copied as text — splitting it out would make the common
    /// case need two buttons.
    func testTextIncludesCodeButNotLinksOrImages() {
        XCTAssertTrue(ClipboardFilter.text.matches(text("git push origin main")))
        XCTAssertTrue(ClipboardFilter.text.matches(text("an ordinary note")))
        XCTAssertFalse(ClipboardFilter.text.matches(text("https://claude.ai")))
        XCTAssertFalse(ClipboardFilter.text.matches(image()))
    }

    func testFilesMatchOnlyFiles() {
        let f = file("/Users/g/Downloads/Screenshot 2026-08-12.png")
        XCTAssertTrue(ClipboardFilter.files.matches(f))
        XCTAssertFalse(ClipboardFilter.images.matches(f), "a file reference is not image data")
        XCTAssertFalse(ClipboardFilter.text.matches(f))
        XCTAssertTrue(ClipboardFilter.all.matches(f))
    }

    /// The row shows the name; the search matches the whole path. "downloads" is
    /// how people look for a file they copied, and it is not in the filename.
    func testAFileShowsItsNameAndSearchesItsPath() {
        let f = file("/Users/g/Downloads/Tailandia/notes.md")
        XCTAssertEqual(f.preview, "notes.md")
        XCTAssertTrue(f.searchableText.contains("Downloads"))
        XCTAssertEqual(f.sizeLabel, "md")
    }

    /// A filename is set in the UI face, never judged as code — otherwise
    /// `Screenshot 2026-08-12 at 21.11.50.png` is at the mercy of its punctuation.
    func testAFilenameIsNeverCode() {
        XCTAssertEqual(file("/tmp/a-b --c {x}; y|z=1.txt").textKind, .prose)
    }

    /// Every item lands under exactly one of the four real buttons, so nothing
    /// can be invisible under every filter but `all`.
    func testEveryItemIsReachableFromExactlyOneFilter() {
        let items = [text("hello"), text("https://claude.ai"), text("git push -f"),
                     text("Lunch - 13:00"), image(), file("/tmp/a.png")]
        for item in items {
            let hits = [ClipboardFilter.text, .links, .images, .files].filter { $0.matches(item) }
            XCTAssertEqual(hits.count, 1, "\(item.preview) matched \(hits.map(\.rawValue))")
        }
    }

    /// The row tints by `textKind` and the filter matches by it. If they ever
    /// derive it separately, a row drawn as a link goes missing from the links
    /// filter and it looks like the filter is broken.
    func testRowTintAndFilterAgree() {
        let link = text("https://claude.ai/code")
        XCTAssertEqual(link.textKind, .link)
        XCTAssertTrue(ClipboardFilter.links.matches(link))
        XCTAssertEqual(image().textKind, .prose, "an image preview is a filename, never code")
    }
}

/// The precedence that makes files possible at all.
final class PasteboardFilePrecedenceTests: XCTestCase {
    private let classifier = PasteboardClassifier()

    /// Finder puts the path on the board as text NEXT TO the file reference. The
    /// text-first rule therefore recorded every file you copied as a string of
    /// its own path, which is what "Files has no data" actually looked like.
    func testAFinderCopyIsAFileAndNotItsPathAsText() {
        XCTAssertEqual(classifier.decide(types: ["public.file-url", "public.utf8-plain-text"]),
                       .takeFile)
    }

    /// A PNG copied in Finder is a FILE, not image data — the design draws those
    /// rows with a document glyph and a filename, sourced from Finder.
    func testAnImageFileCopiedInFinderIsAFile() {
        XCTAssertEqual(classifier.decide(types: ["public.file-url", "public.png"]), .takeFile)
    }

    /// And nothing else changes: a screenshot on the clipboard has no file URL.
    func testPlainCopiesAreUnaffected() {
        XCTAssertEqual(classifier.decide(types: ["public.png"]), .takeImage)
        XCTAssertEqual(classifier.decide(types: ["public.utf8-plain-text"]), .takeText)
        XCTAssertEqual(classifier.decide(types: ["public.html", "public.utf8-plain-text"]),
                       .takeText)
    }

    /// Privacy still outranks everything, including a file.
    func testAPrivateMarkerStillWinsOverAFile() {
        XCTAssertEqual(classifier.decide(types: ["org.nspasteboard.ConcealedType",
                                                 "public.file-url"]),
                       .skip(.markedPrivate("org.nspasteboard.ConcealedType")))
    }
}
