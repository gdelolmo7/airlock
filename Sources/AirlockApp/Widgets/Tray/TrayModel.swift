import AppKit
import UniformTypeIdentifiers
import AirlockCore
import os

/// A shelf problem that a switch in System Settings fixes. The card then
/// offers that switch's pane instead of only naming it.
enum TrayFix: Equatable {
    /// Files and Folders › Downloads, for moving a file off the shelf.
    case downloadsAccess
    /// Automation › Finder, for "Add selection".
    case finderAutomation

    static let button = "Open Settings"

    var settingsURL: URL? {
        switch self {
        case .downloadsAccess:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        case .finderAutomation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        }
    }
}

struct TrayItem: Identifiable, Equatable {
    let url: URL
    let size: Int64
    let modified: Date
    let isDirectory: Bool
    /// False for a folder whose size walk has not reported back. Its `size` is
    /// then a placeholder 0, and an empty folder is a real 0 — this is what
    /// tells the two apart, so neither is drawn as "0 bytes" forever.
    var sizeIsKnown = true

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// The tray's contents, backed directly by `WorkspaceLayout.tray`.
///
/// The folder IS the model. No database, no security-scoped bookmarks — this
/// app isn't sandboxed, so a plain path is enough, and anything that touches
/// the folder (Finder, a script, an agent) shows up without telling us. That
/// also means an item is always a real file on disk, so dragging one out needs
/// no file promises — and it means removing a tile removes a file, which is why
/// `finishedDragOut` will not do it on anything less than the destination
/// saying, in the drag protocol's own words, that it took the file.
@MainActor
@Observable
final class TrayModel {
    private(set) var items: [TrayItem] = []
    /// Every write replaces the fix with nothing; a caller whose problem has a
    /// switch in System Settings names it straight after.
    private(set) var lastError: String? {
        didSet { lastErrorFix = nil }
    }
    /// The Settings pane that fixes `lastError`, when one does.
    private(set) var lastErrorFix: TrayFix?
    /// Names of files still landing on the shelf, in drop order. The file work
    /// runs off the main actor, so the shelf would otherwise sit unchanged for
    /// as long as a big file takes — which reads as a drop that missed the
    /// notch entirely. A same-volume move is instant; a cross-volume one costs
    /// exactly what a copy does, because underneath it is one.
    private(set) var ingesting: [String] = []
    /// Names on their way to the Trash. `NSWorkspace.recycle` is asynchronous
    /// and the folder watcher does not wait for it: a reload in the gap between
    /// asking and the file actually going finds it still on disk and puts the
    /// tile straight back. Removing an item and watching it reappear reads as a
    /// click that missed — and on a drag out, as the file not having left.
    private(set) var departing: [String] = []

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onNavigateAway: (() -> Void)?
    /// Dragging an item out means moving the pointer off the panel, which is
    /// exactly the gesture that collapses it. The controller pins it open.
    @ObservationIgnored var onDragOut: (() -> Void)?
    @ObservationIgnored private let layout: WorkspaceLayout
    @ObservationIgnored private var watch: DispatchSourceFileSystemObject?
    /// Measured folder sizes, keyed by path AND modification date so a folder
    /// whose contents changed gets measured again rather than reporting a stale
    /// total. Walking a directory is too slow to do on every reload.
    @ObservationIgnored private var directorySizes: [String: Int64] = [:]
    @ObservationIgnored private var measuring: Set<String> = []

    var directory: URL { layout.tray }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    init(layout: WorkspaceLayout = .resolve()) {
        self.layout = layout
    }

    /// A shelf for the state gallery: the tiles, arrivals and message it is
    /// handed, and no folder behind them. `start()` is never called on it, so
    /// nothing is created, watched or read — the URLs need not exist, and the
    /// user's real shelf never reaches a picture.
    init(previewing items: [TrayItem], ingesting: [String] = [], lastError: String? = nil,
         lastErrorFix: TrayFix? = nil, layout: WorkspaceLayout) {
        self.layout = layout
        self.items = items
        self.ingesting = ingesting
        self.lastError = lastError
        self.lastErrorFix = lastErrorFix
    }

    /// The shelf's own emptiness, so the VIEW and the DROP ROUTER cannot
    /// disagree about whether the rail has destinations on it. Disagreeing means
    /// an inbound drop finding a Trash card that is not drawn.
    var isEmpty: Bool { items.isEmpty && ingesting.isEmpty }

    func start() {
        do {
            try layout.ensureExists()
        } catch {
            lastError = Self.couldNotCreate(layout.root, error)
        }
        reload()
        startWatching()
    }

