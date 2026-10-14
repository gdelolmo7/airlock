import AirlockCore
import SwiftUI

/// "Words to know": names and words the person's meetings use, typed once and
/// spelled their way in every transcript from then on, and in the notes
/// written from it (`MeetingKnownWords`).
///
/// Chips, as the clipboard's never-remembered list: the words are the thing
/// to read, and each one comes off with its ×. The field takes several at
/// once, split at commas, because a team's names tend to arrive as a list.
/// Saved as typed, so the chip shows exactly the spelling that will be used.
struct KnownWordsRow: View {
    @State private var words: [String]
    @State private var draft = ""
    @FocusState private var typing: Bool
    private let saves: Bool

    /// `words`, when set, stands in for the saved list and nothing is saved:
    /// the state gallery's pictures.
    init(words: [String]? = nil) {
        _words = State(initialValue: words ?? MeetingNotesModel.typedWords())
        saves = words == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Words to know")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                Text("Names and words your meetings use. Transcripts and notes spell them your way")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ChipFlow {
                ForEach(words, id: \.self, content: chip)
                field
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lookRowBox()
    }

    private func chip(_ word: String) -> some View {
        HStack(spacing: 4) {
            Text(word)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Button { save(MeetingKnownWords.removing(word, from: words)) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .clickable()
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(SettingsLook.chipFill))
        .accessibilityElement(children: .contain)
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
                        Text(words.isEmpty ? "Add a name or word, like a product" : "Add a word")
                            .font(Theme.chrome(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: words.isEmpty ? 210 : 110)
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
        save(MeetingKnownWords.adding(draft, to: words))
        draft = ""
    }

    private func save(_ list: [String]) {
        guard list != words else { return }
        words = list
        if saves { UserDefaults.standard.set(list, forKey: MeetingNotesModel.knownWordsKey) }
    }
}
