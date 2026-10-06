import SwiftUI
import AirlockCore

/// The phrases you can say, editable where you can see them.
///
/// **Two lists, not one, and the split is the whole design.** What ships is
/// read-only and searchable — fifty-odd entries nobody should have to retype,
/// shown so you can find out that "go to my downloads" already works instead of
/// discovering it by accident. What you add is a short editable table, and it
/// stays short because the shipped half is doing the bulk of the work.
///
/// Merging them into one editable list was the obvious first idea and is worse:
/// three entries of yours would be lost among fifty of ours, and every shipped
/// row would look deletable when deleting it only means "until the next launch".
struct SiteAliasEditor: View {
    @Environment(AssistantModel.self) private var assistant
    @State private var entries: [Row] = []
    @State private var search = ""
    @State private var loaded = false

    /// Identity that survives editing. A `VoiceSiteAlias` is keyed by its
    /// phrase, so using it directly makes a row lose focus on the first
    /// keystroke — the id changes, SwiftUI rebuilds, the field resigns.
    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var phrase: String
        var url: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            yours
            Divider()
            shipped
        }
        .onAppear(perform: loadOnce)
    }

    // MARK: - Yours

    private var yours: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your phrases")
                .font(.headline)
            Text("Say \"open\" or \"go to\" and the phrase. Yours override the built-in ones, "
                 + "and an app you have installed still wins over both.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if entries.isEmpty {
                Text("Nothing yet — the built-in phrases below already cover the common ones.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }

            ForEach($entries) { $row in
                HStack(spacing: 8) {
                    TextField("what you say", text: $row.phrase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                    Text("→").foregroundStyle(.secondary)
                    TextField("https://…", text: $row.url)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        entries.removeAll { $0.id == row.id }
                        save()
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this phrase")
                }
                // On commit rather than per keystroke: a half-typed URL is not
                // a phrase anybody wants written to disk and re-parsed.
                .onSubmit(save)
            }

            HStack(spacing: 10) {
                Button {
                    entries.append(Row(phrase: "", url: ""))
                } label: {
                    Label("Add a phrase", systemImage: "plus")
                }
                Button("Save") { save() }
                    .disabled(entries.isEmpty)
                Spacer()
                Button("Open the file…") { assistant.siteAliasStore.revealInFinder() }
                    .buttonStyle(.link)
                    .help("The same phrases, as a text file you can keep in version control.")
            }
            .padding(.top, 2)

            if let invalid = firstInvalid {
                ProblemCard(sentence: "\"\(invalid)\" is not a web address, a folder, or a settings pane — "
                      + "that row will be ignored.")
            }
        }
    }

    /// The first row that would be silently dropped on load. Named rather than
    /// counted: one specific string is actionable and "3 rows are invalid" is not.
    private var firstInvalid: String? {
        entries.first {
            !$0.url.trimmingCharacters(in: .whitespaces).isEmpty
                && VoiceSiteAliases.normalized($0.url) == nil
        }?.url
    }

    // MARK: - Shipped

    private var shipped: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Built in").font(.headline)
                Spacer()
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            Text("\(VoiceSiteAliases.defaults.count) phrases that already work, with nothing to set up.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(filteredDefaults) { alias in
                        HStack(spacing: 8) {
                            Text(alias.phrase)
                                .font(.callout)
                                .frame(width: 170, alignment: .leading)
                            Text(displayURL(alias.url))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    private var filteredDefaults: [VoiceSiteAlias] {
        let needle = VoiceMatch.fold(search)
        guard !needle.isEmpty else { return VoiceSiteAliases.defaults }
        return VoiceSiteAliases.defaults.filter {
            VoiceMatch.fold($0.phrase).contains(needle)
                || VoiceMatch.fold($0.url).contains(needle)
        }
    }

    /// Schemes nobody reads as a URL, said in words instead.
    private func displayURL(_ url: String) -> String {
        if url.hasPrefix("x-apple.systempreferences:") { return "System Settings" }
        if url.hasPrefix("file://") {
            return "Finder — " + url.replacingOccurrences(of: "file://" + NSHomeDirectory(), with: "~")
                .replacingOccurrences(of: "file://", with: "")
        }
        if url.hasPrefix("macappstore://") { return "App Store" }
        return url.replacingOccurrences(of: "https://", with: "")
    }

    // MARK: - Persistence

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        entries = assistant.siteAliasStore.loadUserEntries()
            .map { Row(phrase: $0.phrase, url: $0.url) }
    }

    private func save() {
        assistant.siteAliasStore.save(
            entries.map { VoiceSiteAlias(phrase: $0.phrase, url: $0.url) })
        // Straight back into the live table, so a phrase works the moment it is
        // saved rather than after the next cache window.
        Task { await assistant.refreshApps() }
    }
}
