import AirlockCore
import SwiftUI

/// The History row on Settings › Voice: how many dictations are kept, and the
/// button that opens the list. The list is a sheet so a month of dictations
/// never pushes the page's settings out of reach.
struct DictationHistoryRow: View {
    @Environment(DictationModel.self) private var dictation
    @State private var showing = false

    var body: some View {
        LookRow("History", subtitle: subtitle) {
            LookButton("Open…") { showing = true }
                .disabled(dictation.history.entries.isEmpty)
        }
        .onAppear { dictation.history.loadIfNeeded() }
        .sheet(isPresented: $showing) {
            DictationHistorySheet { showing = false }
                .environment(dictation)
        }
    }

    private var subtitle: String {
        guard dictation.keepsHistory else { return String(localized: "Off: new dictations aren't kept") }
        let count = dictation.history.entries.filter(\.finished).count
        if count == 0 { return String(localized: "Your dictations will show here") }
        return count == 1 ? String(localized: "1 dictation, kept on this Mac")
                          : String(localized: "\(count) dictations, kept on this Mac")
    }
}

/// Every kept dictation, newest first: search, copy, type it again, listen
/// again, and the older versions a Try again replaced.
struct DictationHistorySheet: View {
    var onDone: () -> Void
    @Environment(DictationModel.self) private var dictation
    @State private var query = ""
    @State private var confirmingClear = false

    private var shown: [DictationEntry] {
        DictationHistory.search(dictation.history.entries.filter(\.finished), for: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dictation history")
                    .font(Theme.chrome(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                LookButton("Done", isDefault: true, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search what you said, or an app", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.chrome(12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))

            if shown.isEmpty {
                Text(query.isEmpty ? "Nothing kept yet." : "No dictation matches that.")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { entry in
                            DictationHistoryItem(entry: entry)
                        }
                    }
                }
                .frame(height: 380)
            }

            HStack {
                Text("Kept on this Mac only: the last 200 or 30 days, recordings for a week.")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                LookButton("Clear history…") { confirmingClear = true }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(SettingsLook.ground)
        .environment(\.colorScheme, .dark)
        .confirmationDialog("Clear your dictation history?", isPresented: $confirmingClear) {
            Button("Clear history", role: .destructive) {
                dictation.clearHistory()
                onDone()
            }
        } message: {
            Text("Every kept dictation and recording is removed from this Mac. This can't be undone.")
        }
    }
}

/// One dictation in the list.
private struct DictationHistoryItem: View {
    let entry: DictationEntry
    @Environment(DictationModel.self) private var dictation
    @State private var showsHeard = false
    @State private var showsEarlier = false

    private var retrying: Bool { dictation.history.retrying.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.day().month().hour().minute())
                if let app = entry.app, !app.isEmpty {
                    Text("·")
                    Text(app)
                }
                if entry.recovered {
                    Text("Recovered")
                        .font(Theme.chrome(10, .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .help("This dictation was cut off before it was typed. Airlock listened to its recording again when it next opened.")
                }
                if entry.delivery == .copied {
                    Text("· copied, not typed")
                }
                Spacer()
            }
            .font(Theme.chrome(11))
            .foregroundStyle(Theme.textTertiary)

            Text(showsHeard ? entry.heard : entry.text)
                .font(Theme.chrome(12.5))
                .foregroundStyle(showsHeard ? Theme.textSecondary : Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                LookButton("Copy") { dictation.copyHistoryText(entry.text) }
                LookButton("Type again") { dictation.typeAgain(entry.text) }
                    .help("Types it where the cursor is, in the app you were in before Settings.")
                if entry.hasRecording {
                    if retrying {
                        ProgressView().controlSize(.small)
                    } else {
                        LookButton("Try again") { Task { await dictation.tryAgain(entry.id) } }
                            .help("Listens to the recording again. The words it replaces stay below.")
                    }
                }
                Spacer()
                if entry.heard != entry.text, !entry.heard.isEmpty {
                    quietButton(showsHeard ? "Show tidied" : "As heard") { showsHeard.toggle() }
                }
                if !entry.earlier.isEmpty {
                    quietButton(showsEarlier ? "Hide earlier" : "Earlier (\(entry.earlier.count))") {
                        showsEarlier.toggle()
                    }
                }
                quietButton("Remove") { dictation.history.remove(entry.id) }
            }

            if showsEarlier {
                ForEach(entry.earlier.reversed(), id: \.self) { version in
                    HStack(alignment: .top, spacing: 8) {
                        Text(version)
                            .font(Theme.chrome(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        quietButton("Use this") {
                            dictation.history.put(DictationHistory.restored(entry, earlier: version))
                        }
                    }
                    .padding(.leading, 10)
                }
            }
        }
        .lookRowBox()
    }

    private func quietButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .clickable()
    }
}

/// The settings behind "More options": what is kept, and the shortcut that
/// types the last dictation again.
struct DictationHistoryOptions: View {
    @Environment(DictationModel.self) private var dictation

    var body: some View {
        @Bindable var dictation = dictation
        LookGroupLabel("History")
        LookToggleRow("Keep history", subtitle: String(localized: "On this Mac only"),
                      isOn: $dictation.keepsHistory)
        LookToggleRow("Keep recordings for Try again", subtitle: String(localized: "A week, then only the words stay"),
                      isOn: $dictation.keepsRecordings)
            .disabled(!dictation.keepsHistory)
        LookToggleRow("Shortcut to type the last one again", isOn: $dictation.pastesLast)
            .disabled(!dictation.isEnabled)
        if dictation.pastesLast {
            HotkeyRecorder("Types the last dictation", binding: $dictation.pasteLastHotkey, conflict: { _ in nil })
                .disabled(!dictation.isEnabled)
            if dictation.isEnabled, let error = dictation.pasteLastHotkeyError {
                ProblemCard(sentence: error)
            }
        }
        LookNote("Nothing in the history leaves your Mac. Nothing is kept from a password field, and the dictation log never holds your words.")
    }
}
