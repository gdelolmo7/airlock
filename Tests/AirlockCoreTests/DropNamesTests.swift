import XCTest
@testable import AirlockCore

/// What the box's copies are called: never a name already taken.
final class DropNamesTests: XCTestCase {
    func testACopyInAnotherFormat() {
        XCTAssertEqual(DropNames.names(for: ["Beach.heic"], choice: .picture(.jpeg), existing: []),
                       ["Beach.jpg"])
    }

    func testANameAlreadyOnTheShelfGetsANumber() {
        let names = DropNames.names(for: ["Beach.heic"], choice: .picture(.jpeg), existing: ["Beach.jpg"])
        XCTAssertNotEqual(names, ["Beach.jpg"])
        XCTAssertEqual(names.count, 1)
    }

    func testTwoOfTheSameNameInOneDropDiffer() {
        let names = DropNames.names(for: ["a/Beach.heic", "Beach.png"].map { ($0 as NSString).lastPathComponent },
                                    choice: .picture(.jpeg), existing: [])
        XCTAssertEqual(Set(names).count, 2)
    }

    func testActionsSayWhatTheCopyIs() {
        XCTAssertEqual(DropNames.names(for: ["Beach.heic"], choice: .smaller, existing: []),
                       ["Beach (smaller).heic"])
        XCTAssertEqual(DropNames.names(for: ["Beach.heic"], choice: .cutOut, existing: []),
                       ["Beach (no background).png"], "a picture with no background needs see-through pixels")
        XCTAssertEqual(DropNames.names(for: ["Clip.mov"], choice: .noSound, existing: []),
                       ["Clip (no sound).mov"])
    }

    /// A smaller WebP comes back a JPG: this Mac can't write WebP.
    func testAKindTheMacCantWriteFallsBack() {
        XCTAssertEqual(DropNames.names(for: ["Logo.webp"], choice: .smaller, existing: [],
                                       keeps: ["jpg", "png", "heic"], fallback: "jpg"),
                       ["Logo (smaller).jpg"])
    }

    func testOneFileFromTheWholeDrag() {
        XCTAssertEqual(DropNames.names(for: ["A.png", "B.png"], choice: .onePDF, existing: []), ["A.pdf"])
        XCTAssertEqual(DropNames.names(for: ["A.png", "B.png"], choice: .zip, existing: []),
                       ["A and more.zip"])
        XCTAssertEqual(DropNames.names(for: ["Notes"], choice: .zip, existing: []), ["Notes.zip"])
    }

    func testPagesGoInAFolderPerItem() {
        XCTAssertEqual(DropNames.names(for: ["Report.pdf"], choice: .splitPages, existing: []),
                       ["Report pages"])
    }

    func testNothingIsNamedForWhatMakesNoFile() {
        XCTAssertEqual(DropNames.names(for: ["Scan.png"], choice: .copyText, existing: []), [])
        XCTAssertEqual(DropNames.names(for: ["Memo.mp3"], choice: .writeItOut, existing: []), [],
                       "what's said goes to the clipboard")
        XCTAssertEqual(DropNames.names(for: ["Memo.m4a"], choice: .notesFromIt, existing: []), [])
    }

    func testNameInOrder() {
        XCTAssertEqual(DropNames.names(for: ["Trip.jpg", "Other.png", "Notes"], choice: .nameInOrder,
                                       existing: []),
                       ["Trip 1.jpg", "Trip 2.png", "Trip 3"])
    }
}
