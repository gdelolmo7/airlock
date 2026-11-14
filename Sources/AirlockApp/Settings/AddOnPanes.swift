import AirlockCore
import SwiftUI

// The add-ons whose pages are short enough to live together. The longer ones
// (Clipboard, Coding agents, Dictation, Meeting notes) have files of their own.

/// The Shelf's page: what is on it, and where it is kept.
///
/// The folder buttons stay with the switch off too, because switching the
/// Shelf off keeps its files: this is where they can still be reached.
struct ShelfPane: View {
    @Environment(TrayModel.self) private var tray
    @State private var moreOptions: Bool

    init(moreOptions: Bool = false) {
        _moreOptions = State(initialValue: moreOptions)
    }

    var body: some View {
        AddOnPage(.shelf, subtitle: String(localized: "Files you drop on the notch, kept until you clear them."),
                  learnMore: SettingsPane.tray.learnMore, moreOptions: $moreOptions) {
            LookGroupLabel("Files")
            LookRow("On the shelf", subtitle: tray.items.count == 1
                    ? String(localized: "1 item") : String(localized: "\(tray.items.count) items")) {
                HStack(spacing: 6) {
                    LookButton("Open folder") { tray.openFolder() }
                    LookButton("Clear") { tray.clear() }
                        .disabled(tray.items.isEmpty)
                }
            }
            .settingsAnchor(.shelf)
            LookRow("Kept in") {
                LookValue(tray.directory.path, monospaced: true)
                    .textSelection(.enabled)
            }
        } more: {
            LookGroupLabel("Dropping files")
            LookNote("Clear moves everything to the Trash, so it is recoverable from there. Dropped files are moved in, so a file leaves the folder you dragged it out of — hold Option while dropping to leave the original where it is. A format or action in the drop box never moves anything: it leaves the original alone and puts a new file here. The workspace beside it is where the notch opens a terminal.")
        }
    }
}

/// Window layouts' page: the green button and the keyboard shortcuts.
struct WindowLayoutsPane: View {
    var body: some View {
        AddOnPage(.windowLayouts,
                  subtitle: String(localized: "Drag a window to the notch and pick a half, a quarter, a third or the whole screen.")) {
            LookGroupLabel("Placing windows")
            WindowLayoutsSection(layouts: .shared)
        }
    }
}
