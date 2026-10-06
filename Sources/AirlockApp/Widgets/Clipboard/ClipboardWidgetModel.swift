import AppKit
import CryptoKit
import Observation
import AirlockCore

/// Watches the pasteboard and owns the history.
///
/// Polling, not observing: macOS posts no notification when the pasteboard
/// changes. `changeCount` incrementing is the only signal there is, which is why
/// every clipboard manager on the platform runs a timer.
///
/// The model does the I/O — timer, `NSPasteboard`, files. What the list *is*
/// stays in `ClipboardHistory`, which is pure and tested.
@MainActor
@Observable
final class ClipboardWidgetModel {
    private(set) var history = ClipboardHistory()

    /// Seeded history, for tests.
    ///
    /// The selection rules — nothing highlighted until you pick, arrows entering
    /// from either end, a query clearing the highlight — are the part of this
    /// model worth asserting about, and they are meaningless against an empty
    /// list. Everything else here reaches the pasteboard or the disk, so this is
    /// the one seam that buys coverage rather than ceremony.
    init(history: ClipboardHistory = ClipboardHistory()) {
        self.history = history
    }

    /// A model for the state gallery: made-up items and settings, and nothing
    /// that reaches the Mac.
    ///
    /// Every setting is written to its BACKING storage, because assigning the
    /// property from an `@Observable` init still runs its `didSet` — and those
    /// write preferences, start the pasteboard timer, register the hotkey, and
    /// for auto-paste put up the Accessibility prompt. The user's own ignored
    /// apps are left out of the picture, and so is the real Accessibility
    /// answer: `pasteTrusted` stands in for it. Nothing calls `start()`, so the
    /// history on disk is never read.
    init(previewing history: ClipboardHistory, filter: ClipboardFilter = .all, query: String = "",
         isEnabled: Bool = true, pastesAutomatically: Bool = false, pasteTrusted: Bool = true,
         lastSkip: ClipboardSkipReason? = nil, hotkeyError: String? = nil,
         missingPictures: Set<String> = [], pictureGoneNotice: Bool = false) {
        self.history = history
        self.filter = filter
        self.query = query
        self.lastSkip = lastSkip
        self.hotkeyError = hotkeyError
        _isEnabled = isEnabled
        _pastesAutomatically = pastesAutomatically
        _capacity = ClipboardHistory.defaultCapacity
        _hotkeyEnabled = true
        _hotkey = .commandShiftC
        _ignoresPasswordManagerTypes = true
        extraIgnoredApps = []
        previewPasteTrusted = pasteTrusted
        previewMissingPictures = missingPictures
        if pictureGoneNotice {
            pictureGone = history.items.first { $0.imageFile.map(missingPictures.contains) == true }?.id
        }
    }

    /// Set only by the gallery's init. Its presence is also what keeps the
    /// key monitor and the image store out of a preview.
    @ObservationIgnored private var previewPasteTrusted: Bool?
    private var isPreview: Bool { previewPasteTrusted != nil }