    deinit {
        watch?.cancel()
    }

    // MARK: - Reading

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: layout.tray,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        // Both `moveItem` and `copyItem` write straight to the destination, so
        // a file being ingested is already an entry in the folder — instantly
        // for a same-volume move, growing for everything else — and the watcher
        // reports it. It has a placeholder tile of its own; a second, half-
        // written one beside it — thumbnailing a truncated file — is not a
        // better answer. It appears when the file has fully landed.
        let inFlight = Set(ingesting)
        // The other direction, and the same reasoning: a file we have asked the
        // Trash for is gone as far as the shelf is concerned, from the instant
        // it is asked for rather than whenever the workspace gets round to it.
        let leaving = Set(departing)

        let next = contents.compactMap { url -> TrayItem? in
            guard !inFlight.contains(url.lastPathComponent) else { return nil }
            guard !leaving.contains(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let isDirectory = values?.isDirectory ?? false
            // Folders are legitimate shelf items — a dropped folder should not
            // silently vanish — but `fileSize` is nil for them, which is why one
            // read "Zero KB" with files inside. Their size comes from a walk.
            let measured = isDirectory ? directorySizes[Self.sizeKey(url, modified)] : nil
            let size = isDirectory ? (measured ?? 0) : Int64(values?.fileSize ?? 0)
            return TrayItem(url: url, size: size, modified: modified, isDirectory: isDirectory,
                            sizeIsKnown: !isDirectory || measured != nil)
        }
        // Newest first: the thing you just dropped is the thing you want.
        .sorted { $0.modified > $1.modified }

        guard next != items else { return }
        items = next
        onChange?()
        measureDirectories()
    }

    private static func sizeKey(_ url: URL, _ modified: Date) -> String {
        "\(url.path)|\(modified.timeIntervalSince1970)"
    }

