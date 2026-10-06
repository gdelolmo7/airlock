import XCTest
@testable import AirlockCore

final class WorkspaceLayoutTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    func testDefaultsToHomeRootNotDocuments() {
        let layout = WorkspaceLayout.resolve(environment: [:], homeDirectory: home)
        XCTAssertEqual(layout.root.path, "/Users/someone/Airlock")
        // Documents is TCC-protected; the tray must not need a permission
        // prompt to accept its first drop.
        XCTAssertFalse(layout.root.path.contains("Documents"))
        XCTAssertFalse(layout.root.path.contains("Library"))
    }

    /// The tray is not an agents feature — it must not live inside the working
    /// directory the agent runs in.
    func testTrayIsASiblingOfTheWorkspaceNotAChild() {
        let layout = WorkspaceLayout.resolve(environment: [:], homeDirectory: home)
        XCTAssertEqual(layout.workspace.path, "/Users/someone/Airlock/workspace")
        XCTAssertEqual(layout.tray.path, "/Users/someone/Airlock/tray")
        XCTAssertFalse(layout.tray.path.hasPrefix(layout.workspace.path))
        XCTAssertFalse(layout.workspace.path.hasPrefix(layout.tray.path))
    }

    func testEnvironmentOverridesTheRoot() {
        let layout = WorkspaceLayout.resolve(
            environment: [WorkspaceLayout.environmentOverride: "/tmp/an-test"], homeDirectory: home)
        XCTAssertEqual(layout.root.path, "/tmp/an-test")
        XCTAssertEqual(layout.tray.path, "/tmp/an-test/tray")
    }

    func testEmptyOverrideFallsBackToHome() {
        let layout = WorkspaceLayout.resolve(
            environment: [WorkspaceLayout.environmentOverride: ""], homeDirectory: home)
        XCTAssertEqual(layout.root.path, "/Users/someone/Airlock")
    }

    func testEnsureExistsCreatesBothSiblings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("an-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = WorkspaceLayout(root: root)
        try layout.ensureExists()
        var isDirectory: ObjCBool = false
        for path in [layout.workspace.path, layout.tray.path] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
        // Self-healing: a second call over an existing tree is not an error.
        XCTAssertNoThrow(try layout.ensureExists())
    }

    func testUniqueNamePassesThroughWhenFree() {
        XCTAssertEqual(WorkspaceLayout.uniqueName(for: "shot.png", existing: []), "shot.png")
    }

    /// Dropping the same file twice must keep both, not overwrite.
    func testUniqueNameSuffixesOnCollision() {
        XCTAssertEqual(WorkspaceLayout.uniqueName(for: "shot.png", existing: ["shot.png"]), "shot 2.png")
        XCTAssertEqual(
            WorkspaceLayout.uniqueName(for: "shot.png", existing: ["shot.png", "shot 2.png"]),
            "shot 3.png")
    }

    func testUniqueNameHandlesNoExtension() {
        XCTAssertEqual(WorkspaceLayout.uniqueName(for: "notes", existing: ["notes"]), "notes 2")
    }

    /// Multi-dot names keep only the final component as the extension.
    func testUniqueNamePreservesInnerDots() {
        XCTAssertEqual(
            WorkspaceLayout.uniqueName(for: "archive.tar.gz", existing: ["archive.tar.gz"]),
            "archive.tar 2.gz")
    }

    // MARK: - Naming pixels that arrived with no file behind them

    /// The hint is a page URL's last component over the cutout and an item
    /// provider's `suggestedName` on the panel. Either way the extension it
    /// carries is the SOURCE's, and the bytes have already been normalised, so
    /// it is replaced rather than appended.
    func testDroppedImageNameReplacesTheHintsExtension() {
        XCTAssertEqual(WorkspaceLayout.droppedImageName(hint: "puppy.jpg", extension: "png"),
                       "puppy.png")
        XCTAssertEqual(WorkspaceLayout.droppedImageName(hint: "puppy", extension: "png"),
                       "puppy.png")
    }

    func testDroppedImageNameFallsBackWithoutAHint() {
        XCTAssertEqual(WorkspaceLayout.droppedImageName(hint: nil, extension: "png"),
                       "Dropped image.png")
        XCTAssertEqual(WorkspaceLayout.droppedImageName(hint: "", extension: "jpg"),
                       "Dropped image.jpg")
    }

    /// A bare directory URL leaves "/" or "." as its last component. Neither is
    /// a filename, and writing one would put the image somewhere nobody meant.
    func testDroppedImageNameRejectsPathFragments() {
        XCTAssertEqual(WorkspaceLayout.droppedImageName(hint: "/", extension: "png"),
                       "Dropped image.png")
        XCTAssertEqual(WorkspaceLayout.droppedImageName(hint: ".", extension: "png"),
                       "Dropped image.png")
    }

    /// Composes with `uniqueName`: two images off the same page keep both.
    func testDroppedImageNameComposesWithUniqueName() {
        let first = WorkspaceLayout.droppedImageName(hint: "puppy.jpeg", extension: "png")
        XCTAssertEqual(WorkspaceLayout.uniqueName(for: first, existing: [first]), "puppy 2.png")
    }
}