    /// Whether ⌘V can be posted — what the auto-paste warning is drawn from.
    var pasteIsTrusted: Bool { previewPasteTrusted ?? PasteService.isTrusted }
    /// Search text. Not persisted — a query is about the next few seconds.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Cleared, not moved to the top hit. A highlight the user did not
            // ask for is one Return can act on by surprise, and the rows under
            // it change with every keystroke.
            selection = nil
            scrollTarget = nil
        }
    }
    /// The highlighted row, or nil for "the user has not chosen one".
    ///
    /// **Nil is the opening state, deliberately.** This used to preselect the
    /// first row whenever the panel opened, which put a highlight on whatever
    /// happened to be pinned first and made Return act on it — a paste nobody
    /// aimed. A selection now only exists once the pointer is over a row or the
    /// arrow keys have moved to one.
    ///
    /// Model state rather than view state because the key monitor below needs
    /// it, and a monitor closure capturing SwiftUI @State captures a snapshot
    /// that goes stale on the first keystroke.
    var selection: UUID?
    /// Only ever set by the keyboard, so moving the mouse cannot move the list.
    private(set) var scrollTarget: UUID?
    /// Briefly set on the row a shortcut fired, so pressing ⌘4 shows you which
    /// row ⌘4 was before the panel goes.
    private(set) var flashing: UUID?
    /// Why the last change was not kept. Shown in Settings so "it didn't record
    /// my copy" has an answer.
    private(set) var lastSkip: ClipboardSkipReason? {
        didSet { skipNoticeDismissed = false }
    }
    /// Set by the notice's Close; any later skip brings a notice back.
    private var skipNoticeDismissed = false

    /// What the clipboard tab says about the last copy, when it was too large
    /// to keep. Only that reason: the others are either private by design (a
    /// password manager's copy is SUPPOSED to vanish) or not worth a card, and
    /// Settings still names every one of them.
    var skipNotice: String? {
        guard !skipNoticeDismissed, case .tooLarge(let bytes) = lastSkip else { return nil }
        return ClipboardSkipReason.tooLargeNotice(bytes: bytes)
    }

    func dismissSkipNotice() { skipNoticeDismissed = true }

    // MARK: Pictures whose file is gone

    /// The row a picture was picked from when its file had gone. Nil once the
    /// row is removed, the card is closed, or something else is picked.
    private(set) var pictureGone: UUID?

    /// What the card says when a picture row's file has gone. The clipboard is
    /// left as it was: emptying it and then having nothing to put there is the
    /// bug this replaced.
    static let pictureGoneSentence = "That picture is no longer saved, so the clipboard wasn't changed."
    static let pictureGoneButton = "Remove it"
    /// The row's own words in place of the picture's.
    static let missingPictureRowText = "Picture no longer saved"

    /// The gallery's stand-in for the image folder. Nil outside a preview.
    @ObservationIgnored private var previewMissingPictures: Set<String>?

    /// Whether this row is a picture whose saved file is no longer there.
    func pictureIsMissing(_ item: ClipboardItem) -> Bool {
        guard let file = item.imageFile else { return false }
        if let previewMissingPictures { return previewMissingPictures.contains(file) }
        return !FileManager.default.fileExists(atPath: store.imageURL(for: file).path)
    }

    func removeGonePicture() {
        guard let id = pictureGone else { return }
        pictureGone = nil
        if let item = history.item(id: id) { delete(item) }
    }
    private(set) var hotkeyError: String?

    var isEnabled: Bool = WidgetToggle.stored("widget.clipboard.enabled", default: true) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            isEnabled ? startPolling() : stopPolling()
            // The hotkey's only job is to open the panel on the clipboard tab,
            // and a switched-off widget has no such tab — the key still fired
            // and landed on Home, with nothing on screen to say why. Note that
            // `hotkeyEnabled` is deliberately not written here: the preference
            // is the user's stated choice and has to come back intact when the
            // widget does. Registration is a function of both flags instead.
            applyHotkey()
        }
    }

    var capacity: Int = Defaults.int("clipboard.capacity", default: ClipboardHistory.defaultCapacity) {
        didSet {
            guard capacity != oldValue else { return }
            Defaults.set(capacity, "clipboard.capacity")
            history.trim(to: capacity)
            prune()
            save()
        }
    }

    /// Opt-in, because it is the only part of this that needs Accessibility.
    var pastesAutomatically: Bool = Defaults.bool("clipboard.autoPaste", default: false) {
        didSet {
            guard pastesAutomatically != oldValue else { return }
            Defaults.set(pastesAutomatically, "clipboard.autoPaste")
            if pastesAutomatically && !PasteService.isTrusted { PasteService.requestTrust() }
        }
    }

    var hotkeyEnabled: Bool = Defaults.bool("clipboard.hotkeyEnabled", default: true) {
        didSet {
            guard hotkeyEnabled != oldValue else { return }
            Defaults.set(hotkeyEnabled, "clipboard.hotkeyEnabled")
            applyHotkey()
        }
    }

    var hotkey: GlobalHotkey.Binding = Defaults.binding("clipboard.hotkey",
                                                        default: .commandShiftC) {
        didSet {
            guard hotkey != oldValue else { return }
            Defaults.setBinding(hotkey, "clipboard.hotkey")
            applyHotkey()
        }
    }

    /// Ignoring a vendor marker is the user's call; the always-ignored set in
    /// `PasteboardClassifier` is not, and is not represented here.
    var ignoresPasswordManagerTypes: Bool = Defaults.bool("clipboard.ignoreVendorTypes", default: true) {
        didSet {
            Defaults.set(ignoresPasswordManagerTypes, "clipboard.ignoreVendorTypes")
            rebuildClassifier()
        }
    }

    /// Raised when the hotkey fires, so the controller can open the panel on
    /// this tab. Set by whoever owns both.
    var onHotkey: (() -> Void)?
    /// Taking an item is an exit — you have what you came for and are heading
    /// back to whatever you were typing in. Same contract the tray and the
    /// terminal jump already use.
    var onNavigateAway: (() -> Void)?

    @ObservationIgnored private let store = ClipboardStore()
    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.clipboard.enabled", defaultValue: true)
    @ObservationIgnored private let hotkeyRegistration = GlobalHotkey()
    @ObservationIgnored private var classifier = PasteboardClassifier()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?

    /// Maccy's default, and about right: fast enough that the panel is current
    /// by the time you have moved the mouse, slow enough to be free.
    private static let pollInterval: TimeInterval = 0.5

    /// Not persisted, deliberately. A filter is a thing you do to the list you
    /// are looking at now; finding the panel still showing only images tomorrow,
    /// with no memory of having chosen that, reads as a broken clipboard.
    var filter: ClipboardFilter = .all

    /// Worked out once per change, not once per read. The view reads this about
    /// eight times a redraw (list, footer, shortcuts, the pinned divider, the
    /// animation key), and it used to filter the whole history every time.
    /// The comparison is cheap: an unchanged history shares its storage, and
    /// arrays that share storage compare equal without reading anything.
    var items: [ClipboardItem] {
        let history = history, query = query, filter = filter
        if let cached = shownCache, cached.filter == filter, cached.query == query,
           cached.history == history {
            return cached.items
        }
        let shown = history.matching(query).filter(filter.matches)
        shownCache = (history, query, filter, shown)
        return shown
    }
    @ObservationIgnored private var shownCache: (history: ClipboardHistory, query: String,
                                                 filter: ClipboardFilter, items: [ClipboardItem])?

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What Settings prints under "Stored at". Asked of the store that actually
    /// writes the files, so the two cannot drift — the hardcoded copy there did,
    /// and named a directory that has not existed since the rename.
    var storageDirectory: String { store.displayDirectory }

    func start() {
        history = store.load()
        history.mergeRepeatedText()
        history.trim(to: capacity)
        rebuildClassifier()
        prune()
        applyHotkey()
        if isEnabled { startPolling() }
    }

    // MARK: - Capture

    private func startPolling() {
        stopPolling()
        // `.common` so the timer keeps firing while a menu is open or a window
        // is being dragged — the default mode stalls in exactly the moments
        // people copy things.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        capture(from: pasteboard)
    }

    /// Text this app is about to write, which must not come back as history.
    ///
    /// The frontmost-bundle check below cannot cover it: the notch is a
    /// `.nonactivatingPanel`, so it is NEVER frontmost, and a copy made from it
    /// would be recorded and attributed to whatever app happens to be in front.
    ///
    /// A fingerprint rather than a flag, because the pasteboard poll may fire
    /// either side of our write and a flag would have to guess which. The expiry
    /// stops a suppression that never matched from swallowing a real copy later.
    private var suppressedFingerprint: (value: String, until: Date)?

    func suppressNextCopy(of text: String) {
        suppressedFingerprint = (ClipboardItem.fingerprint(forText: text),
                                 Date().addingTimeInterval(2))
    }

    private func capture(from pasteboard: NSPasteboard) {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let source = NSWorkspace.shared.frontmostApplication
        // Our own writes are never new copies. Selecting a row would otherwise
        // re-record it a moment later and reshuffle the list under the pointer.
        guard source?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        switch classifier.decide(types: types, sourceBundleID: source?.bundleIdentifier) {
        case .skip(let reason):
            lastSkip = reason
        case .takeText:
            guard let value = pasteboard.string(forType: .string),
                  !value.isEmpty else { lastSkip = .empty; return }
            // Before hashing, not after: SHA-256 over a 50 MB paste blocks the
            // main actor, and the whole point is never to touch something that
            // size.
            let byteCount = value.utf8.count
            guard ClipboardLimits.acceptsText(byteCount: byteCount) else {
                lastSkip = .tooLarge(bytes: byteCount)
                return
            }
            let fingerprint = ClipboardItem.fingerprint(forText: value)
            if let suppressed = suppressedFingerprint {
                if suppressed.until < Date() {
                    suppressedFingerprint = nil
                } else if suppressed.value == fingerprint {
                    suppressedFingerprint = nil
                    return
                }
            }
            lastSkip = nil
            insert(ClipboardItem(payload: .text(value),
                                 fingerprint: fingerprint,
                                 copiedAt: Date(),
                                 sourceBundleID: source?.bundleIdentifier,
                                 sourceAppName: source?.localizedName))
        case .takeImage:
            captureImage(from: pasteboard, source: source)
        case .takeFile:
            captureFiles(from: pasteboard, source: source)
        }
    }

    /// A Finder copy of three files is ONE pasteboard change and three things
    /// you copied. Recording only the first would lose two silently, so every
    /// URL on the board becomes a row — capped, because copying a folder's
    /// contents should not become a folder's worth of history.
    private static let maxFilesPerCopy = 10

    private func captureFiles(from pasteboard: NSPasteboard, source: NSRunningApplication?) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let files = Array(urls.filter(\.isFileURL).prefix(Self.maxFilesPerCopy))
        guard !files.isEmpty else { lastSkip = .empty; return }
        lastSkip = nil
        // Reversed so the first file you selected ends up on top: each insert
        // goes to the head of the history, so the last one inserted wins.
        for url in files.reversed() {
            let path = url.path
            insert(ClipboardItem(payload: .file(path: path),
                                 fingerprint: "f:" + Self.digest(Data(path.utf8)),
                                 copiedAt: Date(),
                                 sourceBundleID: source?.bundleIdentifier,
                                 sourceAppName: source?.localizedName))
        }
    }

    private func captureImage(from pasteboard: NSPasteboard, source: NSRunningApplication?) {
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let image = NSImage(data: data),
              let png = Self.pngData(from: image) else { lastSkip = .empty; return }

        guard ClipboardLimits.acceptsImage(byteCount: png.count) else {
            lastSkip = .tooLarge(bytes: png.count)
            return
        }
        let fingerprint = "i:" + Self.digest(png)
        // Written before the insert, deleted straight after if the content was
        // already there. Cheaper than hashing twice against the whole history.
        guard let file = try? store.writeImage(png) else { lastSkip = .empty; return }
        lastSkip = nil

        let size = image.size
        let item = ClipboardItem(payload: .image(file: file,
                                                 width: Int(size.width.rounded()),
                                                 height: Int(size.height.rounded())),
                                 fingerprint: fingerprint,
                                 copiedAt: Date(),
                                 sourceBundleID: source?.bundleIdentifier,
                                 sourceAppName: source?.localizedName)
        if case .merged = history.insert(item, capacity: capacity) {
            store.deleteImage(file)
        }
        prune()
        save()
        Moments.shared.announce(.copied, "image")
    }

    private func insert(_ item: ClipboardItem) {
        history.insert(item, capacity: capacity)
        prune()
        save()
        // The kind only: what was copied never reaches the log.
        Moments.shared.announce(.copied, { if case .file = item.payload { "file" } else { "text" } }())
    }

    // MARK: - Actions

    /// Take an item: pasteboard now, a beat of visible confirmation, then out of
    /// the way.
    ///
    /// The order is load-bearing. The clipboard is written immediately so the
    /// result is never in doubt. The flash exists because a keyboard shortcut is
    /// otherwise invisible — press ⌘4 and you deserve to see *which* row ⌘4 was.
    /// And the paste has to come after the collapse, because collapsing is what
    /// hands the keyboard back: fire ⌘V while our panel still holds focus and it
    /// lands on us rather than on your editor.
    func activate(_ item: ClipboardItem) {
        // Nothing to put on the clipboard: stay open and say so, rather than
        // collapsing over an emptied clipboard and pasting nothing.
        guard copy(item) else {
            pictureGone = item.id
            return
        }
        pictureGone = nil
        Moments.shared.announce(.pastedFromHistory)
        // Stamped now, not when the promotion finally runs. If a real copy lands
        // from another app during the wait below, that one is genuinely newer
        // and has to sort above this one.
        let copiedAt = Date()

        flashing = item.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 170_000_000)
            guard let self else { return }
            self.flashing = nil
            self.onNavigateAway?()
            self.pasteIfEnabled()

            // Reorder only once the panel is off screen. Promoting on the click
            // was correct but unreadable: the row you just chose leapt to the
            // top while the panel was still collapsing around it, so the last
            // thing you saw was the list moving for no visible reason.
            //
            // 0.45s because the kit settles its transitions at 0.4 — see the
            // sleeps at the end of `expand`, `compact` and `hide`.
            try? await Task.sleep(nanoseconds: 450_000_000)
            // Picking it IS copying it, so it becomes the most recent item. The
            // poller cannot do this for us — `copy` deliberately claims the
            // change count so our own writes are not re-recorded — which is
            // exactly why it has to be explicit.
            self.history.promote(id: item.id, at: copiedAt)
            self.save()
        }
    }

    /// Returns false only when auto-paste is on but untrusted, so the UI can say
    /// why nothing appeared.
    @discardableResult
    private func pasteIfEnabled() -> Bool {
        guard pastesAutomatically else { return true }
        guard PasteService.isTrusted else { return false }
        // Short, and after the collapse above rather than racing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { PasteService.paste() }
        return true
    }

    // MARK: - Keyboard

    /// Installed while the clipboard tab is on screen.
    ///
    /// A local `NSEvent` monitor rather than SwiftUI's `.onKeyPress`, because
    /// ⌘-modified keys are dispatched as *key equivalents* and never reach it.
    /// That is not a theory — ⌘4 was going straight past us to whatever was
    /// frontmost, switching Chrome tabs and WhatsApp chats. A local monitor sees
    /// every key event routed to this app, equivalents included.
    ///
    /// It only ever sees anything at all when our panel holds the keyboard,
    /// which is why `NotchController` has to make it key on expand.
    func beginKeyboardSession() {
        // Nothing highlighted until the user picks — see `selection`.
        selection = nil
        scrollTarget = nil
        // A picture must not take keystrokes: Return here pastes.
        guard keyMonitor == nil, !isPreview else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only a Bool crosses the isolation boundary — `NSEvent` is not
            // Sendable, so returning it from inside `assumeIsolated` will not
            // compile. The event itself never leaves this closure.
            let handled = MainActor.assumeIsolated {
                ClipboardKeyRouter.shared?.handle(event) ?? false
            }
            return handled ? nil : event
        }
        ClipboardKeyRouter.shared = self
    }

    func endKeyboardSession() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        flashing = nil
        // So a highlight left by the pointer cannot be on screen the next time
        // the panel opens.
        selection = nil
        scrollTarget = nil
        if ClipboardKeyRouter.shared === self { ClipboardKeyRouter.shared = nil }
    }

    /// True when we consumed the event. Everything else falls through untouched
    /// so plain letters keep typing into the search field and ⌘V keeps pasting
    /// into it.
    fileprivate func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // `charactersIgnoringModifiers` and not `characters`: with Option held
        // the keyboard produces π for P and ¡ for 1, so matching on the composed
        // character would silently never fire.
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        switch event.keyCode {
        case 126: moveSelection(-1); return true            // ↑
        case 125: moveSelection(1); return true             // ↓
        case 36, 76:                                        // ↩ / enter
            if let item = selected { activate(item) }
            return true
        case 53:                                            // esc
            // Two-stage, the way Spotlight does it: the first Escape undoes your
            // typing, the second closes the panel. Going straight to close would
            // throw away a long query on a keystroke people press reflexively.
            if query.isEmpty { onNavigateAway?() } else { query = "" }
            return true
        default: break
        }

        if flags.contains(.option) {
            if key == "p" {
                if let item = selected { togglePin(item) }
                return true
            }
            if event.keyCode == 51 {                        // ⌫
                if let item = selected {
                    moveSelection(1) // move the highlight before the row goes
                    delete(item)
                }
                return true
            }
            if let n = Int(key), (1...9).contains(n) { return fire(.pinned(n)) }
        }

        if flags.contains(.command), let n = Int(key), (1...9).contains(n) {
            return fire(.recent(n))
        }

        return false
    }

    /// Always consumes the key, even when nothing is bound to it. Letting an
    /// unbound ⌘7 fall through would send it to the app behind us — which is
    /// the exact bug this replaced.
    private func fire(_ shortcut: ClipboardShortcut) -> Bool {
        if let item = ClipboardShortcuts.item(for: shortcut, in: items) { activate(item) }
        return true
    }

    var selected: ClipboardItem? { items.first { $0.id == selection } }

    func moveSelection(_ delta: Int) {
        let rows = items
        guard !rows.isEmpty else { return }
        guard let current = rows.firstIndex(where: { $0.id == selection }) else {
            // Entering the list from nothing selected: down lands on the first
            // row, up on the last, the way any menu behaves. Without this both
            // arrows landed on the first row, so reaching the bottom of a long
            // history meant holding ↓ through all of it.
            let entry = delta < 0 ? rows.count - 1 : 0
            selection = rows[entry].id
            scrollTarget = rows[entry].id
            return
        }
        let next = min(max(0, current + delta), rows.count - 1)
        selection = rows[next].id
        scrollTarget = rows[next].id
    }

    /// False, with the clipboard untouched, when the row is a picture whose
    /// file has gone. It used to clear the clipboard first and then find
    /// nothing to write, so picking the row emptied the clipboard in silence.
    @discardableResult
    func copy(_ item: ClipboardItem) -> Bool {
        var pictureData: Data?
        if case .image(let file, _, _) = item.payload {
            guard !isPreview,
                  let data = try? Data(contentsOf: store.imageURL(for: file)) else { return false }
            pictureData = data
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.payload {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
        case .image:
            if let pictureData { pasteboard.setData(pictureData, forType: .png) }
        case .file(let path):
            // The reference, exactly as Finder put it there. Pasting into Finder
            // then copies the original file, and pasting into a text field gives
            // the path — both of which are what a file on the pasteboard means.
            // Writing the bytes instead would turn ⌘V in Finder into a duplicate
            // with a new name.
            pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        }
        // Claim the change now so the poller does not treat our own write as a
        // fresh copy from another app.
        lastChangeCount = pasteboard.changeCount
        return true
    }

    /// Put a row back on the pasteboard by id. False when it is no longer there.
    ///
    /// The spoken/typed counterpart of `activate(_:)`, and deliberately only the
    /// half of it that is about the clipboard: no flash (there is no row on
    /// screen to flash), no `onNavigateAway` (that would collapse the panel out
    /// from under the card reporting the outcome), and no `pasteIfEnabled` —
    /// auto-paste is opt-in for the click gesture, and a voice command must not
    /// inherit it.
    ///
    /// It DOES promote, for the reason `activate(_:)` gives at the same line:
    /// picking a row is copying it, so it becomes the most recent entry, and
    /// `copy(_:)` claiming the change count is precisely why the poller cannot
    /// work that out for itself. Promoted immediately rather than after the
    /// 0.45s `activate` waits — that delay exists so the list does not visibly
    /// reorder while the panel collapses, and answering a card collapses nothing.
    @discardableResult
    func recopy(id: UUID) -> Bool {
        // Re-resolved here, at the moment of use: the gap between proposing and
        // approving is as long as the user wants, and the row can be deleted or
        // pushed out of history inside it.
        guard let item = history.item(id: id), copy(item) else { return false }
        history.promote(id: item.id, at: Date())
        save()
        return true
    }

    func togglePin(_ item: ClipboardItem) {
        history.setPinned(!item.pinned, id: item.id)
        save()
    }

    func delete(_ item: ClipboardItem) {
        history.remove(id: item.id)
        prune()
        save()
    }

    func clearUnpinned() {
        history.clearUnpinned()
        prune()
        save()
    }

    func clearAll() {
        history.clearAll()
        store.deleteAllImages()
        save()
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        // The gallery's images are made up; the folder holds the user's real ones.
        guard !isPreview else { return nil }
        return item.imageFile.map(store.imageURL(for:))
    }

    // MARK: - Hotkey

    /// Registered only when there is somewhere for it to go: switching the
    /// widget off takes the clipboard tab out of the strip, so a key that still
    /// fired would open the panel on Home for no stated reason.
    private func applyHotkey() {
        hotkeyRegistration.unregister()
        hotkeyError = nil
        guard isEnabled, hotkeyEnabled else { return }
        hotkeyRegistration.register(hotkey) { [weak self] in self?.onHotkey?() }
        hotkeyError = hotkeyRegistration.lastError
    }

    // MARK: - Persistence

    /// Trailing-debounced, like the session registry: a burst of copies while
    /// you work through a file should not be a burst of disk writes.
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    func persistNow() {
        saveTask?.cancel()
        do {
            try store.save(history)
        } catch {
            Log.widgets.error("could not save clipboard history — \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Drops orphaned image files, then evicts the oldest images if the
    /// directory has outgrown its budget.
    ///
    /// The item cap bounds how many things are stored, never how large they
    /// are — two hundred retina screenshots is gigabytes that nothing would
    /// otherwise reclaim.
    private func prune() {
        store.pruneOrphanedImages(keeping: history.referencedImageFiles)
        let evicted = history.imageItemsToEvict(sizes: store.imageSizes())
        guard !evicted.isEmpty else { return }
        for id in evicted { history.remove(id: id) }
        store.pruneOrphanedImages(keeping: history.referencedImageFiles)
    }

    /// Apps the USER added, on top of the built-in list.
    ///
    /// The built-ins are governed by `ignoresPasswordManagerTypes` and cover the
    /// password managers everybody has heard of. This is for the rest: an
    /// internal tool, a banking app, a notes app somebody keeps recovery codes
    /// in. Nothing but the person using it can know what belongs here.
    ///
    /// Kept SEPARATE from the built-ins rather than seeding a single editable
    /// list from them, so switching the built-ins off cannot silently take away
    /// an app somebody added by hand — the two are different statements and
    /// only one of them is theirs.
    private(set) var extraIgnoredApps: [String] =
        Defaults.stringArray("clipboard.ignoredApps")

    func ignoreApp(_ bundleID: String) {
        guard !bundleID.isEmpty, !extraIgnoredApps.contains(bundleID) else { return }
        extraIgnoredApps.append(bundleID)
        Defaults.setStringArray(extraIgnoredApps, "clipboard.ignoredApps")
        rebuildClassifier()
    }

    func stopIgnoringApp(_ bundleID: String) {
        guard let index = extraIgnoredApps.firstIndex(of: bundleID) else { return }
        extraIgnoredApps.remove(at: index)
        Defaults.setStringArray(extraIgnoredApps, "clipboard.ignoredApps")
        rebuildClassifier()
    }

    private func rebuildClassifier() {
        // The user's own list applies whatever the built-in switch says. They
        // named those apps; a toggle about password managers is not consent to
        // start recording them again.
        let builtIn = ignoresPasswordManagerTypes ? PasteboardClassifier.defaultIgnoredApps : []
        classifier = PasteboardClassifier(
            ignoredTypes: ignoresPasswordManagerTypes ? PasteboardClassifier.defaultIgnoredTypes : [],
            ignoredApps: builtIn.union(extraIgnoredApps))
    }

    // MARK: - Helpers

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// The local monitor closure cannot safely capture the model under Swift 6
/// concurrency, so it goes through here. Exactly one clipboard tab is on screen
/// at a time, which is what makes a single slot correct rather than a shortcut.
@MainActor
enum ClipboardKeyRouter {
    weak static var shared: ClipboardWidgetModel?
}

/// Small typed wrappers so the `didSet` bodies above stay readable.