    /// Off the main actor and only once per folder-version: a deep tree would
    /// otherwise stall the panel every time the watch fires.
    private func measureDirectories() {
        for item in items where item.isDirectory {
            let key = Self.sizeKey(item.url, item.modified)
            guard directorySizes[key] == nil, !measuring.contains(key) else { continue }
            measuring.insert(key)
            let url = item.url
            Task { [weak self] in
                // A recursive directory walk on a network mount blocks for as
                // long as the mount does — never on the cooperative pool.
                let size = await BlockingWork.run { Self.directorySize(at: url) }
                await MainActor.run {
                    guard let self else { return }
                    self.measuring.remove(key)
                    self.directorySizes[key] = size
                    self.reload()
                }
            }
        }
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in files {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Anything touching the folder — Finder, a script, an agent writing output
    /// — refreshes the tray without a poll.
    private func startWatching() {
        // Qualified: `open(_ item:)` below shadows the POSIX one for every
        // member of this type, and the unqualified call resolves to it.
        let descriptor = Darwin.open(layout.tray.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watch = source
    }

    // MARK: - Writing

    /// One entry point for a real drag: the pasteboard knows what it is, so it
    /// decides. Files move onto the shelf; a web image is written out as a
    /// file, because the pixels are already on the pasteboard and the person
    /// dragging a jpg out of a browser is, as far as they're concerned,
    /// dragging a jpg.
    ///
    /// `gesture` comes from the drag itself — see `NotchDropCatcher`, which is
    /// the only place that can read the source's operation mask.
    @discardableResult
    func accept(pasteboard: NSPasteboard, gesture: TrayIngestGesture) -> Bool {
        switch TrayDropKind.classify(typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []) {
        case .files:
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return accept(urls: urls, gesture: gesture)
        case .imageData:
            return acceptImage(from: pasteboard)
        case .webLink, .text, .unknown:
            return false
        }
    }

    /// The image flavours worth writing out, best first. Ordered, and the order
    /// is the point: PNG is lossless and already what the shelf wants, JPEG is
    /// what most of the web is, and TIFF is the one AppKit synthesises for
    /// anything else — taking it first would re-encode a perfectly good JPEG.
    private static let imageFlavours: [(identifier: String, extension: String)] = [
        ("public.png", "png"), ("public.jpeg", "jpg"), ("public.tiff", "tiff"),
    ]

    /// Browsers hand over TIFF as often as PNG. Normalising to PNG means the
    /// file you drag back out behaves like an image everywhere else. Idempotent
    /// — anything that isn't TIFF, and any TIFF that won't decode, comes back
    /// untouched — so both drop paths can call it without coordinating.
    private static func normalised(_ data: Data, _ ext: String) -> (Data, String) {
        guard ext == "tiff", let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return (data, ext) }
        return (png, "png")
    }

    private func imagePayload(on pasteboard: NSPasteboard) -> (Data, String)? {
        guard let payload = Self.imageFlavours.lazy
            .compactMap({ flavour in
                pasteboard.data(forType: NSPasteboard.PasteboardType(flavour.identifier))
                    .map { ($0, flavour.extension) }
            })
            .first else { return nil }
        return Self.normalised(payload.0, payload.1)
    }

    private func acceptImage(from pasteboard: NSPasteboard) -> Bool {
        guard let payload = imagePayload(on: pasteboard) else {
            lastError = Self.unreadableImage
            return false
        }
        return writeImage(payload.0, extension: payload.1, nameHint: nameHint(on: pasteboard))
    }

    /// The gap between "this is an image" and "these are bytes we can write":
    /// something advertised a flavour `TrayDropKind` recognises and then vended
    /// none of the three we know how to save. Rare, and it used to be silent on
    /// both paths — a drag that opened the notch, was classified as supported,
    /// and then simply did nothing.
    private nonisolated static let log = Logger(subsystem: "com.airlock.app", category: "shelf")
    private static let unreadableDrop = "That couldn't be read. Try dragging it again."

    /// What happened, then the plain cause. The system's own sentence goes to
    /// the log, never to the Shelf (`docs/how-airlock-talks.md`).
    private static func problem(_ what: String, _ error: any Error) -> String {
        log.error("\(what, privacy: .public) \(error.localizedDescription, privacy: .private)")
        return what + " " + PlainProblem.file(error)
    }

    private static let unreadableImage = "That picture couldn't be read. Save it first, then drag the file."

    // MARK: - Messages

    // Named, not inlined, so the state gallery prints the shipping words for
    // states it cannot cause.
    static func couldNotCreate(_ root: URL, _ error: Error) -> String {
        problem("The Shelf's folder couldn't be made, so nothing can go on it yet.", error)
    }
    static func couldNotSaveImage(_ error: Error) -> String {
        problem("The picture couldn't go on the Shelf.", error)
    }
    static func couldNotTrash(_ error: Error) -> String {
        problem("That couldn't be moved to the Trash.", error)
    }
    nonisolated static let needsDownloadsAccess =
        "Turn on Downloads for Airlock in System Settings › Privacy & Security › Files and Folders."
    static let airDropNeedsAFile = "AirDrop can only send files."
    static func airDropUnavailable(_ description: String) -> String {
        "AirDrop isn't available for \(description)."
    }
    static func couldNotOpen(_ name: String) -> String { "Couldn't open \(name)." }
    static let nothingSelectedInFinder = "Nothing is selected in Finder."
    /// Finder refused the question. It used to be reported as an empty
    /// selection, which sent people to select files that were already selected.
    static let finderNotAllowed =
        "Airlock isn't allowed to see what's selected in Finder. Turn on Finder for Airlock in Privacy & Security › Automation."

    /// Bytes with no file behind them, turned into one on the shelf.
    ///
    /// Deliberately NOT routed through `TrayIngestPlan`. That machinery is about
    /// taking a file from where it lives, and its whole subtlety — move versus
    /// copy, the recovery when a move half-happens — is about not losing the
    /// original. There is no original here: the pixels exist only on the drag,
    /// so there is nothing a move could empty and nothing it could lose. Both
    /// drop paths land here, so a web image is written the same way whether it
    /// crossed the cutout or the open panel.
    @discardableResult
    private func writeImage(_ data: Data, extension ext: String, nameHint: String?) -> Bool {
        do {
            try layout.ensureExists()
        } catch {
            lastError = Self.problem("The picture couldn't go on the Shelf.", error)
            return false
        }

        let payload = Self.normalised(data, ext)
        let name = WorkspaceLayout.uniqueName(
            for: WorkspaceLayout.droppedImageName(hint: nameHint, extension: payload.1),
            existing: Set(items.map(\.name)))
        do {
            try payload.0.write(to: layout.tray.appendingPathComponent(name), options: .atomic)
            // A drop that worked retires the last one's complaint.
            lastError = nil
            reload()
            return true
        } catch {
            lastError = Self.couldNotSaveImage(error)
            return false
        }
    }

    /// Borrow the name from the source URL when there is one — "puppy.jpg" is a
    /// better shelf item than "Dropped image.png".
    private func nameHint(on pasteboard: NSPasteboard) -> String? {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
            .first?.lastPathComponent
    }

    /// The same decision as `accept(pasteboard:gesture:)`, for the drop path
    /// that has no pasteboard: SwiftUI hands over item providers and nothing
    /// else. `registeredTypeIdentifiers` is the same vocabulary the pasteboard
    /// speaks, so the classifier is the same one and the answer is the same
    /// answer — which is the whole point. This used to take file URLs only, so
    /// a browser image or a Mail attachment dropped on the OPEN panel did
    /// nothing while the identical drag onto the cutout worked.
    ///
    /// Flattened across providers deliberately: a multi-file drag is N
    /// providers all saying `public.file-url`, and `classify` ranks by kind
    /// rather than by count, so one file among them still makes it a file drop.
    @discardableResult
    func accept(providers: [NSItemProvider], gesture: TrayIngestGesture) -> Bool {
        switch TrayDropKind.classify(
            typeIdentifiers: providers.flatMap(\.registeredTypeIdentifiers)) {
        case .files:
            return acceptFiles(from: providers, gesture: gesture)
        case .imageData:
            return acceptImage(from: providers)
        case .webLink, .text, .unknown:
            return false
        }
    }

    /// Bytes off a drag that carries no file — the panel-side twin of
    /// `acceptImage(from pasteboard:)`, landing in the same `writeImage`.
    ///
    /// The data is read rather than the file representation, and that is not an
    /// accident. `loadFileRepresentation` materialises a temp file that AppKit
    /// deletes the moment the completion handler returns, so anything that took
    /// it as an ingest source would be racing the deletion — and the ingest path
    /// now MOVES its source, which turns that race into a lost file rather than
    /// a failed drop. There is no file here to move; there are pixels, and they
    /// get written.
    private func acceptImage(from providers: [NSItemProvider]) -> Bool {
        guard let (provider, flavour) = providers.lazy.compactMap({ provider in
            Self.imageFlavours.lazy
                .first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
                .map { (provider, $0) }
        }).first else {
            lastError = Self.unreadableImage
            return false
        }

        let hint = provider.suggestedName
        let ext = flavour.extension
        provider.loadDataRepresentation(forTypeIdentifier: flavour.identifier) { [weak self] data, error in
            // The reason, not the error: `any Error` is not `Sendable`.
            let reason: String? = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                guard let data else {
                    if let reason { Self.log.error("shelf read: \(reason, privacy: .private)") }
                    self.lastError = Self.unreadableDrop
                    return
                }
                self.writeImage(data, extension: ext, nameHint: hint)
            }
        }
        return true
    }

    /// Finder hands files over as `public.file-url`, which SwiftUI's
    /// `dropDestination(for: URL.self)` does NOT accept — the window declines
    /// the drag and it falls through to whatever is behind the notch. Taking
    /// providers and reading that type explicitly is what actually works, and
    /// matches what the drop catcher registers.
    ///
    /// A provider will not say what it holds until it has loaded it, so the
    /// most AppKit can be told synchronously is "at least one of these is a
    /// file". What it must NOT be told is that the drop worked: this used to
    /// return an unconditional `true` while a provider that produced no URL
    /// returned silently, so a failed drop reported success, left nothing on
    /// the shelf and said nothing. Every load now ends in a tile or in
    /// `lastError`.
    ///
    /// `gesture` is sampled by the caller, at the instant of the drop, and
    /// carried into the completion — a provider answers whenever it feels like
    /// it, and by then the Option key has long since come up.
    private func acceptFiles(from providers: [NSItemProvider], gesture: TrayIngestGesture) -> Bool {
        let fileURL = UTType.fileURL.identifier
        let usable = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURL) }
        guard !usable.isEmpty else { return false }

