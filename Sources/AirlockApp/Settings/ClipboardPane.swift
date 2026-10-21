import SwiftUI
import AirlockCore

/// Clipboard settings.
///
/// The privacy section is the one that matters. A clipboard manager records
/// everything you copy, so what it refuses to record has to be visible and
/// legible — not a checkbox called "filter types".
struct ClipboardPane: View {
    @Environment(ClipboardWidgetModel.self) private var clipboard
    /// Optional so the state gallery can draw the page without the window.
    @Environment(SettingsModel.self) private var settings: SettingsModel?
    /// Clear all deletes the saved pictures with the rows and can't be undone,
    /// so it asks first (X21). Clear unpinned keeps what was pinned and doesn't.
    @State private var confirmingClearAll = false
    @State private var moreOptions: Bool
    @AppStorage(AdvancedSwitch.key) private var advanced = false

    init(moreOptions: Bool = false) {
        _moreOptions = State(initialValue: moreOptions)
    }

    var body: some View {
        @Bindable var clipboard = clipboard
        LookPage("Clipboard", subtitle: "Everything you copy, kept on this Mac.",
                 learnMore: SettingsPane.clipboard.learnMore, moreOptions: $moreOptions) {
            LookToggleRow("Record clipboard history", isOn: $clipboard.isEnabled)
                .settingsAnchor(.clipboardHistory)

            // What shows on this plan. The choice itself is kept as it was
            // made, and comes back on a plan that shows it; a plan's limit
            // is asked of the plan, never written into the setting. A count
            // the plan doesn't show is there to pick, tagged, and picking it
            // opens Plans rather than changing anything: nothing is greyed out.
            LookRow("Keep") {
                LookMenu("\(clipboard.shownCapacity) items") {
                    Picker("Keep", selection: Binding(get: { clipboard.shownCapacity },
                                                      set: { pick($0) })) {
                        ForEach([50, 100, 200, 500, 1000], id: \.self) { count in
                            if let limit = clipboard.planShows, count > limit {
                                Text("\(count) items · Plus").tag(count)
                            } else {
                                Text("\(count) items").tag(count)
                            }
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .disabled(!clipboard.isEnabled)

            // The buttons sit on the row with the number they act on. A count
            // in one row and two Clear buttons in the next asks you to hold
            // "146" in your head while deciding what to delete.
            LookRow("Stored now", subtitle: storedSummary) {
                HStack(spacing: 6) {
                    LookButton("Clear unpinned") { clipboard.clearUnpinned() }
                        .disabled(nothingStored)
                    LookButton("Clear all") { confirmingClearAll = true }
                        .disabled(nothingStored)
                }
            }
            .confirmationDialog("Delete all clipboard history?", isPresented: $confirmingClearAll) {
                Button("Delete all", role: .destructive) { clipboard.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every item goes, pinned ones too, along with the images Airlock saved from them. This can't be undone.")
            }

            LookGroupLabel("Never remembered")
            // Chips, not a sentence. This list is the thing people want to
            // read before they trust a clipboard manager at all, and "anything
            // an app marks private" asks them to take it on faith. Names they
            // recognise, and the ones they added removable.
            IgnoredAppChips(clipboard: clipboard)
                .lookRowBox()
            LookRow("Always") { LookValue("Anything an app marks private") }
                .settingsAnchor(.neverRecorded)
            LookToggleRow("Also skip known password managers", subtitle: "For the ones that don't mark copies private",
                          isOn: $clipboard.ignoresPasswordManagerTypes)
            if let skip = clipboard.lastSkip {
                LookRow("Last copy skipped") { LookValue(describe(skip)) }
            }

            LookGroupLabel("Opening it")
            LookToggleRow("Open with a shortcut", isOn: $clipboard.hotkeyEnabled)
                .settingsAnchor(.clipboardShortcut)
                .disabled(!clipboard.isEnabled)
            // Four chords became "press what you want". The old list was four
            // guesses at what would be free on your Mac, and a Mac where all
            // four were taken had no way to open the clipboard at all.
            HotkeyRecorder("Opens clipboard", binding: $clipboard.hotkey, conflict: { _ in nil })
                .disabled(!clipboard.isEnabled || !clipboard.hotkeyEnabled)
            if clipboard.isEnabled, let error = clipboard.hotkeyError {
                ProblemCard(sentence: error)
            } else if clipboard.isEnabled, clipboard.hotkeyEnabled, clipboard.hotkey == .commandShiftC,
                      Self.maccyIsHere {
                // Registration can succeed for both apps; which one the system
                // delivers to is then not something either can control. Worth
                // saying out loud, because the symptom is "my hotkey opens the
                // wrong app" with no error anywhere. Only where that app is:
                // ⇧⌘C is the default, so everyone else read about an app they
                // never had.
                LookNote("⇧⌘C is also Maccy's default. If Maccy is still running, one of the two "
                         + "will get the key and it won't be predictable which.")
            }

            LookToggleRow("Paste automatically when I pick an item",
                          subtitle: clipboard.pastesAutomatically ? "Types ⌘V into the app in front" : "You paste it yourself",
                          isOn: $clipboard.pastesAutomatically)
                .settingsAnchor(.autoPaste)
            if clipboard.pastesAutomatically && !clipboard.pasteIsTrusted {
                ProblemCard(sentence: "Nothing will paste until Airlock has the Accessibility permission.",
                            button: "Open Accessibility Settings",
                            action: { PasteService.openAccessibilitySettings() })
            }
        } more: {
            LookGroupLabel("History")
            LookNote("With history off, Airlock doesn't look at what you copy, and nothing new is kept. "
                     + "Items already saved stay until you clear them.")
            LookNote("Pinned items survive Clear unpinned. Clear all deletes the saved images too, not just the rows.")
            // Where it is kept belongs with what is kept, not with what is
            // refused.
            // The folder itself is for whoever turned on advanced settings;
            // everyone else gets a way to look at it.
            LookRow("Kept at", subtitle: advanced ? nil : "A folder on this Mac") {
                HStack(spacing: 8) {
                    if advanced {
                        LookValue(clipboard.storageDirectory, monospaced: true)
                            .textSelection(.enabled)
                    }
                    LookButton("Show in Finder") { revealStorage() }
                }
            }
            // The files are 0600 and the image folder 0700; what that means to
            // a person is the sentence. File names and modes are for us.
            LookNote("Only your account on this Mac can read it, and it's never synced anywhere.")

            LookGroupLabel("Never remembered")
            LookNote("Password managers and two-factor apps mark what they copy as private. "
                     + "Airlock always respects that, and there is no setting to turn it off — "
                     + "you can't agree on behalf of the app that marked it.")
            LookNote("Also skip known password managers covers the ones that don't mark their copies as private — "
                     + "1Password, Bitwarden, Dashlane, Enpass, LastPass and Keychain Access.")

            LookGroupLabel("Opening it")
            if !clipboard.isEnabled {
                // The key used to stay registered with history off and open
                // the panel on Home, which explains nothing. It is released
                // instead — and the setting says so rather than sitting there
                // switched on and inert.
                LookNote("History is off, so the key isn't registered — there would be no clipboard "
                         + "tab for it to open. Your choice of key is kept and comes back with it.")
            } else {
                LookNote("Press it again while the clipboard is open to close it.")
            }
            LookNote(clipboard.pastesAutomatically
                     ? "Picking an item types ⌘V into whatever app is in front. This is the only "
                        + "part of the clipboard that needs a permission."
                     : "Picking an item puts it on the clipboard and you paste it yourself. "
                        + "No permission needed.")
            AdvancedSwitch()
        }
    }

    /// "146 items · 8 pinned", which is what the two buttons beside it act on.
    /// Size is deliberately absent: it costs a directory walk per redraw and
    /// nobody clears a clipboard to reclaim two megabytes.
    /// Copies out of sight are stored too, and a clear takes them.
    private var nothingStored: Bool {
        clipboard.history.items.isEmpty && clipboard.history.outOfSight.isEmpty
    }

    /// The other clipboard app whose default is also ⇧⌘C, on this Mac or
    /// running. One Launch Services lookup, asked only while ⇧⌘C is the key.
    private static var maccyIsHere: Bool {
        let id = "org.p0deje.Maccy"
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            || !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func revealStorage() {
        let path = (clipboard.storageDirectory as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// A count this plan shows is the setting; a bigger one is a question
    /// about Plus, answered on the Plans page.
    private func pick(_ count: Int) {
        if let limit = clipboard.planShows, count > limit {
            settings?.reveal(.plans)
        } else {
            clipboard.capacity = count
        }
    }

    private var storedSummary: String {
        let items = clipboard.history.items
        let pinned = items.filter(\.pinned).count
        guard !items.isEmpty else { return "nothing yet" }
        let count = "\(items.count) item\(items.count == 1 ? "" : "s")"
        return pinned > 0 ? "\(count) · \(pinned) pinned" : count
    }

    private func describe(_ reason: ClipboardSkipReason) -> String {
        // Named, for the same reason the chips above are: "ignored app
        // (com.bitwarden.desktop)" is a sentence about a string, not about the
        // app somebody just copied a password out of.
        reason.words(appName: AppName.of)
    }
}

/// The never-recorded list, as names rather than a promise.
///
/// **This is the list people check before they trust the feature**, so it says
/// which apps by name instead of "anything an app marks private" and leaving
/// them to hope. Built-ins and hand-added ones are drawn the same and behave
/// differently: the built-ins are governed by the switch below and carry no ×,
/// because removing one individually would be editing a list the app maintains.
private struct IgnoredAppChips: View {
    let clipboard: ClipboardWidgetModel
    @State private var isPicking = false

    var body: some View {
        chips
            // An open panel rather than a text field: nobody knows their apps'
            // bundle identifiers, and everybody can find an app.
            .fileImporter(isPresented: $isPicking,
                          allowedContentTypes: [.application]) { result in
                guard case .success(let url) = result,
                      let identifier = Bundle(url: url)?.bundleIdentifier else { return }
                clipboard.ignoreApp(identifier)
            }
    }

    private var chips: some View {
        let builtIn = clipboard.ignoresPasswordManagerTypes
            ? PasteboardClassifier.defaultIgnoredApps.sorted() : []
        // Wrapping, not an HStack: eight of these never fit one row, and a row
        // that cannot wrap squeezes its contents instead. See `ChipFlow`.
        return ChipFlow {
            ForEach(builtIn, id: \.self) { chip(name(for: $0), identifier: $0, removable: false) }
            ForEach(clipboard.extraIgnoredApps, id: \.self) { bundle in
                chip(name(for: bundle), identifier: bundle, removable: true) {
                    clipboard.stopIgnoringApp(bundle)
                }
            }
            LookButton("Add an app…") { isPicking = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, identifier: String, removable: Bool,
                      onRemove: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 4) {
            // One line, at its natural width. A chip that wraps is the bug in
            // the screenshot; the layout gives way now, never the name.
            Text(title)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .clickable()
                .accessibilityLabel("Stop ignoring \(title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(SettingsLook.chipFill))
        // The identifier is what the skip actually matches on, and the only way
        // to tell two apps with the same name apart. On hover, not on the chip.
        .help(identifier)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(removable ? "\(title), added by you" : "\(title), built in")
    }

    /// **This used to fall back to the identifier, and that was the normal case
    /// rather than the edge one**: LaunchServices only knows apps that are
    /// INSTALLED, and this list is seven password managers of which somebody
    /// has at most one. The pane read `com.bitwarden.desktop`. See `AppName`.
    private func name(for bundleID: String) -> String { AppName.of(bundleID) }
}
