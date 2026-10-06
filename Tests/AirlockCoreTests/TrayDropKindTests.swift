import XCTest
@testable import AirlockCore

final class TrayDropKindTests: XCTestCase {
    /// A Finder drag advertises the file URL among several other flavours.
    func testFinderDragIsFiles() {
        let kind = TrayDropKind.classify(typeIdentifiers: [
            "public.file-url", "public.url", "public.utf8-plain-text", "NSFilenamesPboardType",
        ])
        XCTAssertEqual(kind, .files)
        XCTAssertTrue(kind.isSupported)
    }

    /// A jpg dragged out of Google Images. It advertises the page URL AND the
    /// pixels; checking the URL first made every genuine web image read as a
    /// bare link and get refused, with the image sitting right there on the
    /// pasteboard. Pixels win.
    func testBrowserImageIsImageDataNotALink() {
        let kind = TrayDropKind.classify(typeIdentifiers: [
            "public.url", "public.utf8-plain-text", "public.tiff",
        ])
        XCTAssertEqual(kind, .imageData)
        XCTAssertTrue(kind.isSupported)
        XCTAssertTrue(kind.explanation.isEmpty)
    }

    /// A link with nothing behind it is still refused — there are no pixels to
    /// keep, and downloading it is a different feature.
    func testBareLinkIsStillRefused() {
        let kind = TrayDropKind.classify(typeIdentifiers: ["public.url", "public.utf8-plain-text"])
        XCTAssertEqual(kind, .webLink)
        XCTAssertFalse(kind.isSupported)
    }

    /// A real file on disk beats a copy of its pixels, so files stay first.
    func testFileURLOutranksLinkAndPixels() {
        XCTAssertEqual(
            TrayDropKind.classify(typeIdentifiers: ["public.url", "public.file-url"]), .files)
        XCTAssertEqual(
            TrayDropKind.classify(typeIdentifiers: ["public.tiff", "public.file-url"]), .files)
    }

    func testRawImageDataWithoutALink() {
        XCTAssertEqual(TrayDropKind.classify(typeIdentifiers: ["public.png"]), .imageData)
        XCTAssertEqual(TrayDropKind.classify(typeIdentifiers: ["public.tiff"]), .imageData)
    }

    /// webp is the format the user named — Google serves it constantly.
    func testWebpCountsAsImageData() {
        XCTAssertEqual(TrayDropKind.classify(typeIdentifiers: ["org.webmproject.webp"]), .imageData)
        XCTAssertEqual(TrayDropKind.classify(typeIdentifiers: ["com.example.thing.webp"]), .imageData)
    }

    func testSelectedTextIsText() {
        XCTAssertEqual(TrayDropKind.classify(typeIdentifiers: ["public.utf8-plain-text"]), .text)
        XCTAssertEqual(TrayDropKind.classify(typeIdentifiers: ["public.html"]), .text)
    }

    /// Anything unrecognised is still refused out loud, but in words: the type
    /// identifier is kept on the case for the log and never reaches the
    /// sentence, which used to read "com.acme.widget isn't a file" (S4).
    func testUnknownIsExplainedWithoutItsTypeIdentifier() {
        let kind = TrayDropKind.classify(typeIdentifiers: ["com.acme.widget"])
        XCTAssertEqual(kind, .unknown("com.acme.widget"))
        XCTAssertFalse(kind.explanation.contains("com.acme.widget"))
        XCTAssertFalse(kind.explanation.lowercased().contains("tray"))
        XCTAssertEqual(kind.explanation, TrayDropKind.unknownExplanation)
    }

    func testEmptyPasteboardStillExplainsItself() {
        let kind = TrayDropKind.classify(typeIdentifiers: [])
        XCTAssertFalse(kind.isSupported)
        XCTAssertFalse(kind.explanation.isEmpty)
    }

    /// Supported drops must not carry a message — the UI keys the red state off
    /// having one.
    func testSupportedKindHasNoExplanation() {
        XCTAssertTrue(TrayDropKind.files.explanation.isEmpty)
    }

    // MARK: - The watched set

    /// The one flavour that must be there: without it a Finder drag is never
    /// offered to either surface and the shelf cannot be filled at all.
    func testWatchedSetAdmitsFileURLs() {
        XCTAssertTrue(TrayDropKind.watchedTypeIdentifiers.contains("public.file-url"))
    }

    /// Both drop surfaces read this list — the AppKit catcher over the cutout
    /// registers it as dragged types, the open panel declares it as content
    /// types. Duplicates would be harmless; the assertion is that it stays one
    /// deliberate list rather than accreting.
    func testWatchedSetHasNoDuplicates() {
        XCTAssertEqual(Set(TrayDropKind.watchedTypeIdentifiers).count,
                       TrayDropKind.watchedTypeIdentifiers.count)
    }

    /// The set is admitted so refusals can be EXPLAINED, which only works if
    /// every refusable member has something to say. Adding a flavour whose
    /// message is empty would give back the silent drop the wide set exists to
    /// prevent, only now with the notch lit up as a target.
    func testEveryWatchedFlavourEitherLandsOrExplainsItself() {
        for identifier in TrayDropKind.watchedTypeIdentifiers {
            let kind = TrayDropKind.classify(typeIdentifiers: [identifier])
            if kind.isSupported {
                XCTAssertTrue(kind.explanation.isEmpty, "\(identifier) is kept but carries a message")
            } else {
                XCTAssertFalse(kind.explanation.isEmpty, "\(identifier) is refused and says nothing")
            }
        }
    }

    /// What the two surfaces actually keep, spelled out against the list they
    /// both admit. `com.adobe.pdf` is in the set and is NOT kept: raw PDF bytes
    /// off a Preview thumbnail are admitted only so the refusal can name them —
    /// the shelf holds files, and a PDF dragged from Finder arrives as one.
    func testWatchedFlavoursKeptVersusExplained() {
        let kept = TrayDropKind.watchedTypeIdentifiers.filter {
            TrayDropKind.classify(typeIdentifiers: [$0]).isSupported
        }
        XCTAssertEqual(kept, ["public.file-url", "public.png", "public.tiff"])
        XCTAssertEqual(TrayDropKind.classify(typeIdentifiers: ["com.adobe.pdf"]),
                       .unknown("com.adobe.pdf"))
    }

    /// The list gates only whether a drag is OFFERED to us; classification then
    /// reads everything it carries. A jpeg is admitted on the strength of the
    /// page URL beside it and still lands as an image — on both paths, because
    /// both read the full flavour list rather than the admitted one.
    func testAdmittedDragIsClassifiedOnEverythingItCarries() {
        XCTAssertFalse(TrayDropKind.watchedTypeIdentifiers.contains("public.jpeg"))
        let kind = TrayDropKind.classify(typeIdentifiers: [
            "public.url", "public.utf8-plain-text", "public.jpeg",
        ])
        XCTAssertEqual(kind, .imageData)
    }
}
