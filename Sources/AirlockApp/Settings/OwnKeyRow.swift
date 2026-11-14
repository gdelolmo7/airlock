import AirlockCore
import SwiftUI

/// "Your own Claude key": an Anthropic API key pasted once, after which
/// Claude Sonnet writes every finished call's notes and to-dos, on the
/// person's Anthropic account (`OwnKeyNotesService`). On every plan.
///
/// The key goes to the keychain (`OwnKeyStore`) and is only ever shown
/// masked. Saving checks it at once, with the smallest request there is;
/// "Check" asks again, "Remove" takes it out of the keychain.
struct OwnKeyRow: View {
    /// What the row says about the key, after a check.
    enum Status: Equatable {
        case none
        case checking
        case works
        case problem(String)
    }

    @State private var saved: String?
    @State private var draft = ""
    @State private var status: Status = .none
    @FocusState private var typing: Bool
    @AppStorage(OwnKeyNotes.Choice.preference) private var picked = OwnKeyNotes.Choice.sonnet.rawValue
    private let saves: Bool

    /// `preview` is the state gallery's pictures: `masked` stands in for the
    /// saved key (nil, none saved), the keychain is never read, and nothing
    /// is saved or sent.
    init(preview: Bool = false, masked: String? = nil, status: Status = .none) {
        _saved = State(initialValue: preview ? masked : OwnKeyStore.key().map(OwnKeyNotes.masked))
        _status = State(initialValue: status)
        saves = !preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your own Claude key")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saved {
                savedLine(saved)
                modelLine
            } else {
                field
            }
            statusLine
        }
        .lookRowBox()
    }

    private var choice: OwnKeyNotes.Choice { OwnKeyNotes.Choice.saved(picked) }

    private var subtitle: String {
        saved == nil
            ? String(localized: "Paste an Anthropic access key and Claude writes your call notes and to-dos, billed to your Anthropic account. The call's words go straight from this Mac to Anthropic")
            : String(localized: "\(choice.name) writes your call notes and to-dos, billed to your Anthropic account. The call's words go straight from this Mac to Anthropic")
    }

    /// Which Claude writes the notes: Sonnet unless another is picked. A
    /// new pick is checked at once, since a key may not reach every model.
    private var modelLine: some View {
        HStack(spacing: 8) {
            Text("Model")
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            LookMenu(choice.name) {
                ForEach(OwnKeyNotes.Choice.allCases, id: \.self) { option in
                    Button {
                        guard option != choice else { return }
                        picked = option.rawValue
                        check()
                    } label: {
                        Text(verbatim: option == choice ? "✓ \(option.name)" : option.name)
                        Text(option.note)
                    }
                }
            }
            .accessibilityLabel("Model: \(choice.name)")
        }
    }

    private func savedLine(_ masked: String) -> some View {
        HStack(spacing: 8) {
            Text(masked)
                .font(Theme.chrome(11.5).monospaced())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .accessibilityLabel("Key ending \(String(masked.suffix(4)))")
            Spacer(minLength: 8)
            LookButton("Check") { check() }
                .disabled(status == .checking)
            LookButton("Remove") { remove() }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            SecureField("Anthropic access key", text: $draft, prompt: Text("sk-ant-…"))
                .textFieldStyle(.plain)
                .font(Theme.chrome(11.5).monospaced())
                .foregroundStyle(Theme.textPrimary)
                .focused($typing)
                .onSubmit(save)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(SettingsLook.rowFill))
                .overlay(Capsule().strokeBorder(typing ? SettingsLook.selectedStroke : SettingsLook.rowStroke,
                                                lineWidth: 1))
            LookButton("Save", action: save)
                .disabled(OwnKeyNotes.cleaned(draft).isEmpty)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .none:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking with Anthropic…")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .works:
            LookStatus(ok: true, text: String(localized: "The key works. Your next call's notes come from Claude"))
        case .problem(let line):
            LookStatus(ok: false, text: line)
        }
    }

    private func save() {
        let key = OwnKeyNotes.cleaned(draft)
        guard !key.isEmpty else { return }
        guard OwnKeyNotes.looksLikeKey(key) else {
            status = .problem(String(localized: "That doesn't look like an Anthropic access key. It starts with sk-ant-"))
            return
        }
        guard saves else { return }
        guard OwnKeyStore.save(key) else {
            status = .problem(String(localized: "The keychain didn't take the key. Try again"))
            return
        }
        draft = ""
        typing = false
        saved = OwnKeyNotes.masked(key)
        check()
    }

    private func check() {
        guard saves, let key = OwnKeyStore.key() else { return }
        status = .checking
        Task {
            let problem = await OwnKeyNotesService.shared.check(key)
            status = problem.map { .problem($0.checkLine) } ?? .works
        }
    }

    private func remove() {
        if saves { OwnKeyStore.remove() }
        saved = nil
        status = .none
    }
}