        for provider in usable {
            provider.loadItem(forTypeIdentifier: fileURL, options: nil) { [weak self] item, error in
                // The payload is a bookmark-style Data more often than a URL.
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? (item as? URL)
                // The reason, not the error: `any Error` is not `Sendable` and
                // must not cross onto the main actor.
                let reason: String? = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    guard let url else {
                        if let reason { Self.log.error("shelf read: \(reason, privacy: .private)") }
                        self.lastError = Self.unreadableDrop
                        return
                    }
                    self.accept(urls: [url], gesture: gesture)
                }
            }
        }
        return true
    }

    /// A file dragged onto the CUTOUT moves onto the shelf: drag something out
    /// of Downloads and it leaves Downloads, the way it would if you had
    /// dragged it into a folder. Hold Option and it copies instead, which is
    /// the same escape hatch Finder gives you. `TrayIngestDisposition.decide`
    /// is where that is written down, and `place(_:)` is what never lets a move
    /// lose the file. A drop on the open panel copies — that seam cannot see
    /// the source's operation mask, so it does not claim one
    /// (`gestureFromPanelDrop`).
    ///
    /// The seam: `gesture` defaults to `.handoff`, which copies. Non-drag entry
    /// points — `open -a Airlock <file>`, a share sheet, an agent handing us a
    /// path — have no gesture to read intent from and no Option key to escape
    /// with, so taking someone's file on the strength of "it was passed to
    /// Airlock" would be a guess with a destructive wrong answer. Only a caller
    /// that actually watched a drag says otherwise, and it has to say so.
    ///
    /// The answer is what AppKit is told about the drop, so it says only what
    /// is knowable at this instant: these are real file URLs and at least one
    /// of them is going onto the shelf. Whether it SUCCEEDS cannot be answered
    /// here — it runs off the main actor precisely because it can take seconds
    /// — so that half arrives where a person can see it: placeholder tiles
    /// while it runs, and `lastError` if it fails.
    @discardableResult
    func accept(urls: [URL], gesture: TrayIngestGesture = .handoff) -> Bool {
        guard !urls.isEmpty else { return false }
        do {
            try layout.ensureExists()
        } catch {
            lastError = Self.problem("That couldn't go on the Shelf.", error)
            return false
        }

        let plan = TrayIngestPlan.plan(sources: urls, tray: layout.tray,
                                       existing: Set(items.map(\.name)).union(ingesting),
                                       gesture: gesture)
        guard !plan.isEmpty else { return false }

        ingesting.append(contentsOf: plan.names)
        Task { [weak self] in
            // A cross-volume move is a copy underneath, so a few GB blocks for
            // as long as the bytes take and a network mount for as long as the
            // mount does — never on the cooperative pool, and never on the main
            // actor, which is where it used to happen with the panel frozen
            // until it finished.
            let result = await BlockingWork.run { Self.ingest(plan) }
            self?.finish(plan, result)
        }
        return true
    }

    /// Runs on whatever thread `BlockingWork` hands it, so it touches nothing
    /// but the plan it was given and reports back as a value. Static and
    /// `nonisolated` for the same reason `directorySize(at:)` is.
    private nonisolated static func ingest(_ plan: TrayIngestPlan) -> TrayIngestResult {
        var added = 0
        var failures: [TrayIngestResult.Failure] = []
        for item in plan.items {
            do {
                try place(item)
                added += 1
            } catch {
                Self.log.error("shelf add: \(error.localizedDescription, privacy: .private)")
                failures.append(TrayIngestResult.Failure(name: item.source.lastPathComponent,
                                                         reason: PlainProblem.file(error)))
            }
        }
        return TrayIngestResult(added: added, failures: failures)
    }

    /// Move where it can, copy where it must, and never lose the file.
    ///
    /// `moveItem` fails for a source the user cannot remove — inside a mounted
    /// DMG, on a read-only volume, in somebody else's directory — and that is
    /// not a reason to refuse the drop. It falls back to copying and counts as
    /// a success with the original left where it was: the shelf gets the file
    /// either way, and the difference is only whether the source still has it.
    ///
    /// The recovery itself is decided in Core (`TrayMoveRecovery`), from what
    /// the two paths look like afterwards rather than from the error, because
    /// a cross-volume move is a copy-then-delete underneath and can fail in the
    /// middle. `predated` is sampled BEFORE the attempt for one reason: it is
    /// the only way to tell our own half-written debris, which is safe to
    /// clear, from a file that was already sitting there, which is not.
    private nonisolated static func place(_ item: TrayIngestPlan.Item) throws {
        let manager = FileManager.default
        guard item.disposition == .move else {
            try manager.copyItem(at: item.source, to: item.destination)
            return
        }
        let predated = manager.fileExists(atPath: item.destination.path)
        do {
            try manager.moveItem(at: item.source, to: item.destination)
        } catch let moveFailure {
            switch TrayMoveRecovery.after(
                sourceExists: manager.fileExists(atPath: item.source.path),
                destinationExists: manager.fileExists(atPath: item.destination.path),
                destinationPredated: predated) {
            case .succeeded:
                return
            case let .copy(clearingDestination):
                if clearingDestination { try? manager.removeItem(at: item.destination) }
                // The copy's own error, not the move's: it is the one that
                // actually stopped the file arriving.
                try manager.copyItem(at: item.source, to: item.destination)
            case .giveUp:
                throw moveFailure
            }
        }
    }

    /// SwiftUI's `onDrop` hands over providers and nothing else — no
    /// `NSDraggingInfo`, so no source operation mask. **So this path copies.**
    ///
    /// That is a real difference from the cutout, which moves, and it is the
    /// honest one. "The source will let this go" is not knowable here, and the
    /// old reading — Option is not held, therefore move — turned that gap into
    /// an assumption: a source offering copy only got a `.move` badge on the
    /// panel and had its file taken. `place(_:)` recovering from a refused
    /// `moveItem` does not undo that, because a move the source ALLOWS but the
    /// user never asked for succeeds, and the file is gone from where they left
    /// it. The shelf does not lose files, so unknown is copy.
    ///
    /// The modifier is read anyway, and passed on: it costs nothing, it keeps
    /// this the same question `DropCatcherView.gesture(of:)` asks, and it is
    /// the half that stays true if a future seam can see a mask.
    static func gestureFromPanelDrop() -> TrayIngestGesture {
        .fromPointerDrag(sourceAllowsMove: nil,
                         optionHeld: NSEvent.modifierFlags.contains(.option))
    }

    private func finish(_ plan: TrayIngestPlan, _ result: TrayIngestResult) {
        let landed = Set(plan.names)
        ingesting.removeAll { landed.contains($0) }
        // Set, not appended to: a drop that worked clears what the last one
        // complained about, so nobody is left staring at an error about a file
        // that has since arrived.
        lastError = result.message
        reload()
    }

    /// The tray is visible for far longer than any one message is true for, so
    /// the message needs a way out that isn't "drop something else".
    // MARK: - The destinations rail

    /// Only what the shelf owns.
    ///
    /// TWO independent gates, and both are load-bearing:
    ///  1. REACHABILITY — `.trash` and `.downloads` are only ever returned by
    ///     `railDestination(at:)` while a drag-out is in progress, i.e. a drag
    ///     that began on a tile.
    ///  2. OWNERSHIP — every URL must be a direct child of the tray. This holds
    ///     even if (1) is wrong, and the drag-out flag getting stuck ON is a
    ///     failure this code has actually had. It is what makes the guarantee
    ///     structural rather than stateful.
    ///
    /// The shelf holds no references: every ingest is a `moveItem` or a
    /// `copyItem`, so a shelf file is either a duplicate or the user's ONLY
    /// copy — and nothing records which. Both rail verbs therefore treat every
    /// item as possibly-the-only-copy.
    private func shelfURLs(on pasteboard: NSPasteboard) -> [URL] {
        guard case .files = TrayDropKind.classify(
            typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []) else { return [] }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let owned = TrayShelfOwnership.filter(urls, tray: layout.tray)
        if owned.isEmpty && !urls.isEmpty { lastError = "Only things on the Shelf can go there." }
        return owned
    }

    /// Straight to `recycle`, which is the whole point: it goes to the Finder
    /// Trash and never `removeItem`. There is no undo anywhere in this app, so
    /// the Trash IS the undo — a wrong drop is one drag back out of it.
    ///
    /// Never introduce `removeItem`, `trashItem`, or a "skip the Trash for large
    /// files" fast path here.
    @discardableResult
    func trashFromShelf(pasteboard: NSPasteboard) -> Bool {
        lastError = nil
        let urls = shelfURLs(on: pasteboard)
        guard !urls.isEmpty else { return false }
        recycle(urls)
        return true
    }

    @discardableResult
    func moveToDownloads(pasteboard: NSPasteboard) -> Bool {
        lastError = nil
        let urls = shelfURLs(on: pasteboard)
        guard !urls.isEmpty else { return false }
        moveOut(urls)
        return true
    }

    /// The context-menu and VoiceOver route to the same place.
    func moveToDownloads(_ item: TrayItem) {
        lastError = nil
        moveOut([item.url])
    }

    private func moveOut(_ urls: [URL]) {
        guard let downloads = try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else {
            lastError = "Your Downloads folder couldn't be found."
            return
        }
        // The tile leaves at once and comes BACK if the move fails — the same
        // contract `recycle` has, so a failure is never a file that silently
        // vanished from the shelf.
        let names = urls.map(\.lastPathComponent)
        departing.append(contentsOf: names)
        reload()
        Task { [weak self] in
            let result = await BlockingWork.run { Self.relocate(urls, into: downloads) }
            guard let self else { return }
            let landed = Set(names)
            self.departing.removeAll { landed.contains($0) }
            self.lastError = result.message
            // The message carries the first failure's reason, so the button
            // follows the same one.
            if result.failures.first?.reason == Self.needsDownloadsAccess {
                self.lastErrorFix = .downloadsAccess
            }
            self.reload()
        }
    }

    /// Off the main actor, because this is file I/O.
    ///
    /// **This deliberately does NOT go through `place(_:)`.** That path calls
    /// `removeItem(at: item.destination)` under `.copy(clearingDestination:)`,
    /// which is sound inside a folder Airlock owns and wrong in `~/Downloads` —
    /// the one directory where browsers and mail clients create files at names
    /// they choose, asynchronously. Clearing a destination there can delete
    /// something the user is mid-download.
    ///
    /// The guarantee is `moveItem` itself: it THROWS on an existing file rather
    /// than clobbering. The unique name only avoids the error in the common
    /// case. There is no `replaceItemAt` and no `removeItem` on the destination
    /// anywhere in this function, and there must never be.
    private nonisolated static func relocate(_ urls: [URL],
                                             into directory: URL) -> TrayRelocationResult {
        let manager = FileManager.default
        var moved: [String] = []
        var failures: [TrayRelocationResult.Failure] = []

        for url in urls {
            let name = url.lastPathComponent
            var attempt = 0
            while true {
                attempt += 1
                // A FRESH listing each attempt, and hidden files included — a
                // failed listing does not mean "empty", it means fall through
                // with the plain name and let `moveItem` be the judge.
                let existing = Set((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
                let unique = WorkspaceLayout.uniqueName(for: name, existing: existing)
                do {
                    try manager.moveItem(at: url, to: directory.appendingPathComponent(unique))
                    moved.append(name)
                    break
                } catch let error as NSError
                    where error.code == NSFileWriteFileExistsError && attempt < 5 {
                    // Something was created between the listing and the move.
                    // Bounded, so a directory churning faster than we can read it
                    // reports rather than spins.
                    continue
                } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
                    failures.append(.init(name: name, reason: Self.needsDownloadsAccess))
                    break
                } catch {
                    // A cross-volume move can report failure after the rename
                    // landed, so ask the filesystem rather than the error.
                    // `destinationPredated` is false by construction: we only
                    // ever attempt a name the listing said was free, and a name
                    // that was taken throws fileExists above instead.
                    let recovery = TrayMoveRecovery.after(
                        sourceExists: manager.fileExists(atPath: url.path),
                        destinationExists: true,
                        destinationPredated: false)
                    if case .succeeded = recovery {
                        moved.append(name)
                    } else {
                        // `.copy` is REPORTED, never taken: completing a degraded
                        // move by deleting the shelf copy is how a file ends up
                        // in neither place.
                        Self.log.error("shelf move: \(error.localizedDescription, privacy: .private)")
                        failures.append(.init(name: name, reason: PlainProblem.file(error)))
                    }
                    break
                }
            }
        }
        return TrayRelocationResult(moved: moved, failures: failures, destination: "Downloads")
    }

    func dismissError() {
        lastError = nil
    }

    /// The card's button when the problem has a switch: open its pane, and put
    /// the card away — the person is now looking at System Settings.
    func openFix() {
        if let url = lastErrorFix?.settingsURL { NSWorkspace.shared.open(url) }
        lastError = nil
        onNavigateAway?()
    }

    /// To the Trash, never unlinked — recoverable matters when the same tree is
    /// a workspace you might be mid-thought in.
    func remove(_ item: TrayItem) {
        recycle([item.url])
    }

    func clear() {
        guard !items.isEmpty else { return }
        recycle(items.map(\.url))
    }

    /// The tile goes first and the file follows. Names are enough to key it:
    /// one folder cannot hold two of them.
    ///
    /// A failure puts the item back rather than leaving a tile that is gone from
    /// the shelf and present on disk — the shelf IS the folder, so the two
    /// disagreeing is the one state it must never be left in.
    private func recycle(_ urls: [URL]) {
        let names = urls.map(\.lastPathComponent)
        departing.append(contentsOf: names)
        reload()
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                let landed = Set(names)
                self.departing.removeAll { landed.contains($0) }
                if let error { self.lastError = Self.couldNotTrash(error) }
                self.reload()
            }
        }
    }

    func beganDragOut() {
        onDragOut?()
    }

    /// The end of a drag that started on a tile, and the ONLY route by which a
    /// drag removes anything.
    ///
    /// `operation` is what the destination chose, reported by AppKit once the
    /// drag has resolved — see `TrayTileDragSource`. SwiftUI's `.onDrag` cannot
    /// produce it, which is why the tile no longer uses `.onDrag`: it hands back
    /// an item provider and never says whether the drop happened, so a drag
    /// abandoned over the desktop and a file filed into a folder look identical
    /// from here. Guessing between them deletes files.
    ///
    /// The rule itself is `TrayDragOutcome.decide`, in Core, where it can be
    /// tested. This half is only the two things it needs from the filesystem:
    /// whether the file is still there, and the Trash.
    func finishedDragOut(_ item: TrayItem, operation: TrayDragOperation) {
        let outcome = TrayDragOutcome.decide(
            operation: operation,
            sourceExists: FileManager.default.fileExists(atPath: item.url.path))
        switch outcome {
        case .keep:
            break
        case .trash:
            // Through `remove`, so a file that left by drag is recoverable from
            // exactly where a file removed by the x is.
            remove(item)
        case .vanished:
            reload()
        }
    }

    // MARK: - Navigation

    /// AirDrop only, not the whole share picker. Every other share destination
    /// is reachable by dragging the item into the app you want, which is the
    /// tray's whole premise — sending to another device is the one thing a drag
    /// genuinely can't do.
    ///
    /// Invoked directly rather than through `NSSharingServicePicker`: the picker
    /// is a popover needing an `NSView` anchor inside a panel that collapses on
    /// hover-out, which would orphan it. AirDrop presents its own window and
    /// needs no anchor.
    /// Dropped straight onto the AirDrop box — send it without shelving it, and
    /// without touching where it came from. Passing through the tray first
    /// would now MOVE something you were only ever routing to another device:
    /// the file would leave its folder as a side effect of sending it.
    @discardableResult
    func airDrop(pasteboard: NSPasteboard) -> Bool {
        let urls: [URL]
        switch TrayDropKind.classify(typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []) {
        case .files:
            urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        case .imageData:
            // Nothing on disk to send yet, so stage it outside the tray.
            urls = stageImageForSending(from: pasteboard).map { [$0] } ?? []
        case .webLink, .text, .unknown:
            lastError = Self.airDropNeedsAFile
            return false
        }
        guard !urls.isEmpty else { return false }
        return send(urls, describedAs: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
    }

    private func stageImageForSending(from pasteboard: NSPasteboard) -> URL? {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-notch-airdrop", isDirectory: true)
        guard let (data, ext) = imagePayload(on: pasteboard),
              (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil
        else { return nil }
        let url = staging.appendingPathComponent(
            WorkspaceLayout.droppedImageName(hint: nameHint(on: pasteboard), extension: ext))
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    func airDrop(_ item: TrayItem) {
        send([item.url], describedAs: item.name)
    }

    @discardableResult
    private func send(_ urls: [URL], describedAs description: String) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else {
            lastError = Self.airDropUnavailable(description)
            return false
        }
        // An accessory app is never frontmost, so without this the AirDrop
        // window opens behind whatever you were looking at.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
        onNavigateAway?()
        return true
    }

    /// Opens the item in whatever owns its type — a folder opens in Finder.
    /// `onNavigateAway` for the same reason the other two have it: the app that
    /// comes forward would otherwise leave the panel pinned behind it.
    func open(_ item: TrayItem) {
        guard NSWorkspace.shared.open(item.url) else {
            lastError = Self.couldNotOpen(item.name)
            return
        }
        onNavigateAway?()
    }

    func reveal(_ item: TrayItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        onNavigateAway?()
    }

    /// Take whatever is selected in Finder, without a drag.
    ///
    /// **The shelf had exactly one way in.** A drag is fine when your hand is
    /// already on the file, and useless when the panel is open and Finder is
    /// behind it — the drop target is a 640pt panel that collapses when you
    /// leave it, so the gesture you need is the one you cannot perform. This is
    /// the same ingest path a drop takes (`accept(urls:)`), so nothing about
    /// what lands on the shelf differs by how it got there.
    ///
    /// `.handoff` rather than `.move`: a selection you did not drag is one you
    /// probably did not mean to remove from where it was.
    func addFinderSelection() async {
        let script = "tell application \"Finder\" to get POSIX path of (selection as alias list)"
        let outcome = await AppleScriptClient.perform(script)
        // Refused is not empty. Any OTHER failure still reads as nothing
        // selected, because that is what an empty selection looks like here:
        // Finder cannot take the POSIX path of an empty list, and says so.
        if outcome.isNotPermitted {
            lastError = Self.finderNotAllowed
            lastErrorFix = .finderAutomation
            return
        }
        guard case .ok(let output?) = outcome, !output.isEmpty else {
            lastError = Self.nothingSelectedInFinder
            return
        }
        let urls = output
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else {
            lastError = Self.nothingSelectedInFinder
            return
        }
        _ = accept(urls: urls, gesture: .handoff)
    }

    func openFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([layout.tray])
        onNavigateAway?()
    }
}
