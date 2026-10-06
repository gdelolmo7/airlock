import SwiftUI
import AirlockCore

/// Clipboard settings.
///
/// The privacy section is the one that matters. A clipboard manager records
/// everything you copy, so what it refuses to record has to be visible and
/// legible — not a checkbox called "filter types".
struct ClipboardPane: View {
    @Environment(ClipboardWidgetModel.self) private var clipboard
    /// Clear all deletes the saved pictures with the rows and can't be undone,
    /// so it asks first (X21). Clear unpinned keeps what was pinned and doesn't.
    @State private var confirmingClearAll = false

    var body: some View {
        @Bindable var clipboard = clipboard
        return Form {
            Section("Should Airlock remember what you copy?") {
                Toggle("Record clipboard history", isOn: $clipboard.isEnabled)
                    .settingsAnchor(.clipboardHistory)
                Text("Off stops the watcher entirely — nothing is read and nothing is stored. "
                     + "Items already saved stay until you clear them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Keep", selection: $clipboard.capacity) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { count in
                        Text("\(count) items").tag(count)
                    }
                }
                .disabled(!clipboard.isEnabled)

                // The buttons sit on the row with the number they act on. A
                // count in one row and two Clear buttons in the next asks you
                // to hold "146" in your head while deciding what to delete.
                LabeledContent("Stored now") {
                    HStack(spacing: 10) {
                        Text(storedSummary).foregroundStyle(.secondary)
                        Button("Clear unpinned") { clipboard.clearUnpinned() }
                            .disabled(clipboard.history.items.isEmpty)
                        Button("Clear all", role: .destructive) { confirmingClearAll = true }
                            .disabled(clipboard.history.items.isEmpty)
                    }
                }
                Text("Pinned items survive Clear unpinned. Clear all deletes the saved images too, not just the rows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .confirmationDialog("Delete all clipboard history?", isPresented: $confirmingClearAll) {
                        Button("Delete All", role: .destructive) { clipboard.clearAll() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every item goes, pinned ones too, along with the images Airlock saved from them. This can't be undone.")
                    }

                // Where it is kept belongs with what is kept, not with what is
                // refused. It was under "Never recorded", which is the section
                // about exclusions.
                LabeledContent("Kept at") {
                    Text(clipboard.storageDirectory)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                // The files are 0600 and the image folder 0700; what that means
                // to a person is the sentence. File names and modes are for us.
                Text("Only your account on this Mac can read it, and it's never synced anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("What should it never remember?") {
                // Chips, not a sentence. This list is the thing people want to
                // read before they trust a clipboard manager at all, and
                // "anything an app marks private" asks them to take it on faith.
                // Names they recognise, and the ones they added removable.
                IgnoredAppChips(clipboard: clipboard)

                LabeledContent("Always") {
                    Text("Anything an app marks private")
                        .foregroundStyle(.secondary)
                }
                .settingsAnchor(.neverRecorded)
                Text("Password managers and two-factor apps mark what they copy as private. "
                     + "Airlock always respects that, and there is no setting to turn it off — "
                     + "you can't agree on behalf of the app that marked it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Also skip known password managers", isOn: $clipboard.ignoresPasswordManagerTypes)
                Text("Covers password managers that don't mark their copies as private — "
                     + "1Password, Bitwarden, Dashlane, Enpass, LastPass and Keychain Access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let skip = clipboard.lastSkip {
                    LabeledContent("Last copy skipped") {
                        Text(describe(skip)).foregroundStyle(.secondary)
                    }
                }
            }

            Section("How do you open it?") {
                Toggle("Open with a shortcut", isOn: $clipboard.hotkeyEnabled)
                    .settingsAnchor(.clipboardShortcut)
                    .disabled(!clipboard.isEnabled)
                // Four chords became "press what you want". The old list was
                // four guesses at what would be free on your Mac, and a Mac
                // where all four were taken had no way to open the clipboard at
                // all.
                LabeledContent("Opens clipboard") {
                    HotkeyRecorder(binding: $clipboard.hotkey, conflict: { _ in nil })
                }
                .disabled(!clipboard.isEnabled || !clipboard.hotkeyEnabled)

                if !clipboard.isEnabled {
                    // The key used to stay registered with history off and open
                    // the panel on Home, which explains nothing. It is released
                    // instead — and the setting says so rather than sitting
                    // there switched on and inert.
                    Text("History is off, so the key isn't registered — there would be no clipboard "
                         + "tab for it to open. Your choice of key is kept and comes back with it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let error = clipboard.hotkeyError {
                    ProblemCard(sentence: error)
                } else if clipboard.hotkeyEnabled && clipboard.hotkey == .commandShiftC {
                    // Registration can succeed for both apps; which one the
                    // system delivers to is then not something either can
                    // control. Worth saying out loud, because the symptom is
                    // "my hotkey opens the wrong app" with no error anywhere.
                    Text("⇧⌘C is also Maccy's default. If Maccy is still running, one of the two "
                         + "will get the key and it won't be predictable which.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if clipboard.isEnabled {
                    Text("Press it again while the clipboard is open to close it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Paste automatically when I pick an item", isOn: $clipboard.pastesAutomatically)
                    .settingsAnchor(.autoPaste)
                if clipboard.pastesAutomatically && !clipboard.pasteIsTrusted {
                    ProblemCard(sentence: "Nothing will paste until Airlock has the Accessibility permission.",
                                button: "Open Accessibility Settings",
                                action: { PasteService.openAccessibilitySettings() })
                }
                Text(clipboard.pastesAutomatically
                     ? "Picking an item types ⌘V into whatever app is in front. This is the only "
                        + "part of the clipboard that needs a permission."
                     : "Picking an item puts it on the clipboard and you paste it yourself. "
                        + "No permission needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// "146 items · 8 pinned", which is what the two buttons beside it act on.
    /// Size is deliberately absent: it costs a directory walk per redraw and
    /// nobody clears a clipboard to reclaim two megabytes.
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
            Button("Add an app…") { isPicking = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, identifier: String, removable: Bool,
                      onRemove: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 4) {
            // One line, at its natural width. A chip that wraps is the bug in
            // the screenshot; the layout gives way now, never the name.
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .fixedSize()
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop ignoring \(title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
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
