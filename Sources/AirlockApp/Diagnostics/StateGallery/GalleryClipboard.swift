import SwiftUI
import AirlockCore

/// The clipboard's rows (C) of the inventory.
///
/// **Every item here is made up.** The pictures come from a model built with
/// `ClipboardWidgetModel(previewing:)`, which never reads the pasteboard, never
/// loads the history on disk and never registers the hotkey — a gallery export
/// must not be able to put somebody's copied password in a PNG. Image rows
/// show the placeholder glyph for the same reason: their files do not exist.
@MainActor
enum GalleryClipboard {
    static let area = "Clipboard"

    static var states: [GalleryState] {
        [
            settings("C1", "Off — the tab goes; Settings says why", .init(isEnabled: false)),
            .notYet("C2", area, "Pause for a while",
                    why: "There is no pause — the clipboard is only on or off."),
            panel("C3", "Empty", .init(history: ClipboardHistory())),
            panel("C4", "Filter shows nothing (Images, none stored)",
                  .init(filter: .images, history: ClipboardHistory(items: textOnly))),
            panel("C5", "Search finds nothing (Links filter on — says so, offers everything)",
                  .init(filter: .links, query: "invoice march")),
            panel("C6", "Has items (text, image, file, pinned)", .init()),
            panel("C7", "Auto-paste without Accessibility",
                  .init(pastesAutomatically: true, pasteTrusted: false)),
            settings("C8", "Password copy skipped — Settings",
                     .init(lastSkip: .markedPrivate("org.nspasteboard.ConcealedType"))),
            panel("C9", "Too large — the notch says so (Settings names it too, as in C8)",
                  .init(lastSkip: .tooLarge(bytes: 61_400_000))),
            settings("C10", "Shortcut taken by another app — Settings",
                     .init(hotkeyError: GlobalHotkey.failureMessage(.commandShiftC, status: -9878))),
            panel("C11", "Image file gone (the row says so; picking it leaves the clipboard alone)",
                  .init(history: ClipboardHistory(items: [missingImage] + textOnly),
                        missingPictures: ["state-gallery-deleted.png"], pictureGoneNotice: true)),
        ]
    }

    // MARK: - Builders

    /// Everything one picture needs, defaulted to the "has items" shelf.
    @MainActor
    struct Setup {
        var isEnabled = true
        var filter: ClipboardFilter = .all
        var query = ""
        var pastesAutomatically = false
        var pasteTrusted = true
        var lastSkip: ClipboardSkipReason?
        var hotkeyError: String?
        var history = ClipboardHistory(items: GalleryClipboard.items)
        var missingPictures: Set<String> = []
        var pictureGoneNotice = false

        func model() -> ClipboardWidgetModel {
            ClipboardWidgetModel(previewing: history, filter: filter, query: query,
                                 isEnabled: isEnabled, pastesAutomatically: pastesAutomatically,
                                 pasteTrusted: pasteTrusted, lastSkip: lastSkip,
                                 hotkeyError: hotkeyError, missingPictures: missingPictures,
                                 pictureGoneNotice: pictureGoneNotice)
        }
    }

    /// The clipboard tab in the open notch.
    private static func panel(_ id: String, _ name: String, _ setup: Setup) -> GalleryState {
        GalleryState(id, area, name) {
            ClipboardSectionView()
                .environment(setup.model())
        }
    }

    /// Settings › Clipboard, at the settings window's detail width. Tall enough
    /// for the whole page: a grouped form scrolls, so it has no height of its own.
    private static func settings(_ id: String, _ name: String, _ setup: Setup) -> GalleryState {
        GalleryState(id, area, name, ground: .window, width: 576) {
            ClipboardPane()
                .environment(setup.model())
                .frame(height: 1100)
        }
    }

    // MARK: - Made-up history

    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private static func text(_ value: String, from app: String, minutesAgo: Double,
                             pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(payload: .text(value), fingerprint: ClipboardItem.fingerprint(forText: value),
                      copiedAt: t0.addingTimeInterval(-minutesAgo * 60), pinned: pinned,
                      sourceAppName: app)
    }

    private static let textOnly: [ClipboardItem] = [
        text("Flat 3B, 14 Harbour Street", from: "Notes", minutesAgo: 400, pinned: true),
        text("Thanks — I'll send the slides over tonight.", from: "Mail", minutesAgo: 2),
        text("swift test --filter StateGalleryTests", from: "Terminal", minutesAgo: 9),
        text("https://example.com/handbook/onboarding", from: "Safari", minutesAgo: 14),
    ]

    private static let image = ClipboardItem(
        payload: .image(file: "state-gallery-screenshot.png", width: 1440, height: 900),
        fingerprint: "i:state-gallery-screenshot", copiedAt: t0.addingTimeInterval(-5 * 60),
        sourceAppName: "Screenshot")

    private static let file = ClipboardItem(
        payload: .file(path: "/Users/you/Documents/Q3 budget.numbers"),
        fingerprint: "f:state-gallery-budget", copiedAt: t0.addingTimeInterval(-11 * 60),
        sourceAppName: "Finder")

    private static let missingImage = ClipboardItem(
        payload: .image(file: "state-gallery-deleted.png", width: 1200, height: 800),
        fingerprint: "i:state-gallery-deleted", copiedAt: t0.addingTimeInterval(-60),
        sourceAppName: "Preview")

    static let items: [ClipboardItem] = [textOnly[0], textOnly[1], image, textOnly[2], file, textOnly[3]]
}
