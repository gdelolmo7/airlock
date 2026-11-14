import AirlockCore
import SwiftUI

/// The Airlock window's content: one column down the left, with the search
/// for Settings at its top, Calls, then the Settings pages; and to its right
/// whichever was chosen (`SettingsModel.showsCalls`).
///
/// Calls sits above Settings because it is what people come back for, and
/// Settings is where they go once in a while. The row is there only while
/// call notes are on, as the menu bar's "Call Notes…" is.
struct AirlockWindowView: View {
    @Environment(SettingsModel.self) private var model
    /// The calls; missing in a window made without them (the gallery).
    @Environment(CallNotesLibrary.self) private var library: CallNotesLibrary?
    @AppStorage(MeetingNotesModel.enabledKey) private var callNotesOn = MeetingNotesModel.onByDefault
    /// The add-ons' models, for the sidebar's on/off dots. Optional: a
    /// window drawn by the gallery may have none, and then shows no dots.
    @Environment(TrayModel.self) private var tray: TrayModel?
    @Environment(ClipboardWidgetModel.self) private var clipboard: ClipboardWidgetModel?
    @Environment(AgentsWidgetModel.self) private var agents: AgentsWidgetModel?
    @Environment(DictationModel.self) private var dictation: DictationModel?
    /// What is typed in the Settings search field.
    @State private var query = ""
    /// Bumped by ⌘F, which puts the cursor in the Settings search field.
    @State private var searchRequest = 0
    /// The last link into Settings that was scrolled to (`SettingsColumn`).
    @State private var landedSerial: UUID?

    /// The smallest the window goes: the left column, the call list and a
    /// page of notes beside it.
    static let minimumSize = CGSize(width: 816, height: 520)
    /// Its size the first time it opens; after that, the size it was left at.
    static let firstSize = CGSize(width: 940, height: 620)

    var body: some View {
        // The smallest size comes from an empty box, not from the pages, for
        // the reason `CallNotesView` gives.
        Color.clear
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
            .overlay {
                HStack(spacing: 0) {
                    LookSidebar(selection: Binding(get: { model.pane.resolved },
                                                   set: { model.pane = $0; query = "" }),
                                calls: callsRow,
                                isOn: addOnIsOn,
                                query: $query,
                                focusRequest: searchRequest)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(SettingsLook.ground)
            .environment(\.colorScheme, .dark)
            .background {
                // ⌘F, from anywhere in the window: the calls' search while
                // they show, the Settings search otherwise.
                Button("Search") {
                    if showsCalls { library?.searchRequest += 1 } else { searchRequest += 1 }
                }
                .keyboardShortcut("f")
                .hidden()
            }
            .onAppear { model.refresh() }
    }

    /// Whether each add-on is on, read through the same switches its page
    /// flips, so a dot changes the moment the big switch does.
    private var addOnIsOn: ((AddOn) -> Bool)? {
        guard let tray, let clipboard, let agents, let dictation else { return nil }
        let switches = AddOnSwitches(tray: tray, clipboard: clipboard, agents: agents, dictation: dictation)
        let notesOn = callNotesOn
        return { $0 == .meetingNotes ? notesOn : switches.isOn($0) }
    }

    /// The calls are what is chosen, and there are calls to show.
    private var showsCalls: Bool {
        model.showsCalls && callsOffered
    }

    private var callsOffered: Bool {
        callNotesOn && library != nil
    }

    /// The Calls row: chosen while the calls show, and choosing it reads the
    /// calls again, so one made while the window was elsewhere is in the list.
    private var callsRow: Binding<Bool>? {
        guard callsOffered else { return nil }
        return Binding(get: { showsCalls }, set: { chosen in
            guard chosen else { return }
            query = ""
            library?.reload(selecting: nil)
            model.showsCalls = true
        })
    }

    @ViewBuilder private var detail: some View {
        if showsCalls, query.trimmingCharacters(in: .whitespaces).isEmpty {
            CallNotesView()
        } else {
            SettingsColumn(query: $query, landedSerial: $landedSerial)
        }
    }
}
