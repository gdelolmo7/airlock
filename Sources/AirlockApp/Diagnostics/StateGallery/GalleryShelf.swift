import SwiftUI
import AirlockCore

/// The shelf's rows (S) of the inventory.
///
/// **No shelf folder is involved.** Tiles come from `TrayModel(previewing:)`
/// over a root that does not exist, so nothing is created, watched or listed,
/// and nobody's real shelf can reach a picture. Thumbnails therefore fall back
/// to the system icon or nothing — the files are not there to preview.
///
/// Messages are the shipping words: `TrayModel`'s named messages, the Core
/// results' `message`, and real `CocoaError` descriptions where the app shows
/// a raw system error, since what that raw text looks like is the finding.
@MainActor
enum GalleryShelf {
    static let area = "Shelf"

    static var states: [GalleryState] {
        [
            shelf("S1", "Empty", items: []),
            shelf("S2", "Dragging over", items: [], targeted: true),
            shelf("S3", "Refused (link / text)", items: [], targeted: true,
                  rejection: TrayDropKind.webLink.explanation),
            shelf("S4", "Refused (anything else) — said without its type identifier", items: [], targeted: true,
                  rejection: TrayDropKind.unknown("com.apple.mail.PasteboardTypeMessageTransfer").explanation),
            shelf("S5", "Has files", items: files),
            shelf("S6", "Folders: being measured (\"Folder\"), and measured empty (\"Folder · Empty\")",
                  items: [folder, emptyFolder] + files.prefix(2)),
            shelf("S7", "File arriving", items: Array(files.prefix(2)), ingesting: ["Holiday video.mov"]),
            shelf("S8", "Couldn't add (disk full)", items: files,
                  error: TrayIngestResult(added: 0, failures: [
                      .init(name: "Holiday video.mov",
                            reason: PlainProblem.file(CocoaError(.fileWriteOutOfSpace))),
                  ]).message),
            shelf("S9", "Couldn't create the shelf folder", items: [],
                  error: TrayModel.couldNotCreate(root, CocoaError(.fileWriteNoPermission,
                                                                    userInfo: [NSFilePathErrorKey: root.path]))),
            shelf("S10", "Couldn't save an image", items: files,
                  error: TrayModel.couldNotSaveImage(CocoaError(.fileWriteOutOfSpace, userInfo: [
                      NSFilePathErrorKey: root.appendingPathComponent("tray/Dropped image.png").path,
                  ]))),
            shelf("S11", "No Downloads access (Open Settings)", items: files,
                  error: moveFailed(TrayModel.needsDownloadsAccess), fix: .downloadsAccess),
            shelf("S12", "Move to Downloads failed", items: files,
                  error: moveFailed(PlainProblem.file(CocoaError(.fileWriteVolumeReadOnly, userInfo: [
                      NSFilePathErrorKey: "/Users/you/Downloads/Invoice 0412.pdf",
                  ])))),
            shelf("S13", "AirDrop failure (text dropped on AirDrop)", items: files,
                  error: TrayModel.airDropNeedsAFile),
            shelf("S14", "\"Add selection\" with Finder control refused (Open Settings)", items: [],
                  error: TrayModel.finderNotAllowed, fix: .finderAutomation),
            shelf("S15", "Trash failed", items: files,
                  error: TrayModel.couldNotTrash(CocoaError(.fileWriteNoPermission, userInfo: [
                      NSFilePathErrorKey: root.appendingPathComponent("tray/Invoice 0412.pdf").path,
                  ]))),
        ]
    }

    // MARK: - Builders

    private static func shelf(_ id: String, _ name: String, items: [TrayItem],
                              ingesting: [String] = [], error: String? = nil, fix: TrayFix? = nil,
                              targeted: Bool = false, rejection: String? = nil) -> GalleryState {
        GalleryState(id, area, name) {
            TraySectionView()
                .environment(TrayModel(previewing: items, ingesting: ingesting, lastError: error,
                                       lastErrorFix: fix, layout: WorkspaceLayout(root: root)))
                .environment(drag(targeted: targeted, rejection: rejection))
        }
    }

    /// A drag hovering over the panel, as the drop target reports it.
    private static func drag(targeted: Bool, rejection: String?) -> NotchUIState {
        let state = NotchUIState()
        state.isDropTargeted = targeted
        state.dropRejection = rejection
        return state
    }

    private static func moveFailed(_ reason: String) -> String? {
        TrayRelocationResult(moved: [], failures: [.init(name: "Invoice 0412.pdf", reason: reason)],
                             destination: "Downloads").message
    }

    // MARK: - Made-up shelf

    /// Never created. Reads like a home folder because S9 prints it.
    private static let root = URL(fileURLWithPath: "/Users/you/Airlock", isDirectory: true)
    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private static func item(_ name: String, _ size: Int64, minutesAgo: Double,
                             isDirectory: Bool = false, sizeIsKnown: Bool = true) -> TrayItem {
        TrayItem(url: root.appendingPathComponent("tray/\(name)", isDirectory: isDirectory),
                 size: size, modified: t0.addingTimeInterval(-minutesAgo * 60),
                 isDirectory: isDirectory, sizeIsKnown: sizeIsKnown)
    }

    private static let files: [TrayItem] = [
        item("Invoice 0412.pdf", 184_000, minutesAgo: 1),
        item("Moodboard.png", 2_400_000, minutesAgo: 6),
        item("Notes from Tuesday.txt", 3_100, minutesAgo: 30),
        item("Site export.zip", 48_200_000, minutesAgo: 95),
    ]

    /// Just dropped: its size has not been walked yet.
    private static let folder = item("Photos to sort", 0, minutesAgo: 0, isDirectory: true,
                                     sizeIsKnown: false)
    /// Walked, and nothing in it.
    private static let emptyFolder = item("New folder", 0, minutesAgo: 3, isDirectory: true)
}
