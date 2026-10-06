import XCTest
@testable import AirlockApp

/// The gallery is reachable only by its flag, and its IDs are the
/// inventory's rows: one picture per row, so two states sharing an ID would
/// silently overwrite each other's PNG in the export.
@MainActor
final class StateGalleryTests: XCTestCase {
    func testOnlyTheFlagOpensIt() {
        XCTAssertNil(StateGallery.requested(in: ["Airlock"]))
        XCTAssertNil(StateGallery.requested(in: ["Airlock", "--demo", "G26"]))
    }

    func testFlagAloneBrowsesFromTheStart() {
        XCTAssertEqual(StateGallery.requested(in: ["Airlock", "--state-gallery"]), .browse(startAt: nil))
        XCTAssertEqual(StateGallery.requested(in: ["Airlock", "--state-gallery", "--demo"]), .browse(startAt: nil))
    }

    func testAnIDOpensAtThatState() {
        XCTAssertEqual(StateGallery.requested(in: ["Airlock", "--state-gallery", "G26"]), .browse(startAt: "G26"))
        XCTAssertEqual(StateGallery.requested(in: ["Airlock", "--state-gallery", "G44a"]), .browse(startAt: "G44a"))
    }

    func testAnythingElseIsAFolderToExportTo() {
        XCTAssertEqual(StateGallery.requested(in: ["Airlock", "--state-gallery", "/tmp/states"]),
                       .export(URL(fileURLWithPath: "/tmp/states", isDirectory: true)))
    }

    func testEveryIDIsAnInventoryRowAndUnique() {
        let ids = StateGallery.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate IDs: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
        for id in ids {
            XCTAssertNotNil(id.range(of: #"^[A-Z][0-9]+[a-z]?$"#, options: .regularExpression), "\(id) is not a row ID")
        }
    }
}
