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
            pocket("S16", "Drop box: a file near the top", .open),
            pocket("S17", "Drop box: the file on it", .over),
            pocket("S18", "Drop box: kept", .landed, note: .done(.shelf, count: 1)),
            shelf("S19", "A phone photo over the shelf: the format row", items: files, targeted: true,
                  pictures: onePhoto),
            shelf("S20", "Three pictures on the JPG chip (and One PDF at the end)", items: files,
                  targeted: true, pictures: threePictures, over: .format(.jpeg)),
            shelf("S21", "A picture copy that failed", items: files,
                  error: PictureConversionResult(target: .format(.png), made: 0, failures: [
                      .init(name: "IMG_0042.heic", reason: PictureConversionResult.unreadable),
                  ]).message),
            pocket("S22", "Drop box: a photo near the top, formats over actions", .open,
                   sources: [.picture(.heic)]),
            pocket("S23", "Drop box: three pictures on the JPG chip", .over,
                   sources: Array(repeating: .picture(.heic), count: 3), over: .choice(.picture(.jpeg))),
            pocket("S24", "Drop box: the file on AirDrop", .over, over: .airDrop),
            pocket("S25", "Drop box: a copy on its way", .landed, sources: [.picture(.heic)],
                   note: .done(.choice(.picture(.png)), count: 1)),
            pocket("S26", "Drop box: AirDrop refused", .landed,
                   note: .refused(TrayModel.airDropUnavailable("Notes.txt"))),
            pocket("S27", "Drop box on Free: a photo on WebP, with the Plus tag", .over,
                   sources: [.picture(.jpeg)], over: .choice(.picture(.webp)), extras: false),
            pocket("S28", "Drop box: a PDF on Split pages", .over, sources: [.pdf],
                   over: .choice(.splitPages)),
            pocket("S29", "Drop box: a film", .open, sources: [.video(isMP4: false)]),
            pocket("S30", "Drop box: an MP3 on Write it out", .over, sources: [.audio(nil)],
                   over: .choice(.writeItOut)),
            pocket("S31", "Drop box: a Word file", .open, sources: [.document(.word)]),
            pocket("S32", "Drop box: a folder and two files", .open, sources: [.folder, .pdf, .other]),
            pocket("S33", "Drop box on Free: remove background dropped, left where it was", .landed,
                   sources: [.picture(.heic)], note: .locked(.cutOut), extras: false),
            pocket("S34", "Drop box on Free: WebP dropped, left where it was, with See Plus", .landed,
                   sources: [.picture(.jpeg)], note: .locked(.picture(.webp), offerPlan: true), extras: false),
            // A window of its own under the notch, not part of the island.
            GalleryState("S35", area, "First three drags: the line under the notch") {
                DragHintLabel()
            },
        ]
    }

    // MARK: - Builders

    private static func shelf(_ id: String, _ name: String, items: [TrayItem],
                              ingesting: [String] = [], error: String? = nil, fix: TrayFix? = nil,
                              targeted: Bool = false, rejection: String? = nil,
                              pictures: [PictureSource] = [], over: PictureTarget? = nil) -> GalleryState {
        GalleryState(id, area, name) {
            TraySectionView()
                .environment(TrayModel(previewing: items, ingesting: ingesting, lastError: error,
                                       lastErrorFix: fix, layout: WorkspaceLayout(root: root)))
                .environment(drag(targeted: targeted, rejection: rejection, pictures: pictures, over: over))
        }
    }

    /// The island as the drop box (`DropPocket`), at the box's own width: it
    /// is all the island draws while it is up.
    private static func pocket(_ id: String, _ name: String, _ phase: DropPocket.Phase,
                               sources: [DropSource] = [], over: DropPocketTarget? = nil,
                               note: DropPocketNote? = nil, extras: Bool = true) -> GalleryState {
        let state = NotchUIState()
        // Every ability on, so the gallery draws the whole box whatever this
        // Mac's speech model says.
        state.pocketOffer = DropOffer.make(sources: sources, abilities: DropAbilities(
            writablePictures: DropReader.writablePictures, takesNotes: true))
        state.pocketExtras = extras
        state.overPocketTarget = over
        state.pocketNote = note
        return GalleryState(id, area, name, width: DropPocketLayout.width + 28) {
            DropPocketView(phase: phase)
                .environment(state)
                .environment(NotchAppearanceModel(defaults: plainLook))
                // Its ground is over-drawn for the island to clip; here
                // nothing else would, and it covers the picture's label.
                .clipped()
        }
    }

    /// A suite nothing writes to, so the box is drawn on the default black
    /// whatever look this Mac picked.
    private static let plainLook = UserDefaults(suiteName: "com.airlock.state-gallery") ?? .standard

    /// A drag hovering over the panel, as the drop target reports it. The
    /// format row is this Mac's own: a format it can't write is not drawn.
    private static func drag(targeted: Bool, rejection: String?, pictures: [PictureSource],
                             over: PictureTarget?) -> NotchUIState {
        let state = NotchUIState()
        state.isDropTargeted = targeted
        state.dropRejection = rejection
        state.pictureOffer = PictureOffer.make(sources: pictures,
                                               writable: PictureConverter.writableTypeIdentifiers)
        state.overPictureTarget = over
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

    private static let onePhoto: [PictureSource] = [.picture(.heic)]
    private static let threePictures: [PictureSource] = [.picture(.heic), .picture(.png), .picture(.webp)]
}
