import AirlockCore
import SwiftUI

/// "Words to know": names and words the person uses, typed once and spelled
/// their way in dictation, in every call transcript and in the notes written
/// from it (`MeetingKnownWords`, `DictationWords`). One list, drawn on the
/// Dictation page and the Call notes page alike.
///
/// Chips, as the clipboard's never-remembered list: the words are the thing
/// to read, and each one comes off with its ×. The field takes several at
/// once, split at commas, because a team's names tend to arrive as a list,
/// and "jon → Jon" as an "always write" entry. Saved as typed, so the chip
/// shows exactly the spelling that will be used.
///
/// The Dictation page also shows the built-in words (removable, and put back
/// with one click) and names from recent calls to add with one click.
struct KnownWordsRow: View {
    enum Page { case dictation, calls }

    /// What the gallery's pictures stand in with, so nothing is read or saved.
    struct Preview {
        var words: [String]
        var replacements: [DictationWords.Replacement] = []
        var builtInsRemoved: [String] = []
        var suggestions: [String] = []
    }

    let page: Page
    @State private var words: [String]
    @State private var replacements: [DictationWords.Replacement]
    @State private var builtInsRemoved: [String]
    @State private var suggestions: [String]
    @State private var draft = ""
    @FocusState private var typing: Bool
    private let saves: Bool

    init(page: Page = .calls, preview: Preview? = nil) {
        self.page = page
        let settings = UserDefaults.standard
        _words = State(initialValue: preview?.words ?? MeetingNotesModel.typedWords(in: settings))
        _replacements = State(initialValue: preview?.replacements ?? DictationWordsStore.replacements(settings))
        _builtInsRemoved = State(initialValue: preview?.builtInsRemoved
            ?? settings.stringArray(forKey: DictationWordsStore.builtInsRemovedKey) ?? [])
        _suggestions = State(initialValue: preview?.suggestions ?? [])
        saves = preview == nil
    }

    /// The gallery's old way in: typed words only.
    init(words: [String]?) {
        self.init(page: .calls, preview: words.map { Preview(words: $0) })
    }

    private var builtInsKept: [String] { DictationWords.builtIns(without: builtInsRemoved) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Words to know")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ChipFlow {
                ForEach(words, id: \.self) { word in
                    chip(Text(word), label: word) {
                        save(words: MeetingKnownWords.removing(word, from: words))
                    }
                }
                ForEach(replacements, id: \.self) { pair in
                    chip(Text("\(pair.heard) → \(pair.written)"), label: "\(pair.heard) → \(pair.written)") {
                        save(replacements: DictationWords.removing(pair, from: replacements))
                    }
                }
                if page == .dictation {
                    ForEach(builtInsKept, id: \.self) { word in
                        chip(Text(word), label: word, faint: true) {
                            save(builtInsRemoved: builtInsRemoved + [word])
                        }
                    }
                }
                field
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if page == .dictation, !builtInsRemoved.isEmpty {
                Button { save(builtInsRemoved: []) } label: {
                    Text("Put back the \(builtInsRemoved.count) built-in words you removed")
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textSecondary)
                        .underline()
                }
                .buttonStyle(.plain)
                .clickable()
            }
            if page == .dictation, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From your calls")
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textSecondary)
                    ChipFlow {
                        ForEach(suggestions, id: \.self, content: suggestion)
                    }
                }
            }
        }
        .lookRowBox()
        .task {
            guard saves, page == .dictation else { return }
            suggestions = await DictationWordsStore.namesFromCalls()
        }
        .onReceive(NotificationCenter.default.publisher(for: DictationWordsStore.changed)) { _ in
            guard saves else { return }
            reload()
        }
    }

    private var subtitle: String {
        switch page {
        case .dictation:
            return String(localized: "Names and words you use. Dictation, call transcripts and notes spell them your way. Type “jon → Jon” to always write one word as another")
        case .calls:
            return String(localized: "Names and words you use. Transcripts, notes and dictation spell them your way")
        }
    }

    private func chip(_ text: Text, label: String, faint: Bool = false,
                      remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            text
                .font(Theme.chrome(11.5))
                .foregroundStyle(faint ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .clickable()
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(SettingsLook.chipFill))
        .accessibilityElement(children: .contain)
    }

    private func suggestion(_ name: String) -> some View {
        Button {
            suggestions.removeAll { $0 == name }
            save(words: MeetingKnownWords.adding(name, to: words))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                Text(name)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(SettingsLook.rowStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityLabel("Add \(name)")
    }

    private var isEmpty: Bool {
        words.isEmpty && replacements.isEmpty && (page == .calls || builtInsKept.isEmpty)
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField("Add a word", text: $draft, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($typing)
                .onSubmit(add)
                .onExitCommand { draft = ""; typing = false }
                // A grey hint drawn here, as the search field's: the field's
                // own placeholder comes out white and reads as typed.
                .background(alignment: .leading) {
                    if draft.isEmpty {
                        Text(isEmpty ? "Add a name or word, like a product" : "Add a word")
                            .font(Theme.chrome(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: isEmpty ? 210 : 110)
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                LookButton("Add", action: add)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(SettingsLook.rowFill))
        .overlay(Capsule().strokeBorder(typing ? SettingsLook.selectedStroke : SettingsLook.rowStroke,
                                        lineWidth: 1))
    }

    private func add() {
        if let pair = DictationWords.replacement(from: draft) {
            save(replacements: DictationWords.adding(pair, to: replacements))
        } else {
            save(words: MeetingKnownWords.adding(draft, to: words))
        }
        draft = ""
    }

    private func reload() {
        let settings = UserDefaults.standard
        words = MeetingNotesModel.typedWords(in: settings)
        replacements = DictationWordsStore.replacements(settings)
        builtInsRemoved = settings.stringArray(forKey: DictationWordsStore.builtInsRemovedKey) ?? []
    }

    private func save(words list: [String]) {
        guard list != words else { return }
        words = list
        if saves { DictationWordsStore.saveTyped(list) }
    }

    private func save(replacements list: [DictationWords.Replacement]) {
        guard list != replacements else { return }
        replacements = list
        if saves { DictationWordsStore.saveReplacements(list) }
    }

    private func save(builtInsRemoved list: [String]) {
        guard list != builtInsRemoved else { return }
        builtInsRemoved = list
        if saves { DictationWordsStore.saveBuiltInsRemoved(list) }
    }
}

/// "Learn from my fixes" and "Add without asking", under the words on the
/// Dictation page.
struct LearnFromFixesRows: View {
    @AppStorage(DictationWordsStore.learnsKey) private var learns = true
    @AppStorage(DictationWordsStore.learnsSilentlyKey) private var silently = true

    var body: some View {
        LookToggleRow("Learn from my fixes",
                      subtitle: String(localized: "When you change a word right after dictating it, Airlock remembers the new spelling. It looks only at the box it just typed into, for a few seconds"),
                      isOn: $learns)
        LookToggleRow("Add without asking",
                      subtitle: String(localized: "Fixed words join the list straight away, and the notch says so. Off, the notch asks first"),
                      isOn: $silently)
            .disabled(!learns)
    }
}
