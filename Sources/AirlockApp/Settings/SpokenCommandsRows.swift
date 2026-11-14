import AirlockCore
import SwiftUI

/// "Spoken commands" on the Dictation page: say a sign, take a sentence
/// back, or say a short name to type a saved text (`SpokenCommands`). One
/// switch each, so someone who dictates the word "comma" for real can keep it.
struct SpokenCommandsRows: View {
    @AppStorage(DictationWordsStore.spokenPunctuationKey) private var punctuation = true
    @AppStorage(DictationWordsStore.scratchThatKey) private var scratch = true
    @AppStorage(DictationWordsStore.savedTextsOnKey) private var savedTexts = true

    var body: some View {
        LookToggleRow("Say punctuation",
                      subtitle: String(localized: "“Comma”, “full stop”, “question mark”, “new line” and “new paragraph” type the sign. In Spanish: “coma”, “punto”, “punto y aparte”, “nueva línea”"),
                      isOn: $punctuation)
        LookToggleRow("“Scratch that”",
                      subtitle: String(localized: "Takes back the sentence before it. Said first, it takes back what the last dictation typed, if it's still there. In Spanish: “borra eso”"),
                      isOn: $scratch)
        LookToggleRow("Saved texts",
                      subtitle: String(localized: "Say a short name, and nothing else, to type the text saved under it. Kept on this Mac only"),
                      isOn: $savedTexts)
        if savedTexts {
            SavedTextsRow()
        }
    }
}

/// The saved texts themselves: a name, its text, and an × to remove it.
struct SavedTextsRow: View {
    @State private var list: [SavedText]
    @State private var name = ""
    @State private var text = ""
    @FocusState private var typing: Field?
    private let saves: Bool

    private enum Field { case name, text }

    init(preview: [SavedText]? = nil) {
        _list = State(initialValue: preview ?? DictationWordsStore.savedTexts())
        saves = preview == nil
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your saved texts")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                Text(list.isEmpty
                     ? String(localized: "Nothing saved yet. Try “my address”, “sign off” or “my phone”")
                     : String(localized: "Say the name on its own to type the text"))
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name)
                        .font(Theme.chrome(11.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                    Text(item.text)
                        .font(Theme.chrome(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { save(list.filter { $0.id != item.id }) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .accessibilityLabel("Remove \(item.name)")
                }
            }
            HStack(spacing: 6) {
                field("Name", text: $name, width: 110, focus: .name)
                field("Text to type", text: $text, width: nil, focus: .text)
                if canAdd {
                    LookButton("Add", action: add)
                }
            }
        }
        .lookRowBox()
        .onReceive(NotificationCenter.default.publisher(for: DictationWordsStore.changed)) { _ in
            guard saves else { return }
            list = DictationWordsStore.savedTexts()
        }
    }

    private func field(_ hint: LocalizedStringKey, text value: Binding<String>, width: CGFloat?,
                       focus: Field) -> some View {
        TextField(hint, text: value, prompt: Text(""), axis: focus == .text ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(Theme.chrome(11.5))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(focus == .text ? 1...4 : 1...1)
            .focused($typing, equals: focus)
            .onSubmit(add)
            // A grey hint drawn here: the field's own placeholder comes out
            // white and reads as typed.
            .background(alignment: .leading) {
                if value.wrappedValue.isEmpty {
                    Text(hint)
                        .font(Theme.chrome(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8).fill(SettingsLook.rowFill))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(typing == focus ? SettingsLook.selectedStroke : SettingsLook.rowStroke,
                              lineWidth: 1))
    }

    private func add() {
        guard canAdd else { return }
        save(SavedText.adding(name: name, text: text, to: list))
        name = ""
        text = ""
        typing = .name
    }

    private func save(_ new: [SavedText]) {
        guard new != list else { return }
        list = new
        if saves { DictationWordsStore.saveSavedTexts(new) }
    }
}
