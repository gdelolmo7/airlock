import AVFAudio
import SwiftUI
import AirlockCore

/// The settings window content. Deliberately native — system light/dark, a
/// sidebar and grouped forms — unlike the always-dark obsidian notch surface.
///
/// Sidebar rather than tabs: three tabs fitted, seven do not, and each new group
/// made the remaining tabs narrower and the panes longer.
struct SettingsView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is typed in the sidebar's search field (card Settings 3).
    @State private var query = ""
    /// The last reveal that was scrolled to (`land`).
    @State private var landedSerial: UUID?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    paneList
                } else {
                    SettingsSearchResults(query: query)
                }
            }
            .navigationSplitViewColumnWidth(min: 194, ideal: 204, max: 240)
        } detail: {
            ScrollViewReader { proxy in
                Group {
                    // `resolved`, so a deep link to a folded pane lands where its
                    // contents actually went rather than on a room that no longer
                    // exists.
                    switch model.pane.resolved {
                    case .general: GeneralPane()
                    case .appearance: NotchPane()
                    case .clipboard: ClipboardPane()
                    case .voice: DictationPane()
                    case .agents: AgentsPane()
                    case .permissions: PermissionsPane()
                    case .license: LicensePane()
                    #if AIRLOCK_GUIDE
                    case .guide: GuidePane()
                    case .privacy: PrivacyPane()
                    #else
                    // The guide's two panes, never in the sidebar without it.
                    case .guide, .privacy: EmptyView()
                    #endif
                    // `resolved` never returns these; they are listed so the switch
                    // stays exhaustive if a case is ever un-folded.
                    case .widgets, .policy, .tray, .about: EmptyView()
                    }
                }
                .task(id: model.revealRequest) { await land(model.revealRequest, proxy: proxy) }
            }
            .navigationTitle(model.pane.resolved.title)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .frame(width: 780, height: 540)
        .onAppear { model.refresh() }
    }

    private var paneList: some View {
        @Bindable var model = model
        // The nine, not `allCases` — `tray` and `about` survive as cases
        // only so stored preferences and deep links still decode.
        return List(SettingsPane.sidebar(), selection: $model.pane) { entry in
            NavigationLink(value: entry) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                        Text(entry.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: entry.symbol)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Scrolls to the row a link asked for and lights it up for a moment.
    ///
    /// The short wait first is for the page: a link usually switches pages
    /// too, and the row it names does not exist until the new page has been
    /// laid out once.
    private func land(_ request: SettingsModel.RevealRequest?, proxy: ScrollViewProxy) async {
        // Once each. The task sits on the `Group`, which hands it to every
        // page, so it runs again each time a page appears; without this, a
        // row found once was scrolled to and lit up on every later visit.
        guard let request, request.serial != landedSerial else { return }
        landedSerial = request.serial
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { proxy.scrollTo(request.anchor, anchor: .center) }
        model.highlighted = request.anchor
        try? await Task.sleep(for: .seconds(1.6))
        if model.highlighted == request.anchor { model.highlighted = nil }
    }
}

/// The sidebar while something is typed in the search field: matching
/// settings, best first, each with the page it is on. Choosing one opens that
/// page on that row.
private struct SettingsSearchResults: View {
    let query: String
    @Environment(SettingsModel.self) private var model
    @Environment(AgentsWidgetModel.self) private var agents
    @State private var chosen: SettingsAnchor?

    var body: some View {
        let results = SettingsAnchor.search(query, agentsOn: agents.isEnabled)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results, selection: $chosen) { anchor in
                VStack(alignment: .leading, spacing: 1) {
                    Text(anchor.title)
                    Text(anchor.pane.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(anchor)
            }
            .onChange(of: chosen) { _, anchor in
                guard let anchor else { return }
                model.reveal(anchor)
                // Let go of it, so choosing the same row again is a change and
                // lands again after scrolling away.
                chosen = nil
            }
            .onChange(of: query) { chosen = nil }
        }
    }
}

/// A sentence whose answer lives on another page, with the way there attached.
///
/// Naming the other pane is honest and still a dead end: the reader has been
/// told that a switch exists somewhere else and left to go and find it. The
/// selection is on `SettingsModel` rather than in a view's `@State` exactly so
/// anything can move it — the window is built once and reused, so a pane change
/// has to survive the view already existing.
struct PaneReference: View {
    @Environment(SettingsModel.self) private var model
    private let text: String?
    private let pane: SettingsPane
    private let anchor: SettingsAnchor?
    /// Names what the button is for when "Open <page>" would not read well,
    /// as with "Open The notch".
    private let label: String?

    init(_ text: String? = nil, to pane: SettingsPane) {
        self.text = text
        self.pane = pane
        self.anchor = nil
        self.label = nil
    }

    /// Lands on the row itself, scrolled to and lit up, not just its page.
    init(_ text: String? = nil, to anchor: SettingsAnchor, label: String? = nil) {
        self.text = text
        self.pane = anchor.pane
        self.anchor = anchor
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Optional, because the sentence is only worth saying once. Where
            // the row above already states the fact, repeating it here just
            // makes VoiceOver read it twice — the button's own label carries
            // the destination.
            if let text {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A real button, not a tappable phrase: the label says where it
            // goes, so VoiceOver reads the destination rather than "link".
            Button(label ?? "Open \(pane.title)") {
                if let anchor { model.reveal(anchor) } else { model.pane = pane }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(SettingsModel.self) private var model
    @AppStorage(Ticks.defaultsKey) private var trackpadTicks = true
    @AppStorage(Sounds.levelKey) private var soundLevel: String?

    /// What the chosen level plays, in words.
    private var soundsExplanation: String {
        switch Sounds.binding($soundLevel).wrappedValue {
        case .off:
            "Airlock makes no sound. The notch still opens when a request needs you."
        case .important:
            "A soft call when a request needs you, and a chime when an agent finishes or the guide reaches your goal. As loud as your Mac's alert sounds."
        case .all:
            "Also a light tap when you approve a request, and a low note when the guide has to stop. As loud as your Mac's alert sounds."
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("When should Airlock start?") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .settingsAnchor(.launchAtLogin)
                .disabled(!model.isBundled)
                if !model.isBundled {
                    Text("Launch at login only works in the installed Airlock app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let note = model.launchAtLoginNote {
                    LaunchAtLoginProblem(note: note)
                }
            }

            NotchScreenSection(followsMainDisplay: $model.followsMainDisplay,
                               showsOnExternalWhenClosed: $model.showsOnExternalWhenClosed,
                               canSeeFullScreen: TypeService.isTrusted)

            Section("Sound and touch") {
                Picker("Sounds", selection: Sounds.binding($soundLevel)) {
                    Text("Off").tag(SoundLevel.off)
                    Text("Only important").tag(SoundLevel.important)
                    Text("All").tag(SoundLevel.all)
                }
                .settingsAnchor(.sounds)
                Text(soundsExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Trackpad feedback", isOn: $trackpadTicks)
                Text("A light tap under your finger when you approve or deny a request, switch tabs, drop a file on the shelf, or scroll to the end of a list. Only things you do, never things that happen on their own. Mac trackpads only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Version, updates, health and the diagnostics paste. What was the
            // About pane, where people were already going to look for it.
            AboutSettings()
            AdvancedSwitch()
            #if AIRLOCK_GUIDE
            GuideSettings()
            #endif
        }
        .formStyle(.grouped)
        #if AIRLOCK_GUIDE
        // ⌥ held while General opens reveals the guide prototype's section.
        .onAppear { GuidePreferences.unlockIfOptionHeld() }
        #endif
    }
}

/// "Which screen is the notch on?" — the placement switches, and the two
/// cases where the notch cannot do what the paragraph promises.
///
/// Values in rather than models read, so the state gallery draws this section
/// as it ships (I21, I23). It changes no placement; it only says what the
/// placement rules already do.
struct NotchScreenSection: View {
    @Binding var followsMainDisplay: Bool
    @Binding var showsOnExternalWhenClosed: Bool
    /// Whether Accessibility is granted — full screen is read through it.
    var canSeeFullScreen: Bool

    /// Without Accessibility, `FullScreenFront` cannot see a full-screen
    /// window, so the notch stays over it — and nothing said why.
    static let fullScreenNeedsAccessibility =
        "Without the Accessibility permission the notch can't tell when an app is full screen, so it stays on top of it."
    /// Lid closed, this switch off: there is no screen left to draw on, and
    /// until this sentence nothing said so before it happened.
    static let lidClosedHidesTheNotch =
        "With this off, the notch has nowhere to show while the lid is closed, so nothing on screen will tell you when something needs you."

    var body: some View {
        Section("Which screen is the notch on?") {
            Toggle("Show on the main display", isOn: $followsMainDisplay)
                .settingsAnchor(.displays)
            if !followsMainDisplay {
                Toggle("Show on an external display when the lid is closed",
                       isOn: $showsOnExternalWhenClosed)
                if !showsOnExternalWhenClosed {
                    Text(Self.lidClosedHidesTheNotch)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(followsMainDisplay
                 ? "The notch goes wherever your main display is (the one set as main in System Settings › Displays). On a monitor it sits in the middle of the menu bar and works the same. Dragging files onto it for the Shelf only works on a MacBook's notch. In full screen it hides with the menu bar and comes back when you move the pointer to the top. It still appears on its own when an agent needs you."
                 : "The notch stays on your MacBook. With the lid closed, it can sit in the middle of the menu bar on your main display instead, and works the same. Dragging files onto it for the Shelf only works on the MacBook. In full screen it hides with the menu bar and comes back when you move the pointer to the top. It still appears on its own when an agent needs you.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !canSeeFullScreen {
                ProblemCard(sentence: Self.fullScreenNeedsAccessibility, button: "Turn it on",
                            action: { TypeService.openAccessibilitySettings() })
            }
        }
    }
}

// MARK: - Appearance

/// How the notch looks, and what it shows — one pane, because they are one
/// question. See `SettingsPane` for why the two were merged.
private struct NotchPane: View {
    @Environment(\.islandPreview) private var islandPreview

    var body: some View {
        Form {
            // The island as it is now, redrawn as anything below changes
            // (card Settings 2).
            if let islandPreview {
                Section { islandPreview() }
            }
            NotchLookSections()
            WidgetSections()
            AdvancedSwitch()
        }
        .formStyle(.grouped)
    }
}

private struct NotchLookSections: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(NotchAppearanceModel.self) private var appearance
    /// Whether the battery is in the gutter at all is the Widgets toggle, and
    /// both the demand figure and the percentage switch depend on it.
    @Environment(BatteryWidgetModel.self) private var battery
    /// Same again for usage: the rate-limit figures go with the agent surfaces.
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(UsageConnectionModel.self) private var usage
    /// For the link down to the widget switches, which are on this same page.
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var appearance = appearance
        // Sections, not a Form: `NotchPane` owns the Form both halves sit in.
        Group {
            Section("How should the notch look?") {
                Picker("Background", selection: $appearance.surface) {
                    ForEach(NotchSurface.allCases) { surface in
                        Text(surface.label).tag(surface)
                    }
                }
                .settingsAnchor(.surface)
                .pickerStyle(.segmented)
                Text(surfaceNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("How wide is the open notch?") {
                LabeledContent("Width") {
                    HStack(spacing: 10) {
                        // The screen's range, not the product's: half the screen
                        // is the whole window, the island drawn around the panel
                        // has to fit in it, and points past it are clipped by
                        // the window edge rather than scrolled.
                        Slider(value: $appearance.panelWidth,
                               in: appearance.widthRange, step: 10)
                            .frame(width: 220)
                        // Relative to the default, not in points: "640pt"
                        // asked people to know what a point is (X9).
                        Text("\(Int((appearance.panelWidth / NotchAppearanceModel.defaultPanelWidth * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .settingsAnchor(.panelWidth)
                // Width is not a free choice: the gutters flank the camera, and
                // content wider than its gutter is drawn behind the housing.
                // Saying so live beats letting it be discovered by eye.
                if let advice = appearance.widthAdvice(batteryVisible: battery.isEnabled,
                                                       usageVisible: usageVisible) {
                    ProblemCard(sentence: advice)
                } else {
                    Text(gutterSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Reset width") {
                    appearance.panelWidth = NotchAppearanceModel.defaultPanelWidth
                }
            }

            Section("How big is the text?") {
                LabeledContent("Text size") {
                    HStack(spacing: 10) {
                        Slider(value: $appearance.textScale,
                               in: NotchAppearanceModel.textScaleRange, step: 0.1)
                            .frame(width: 220)
                        Text("\(Int(appearance.textScale * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .settingsAnchor(.textSize)
                Text("Makes the notch's text up to 140% bigger. The strip beside the camera keeps its size — text that grew there would be cut off rather than wrap — and the top bar grows only part way, because it has to stay clear of the camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appearance.textScale > 1.2 {
                    // Honest rather than silent: at the top of the range a
                    // narrow panel runs out of width before it runs out of
                    // height, and the fix is the slider directly above.
                    Text("At this size a wider notch helps — long lines are cut short before they wrap.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Reset text size") { appearance.textScale = 1 }
            }

            Section("What shows beside the camera?") {
                Toggle("Claude usage limits", isOn: $appearance.showsUsageInGutter)
                    .settingsAnchor(.usageLimits)
                    .disabled(!agents.isEnabled)
                    // The switch is not only a display choice: with it on,
                    // Airlock keeps itself connected to where the figures come
                    // from, and with it off it disconnects rather than leaving
                    // a reader nobody reads. See `UsageConnection`.
                    .onChange(of: appearance.showsUsageInGutter) { _, on in
                        usage.sync(wantsUsage: on)
                    }
                if appearance.showsUsageInGutter, agents.isEnabled { usageConnection }
                Toggle("Battery percentage", isOn: $appearance.showsBatteryPercentage)
                    .settingsAnchor(.batteryPercentage)
                    .disabled(!battery.isEnabled)
                // Naming the switch that is actually in the way, rather than
                // leaving a dead control to be poked at. Both of these live in
                // Widgets, which is not where you are looking when you notice
                // the thing missing from the top bar — so the sentence carries
                // the way there rather than leaving you to find it.
                // The switches are further down this same page, so the way
                // there scrolls to them rather than "opening" the page you
                // are already on (X11).
                if let off = disabledNote {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(off)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Show the switches") { model.reveal(SettingsAnchor.widgets) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Both sit to the right of the camera. Turning one off frees room there, which is the other way to stop them running behind the camera.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // A slider measured in points, for the space around a camera —
            // nobody's first question, and a stranger reading it learns that
            // this app expects them to know what a point is.
            if advanced {
                Section("Camera") {
                    // "Reserved centre" named the mechanism; this names the
                    // thing being set. The number is how much room the camera
                    // housing is given, and everyone reading this pane is
                    // thinking about the housing rather than a reservation.
                    LabeledContent("Clear space around the camera") {
                        HStack(spacing: 10) {
                            Slider(value: $appearance.centreTightening, in: 0...40, step: 2)
                                .frame(width: 220)
                            Text("−\(Int(appearance.centreTightening))")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    Text("How much narrower than the camera's measured cutout to keep clear. Anything above zero is space the camera actually covers, so whatever is placed there disappears. Leave it at zero unless you need a little more room beside the camera.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Whether the figures can reach the gutter at all, said plainly.
    ///
    /// A switch that is on for something that cannot work is what this pane was
    /// quietly offering: the figures arrive through Claude's status line,
    /// Claude keeps only one, and another tool taking it leaves the switch on
    /// and the gutter empty for good. So the state is on screen, with the one
    /// button that fixes it — and, connected or not, the sentence no amount of
    /// fixing changes: only a session in a terminal ever reports usage.
    @ViewBuilder
    private var usageConnection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch usage.state {
            case .connected:
                Text("Connected. The figures only come from a Claude session in a terminal — the desktop app never reports them, so open one to fill them in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .replaced:
                Text("Not connected, so these figures can't update. Airlock reads them from the line at the bottom of a Claude session, and something else is using it. Connecting puts Airlock back without changing what you see there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect") { usage.connect() }
            case .hooksMissing:
                PaneReference("Connect Claude Code first. Claude usage comes from it.",
                              to: .agents)
            }
            if let failure = usage.failure {
                ProblemCard(sentence: failure, tone: .stopped)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Reading it touches the settings file, so it happens when the pane
        // appears rather than on every redraw — and it has to happen at all,
        // because the status line can change while this window is open.
        .onAppear { usage.refresh() }
    }

    /// What the gutter actually has to hold — the switch here ANDed with the
    /// Widgets one, which is what the top bar draws against.
    private var usageVisible: Bool { appearance.showsUsageInGutter && agents.isEnabled }

    private var disabledNote: String? {
        switch (agents.isEnabled, battery.isEnabled) {
        case (true, true): return nil
        case (false, true):
            return "AI agents are switched off further down this page, so Claude usage isn't beside the camera."
        case (true, false):
            return "The battery is switched off further down this page, so it isn't beside the camera."
        case (false, false):
            return "AI agents and the battery are both switched off further down this page, so neither shows beside the camera — the settings gear has the space to itself."
        }
    }

    private var surfaceNote: String {
        switch appearance.surface {
        case .black:
            return "Solid black, so the notch reads as one piece with the camera housing — which is black whatever you do."
        case .darkGlass, .lightGlass:
            let caveat = appearance.surface == .lightGlass
                ? " The camera area itself is always black, so a light notch shows a black strip where it meets it when closed."
                : " Only visible over a colourful desktop; against a dark wallpaper it looks much like black."
            return "Blurs the desktop behind the notch using Liquid Glass." + caveat
        }
    }

    /// In words, not points (X9): what the width buys, which is room either
    /// side of the camera for the top bar.
    private var gutterSummary: String {
        guard appearance.centreTightening > 0 else {
            return "A wider notch leaves more room either side of the camera for the battery and Claude usage."
        }
        return "A wider notch leaves more room either side of the camera for the battery and Claude usage. "
            + "Some of that room is the clear space set under Camera below."
    }
}

// MARK: - Widgets

/// One widget: whether it shows, and where.
///
/// The column popup writes the same `widget.column` the panel's arrange-mode
/// drag writes — deliberately, so the two are editors of one setting rather
/// than two competing sources of layout.
private struct WidgetRow: View {
    let title: String
    let id: String
    @Binding var isOn: Bool
    /// UserDefaults is invisible to `@Observable`, so the popup needs a nudge
    /// to re-read after it writes.
    @State private var revision = 0

    init(_ title: String, id: String, isOn: Binding<Bool>) {
        self.title = title
        self.id = id
        self._isOn = isOn
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { _ = revision; return WidgetArrangement.column(for: id) ?? .full },
                    set: { WidgetArrangement.setColumn($0, for: id); revision += 1 })) {
                    Text("Leading").tag(WidgetColumn.leading)
                    Text("Trailing").tag(WidgetColumn.trailing)
                    Text("Full width").tag(WidgetColumn.full)
                }
                .labelsHidden()
                .fixedSize()
                // A column for something that is not drawn is a choice with no
                // effect, so it follows the switch.
                .disabled(!isOn)

                Toggle("", isOn: $isOn).labelsHidden()
            }
        } label: {
            Text(title)
        }
    }
}

private struct WidgetSections: View {
    @Environment(MediaWidgetModel.self) private var media
    @Environment(SoundWidgetModel.self) private var sound
    @Environment(AppVolumeModel.self) private var appVolume
    @Environment(CalendarWidgetModel.self) private var calendar
    @Environment(BatteryWidgetModel.self) private var battery
    @Environment(SystemStatsWidgetModel.self) private var system
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(RepositoryWidgetModel.self) private var repository
    @Environment(SystemControlsModel.self) private var controls
    /// Only for the gate hotkey's conflict check — the two hold keys are what
    /// a chord can collide with. See `CommandBarChord`.
    @Environment(DictationModel.self) private var dictation
    #if AIRLOCK_GUIDE
    @AppStorage(AskWidget.enabledKey) private var asksOnHome = true
    #endif
    @State private var choosingCalendars = false
    /// With the guide on, the agents switch is Developer mode (card 3.02).
    private var guideOn: Bool { GuideSwitch.isOn }

    var body: some View {
        // Sections, not a Form: `NotchPane` owns the Form both halves sit in.
        Group {
            // Switch AND column on one row. They are the same decision about
            // the same widget — "show this, there" — and the column popup writes
            // `widget.column`, which is exactly what arrange mode's drag writes.
            // One setting, two editors, as the handoff asks.
            Section("What shows when it's open?") {
                #if AIRLOCK_GUIDE
                if SettingsPane.guideIsOn {
                    Toggle(isOn: $asksOnHome) {
                        Text("Ask strip on Home")
                        Text("A line at the top of Home that starts the guide")
                    }
                }
                #endif
                WidgetRow("Media (Spotify & Apple Music)", id: "media",
                          isOn: Binding(get: { media.isEnabled },
                                        set: { media.isEnabled = $0 }))
                    .settingsAnchor(.widgets)
                WidgetRow("Sound (output & per-app volume)", id: "sound",
                          isOn: Binding(get: { sound.isEnabled },
                                        set: { sound.isEnabled = $0 }))
                WidgetRow("Calendar", id: "calendar",
                          isOn: Binding(get: { calendar.isEnabled },
                                        set: { calendar.isEnabled = $0 }))
                // No column: it is gutter chrome, drawn beside the housing on
                // every tab, so there is no slot to place it in.
                Toggle("Battery", isOn: Binding(
                    get: { battery.isEnabled }, set: { battery.isEnabled = $0 }))
                WidgetRow("System (CPU, GPU & Memory)", id: "system",
                          isOn: Binding(get: { system.isEnabled },
                                        set: { system.isEnabled = $0 }))
                WidgetRow("Repository status", id: "repository",
                          isOn: Binding(get: { repository.isEnabled },
                                        set: { repository.isEnabled = $0 }))
                Text("Repository status shows the branch and uncommitted changes for whatever checkout each agent session is working in — so it lives on the Agents tab, and appears only when a session is running in a git repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("How should the music bars move?") {
                Toggle("Wave follows the audio", isOn: Binding(
                    get: { media.reactiveWave }, set: { media.reactiveWave = $0 }))
                    .settingsAnchor(.reactiveWave)
                    .disabled(!media.isEnabled)
                Text(media.isEnabled
                     ? "The bars beside the notch normally run their own animation. Switched on, they follow the actual audio coming out of Spotify or Music — which means asking macOS for permission to hear the music the first time something plays, and listening while it does. Nothing is recorded, stored or sent anywhere; the only thing computed is how tall to draw five bars."
                     : "Turn media on above to use this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = media.tapStatus {
                    WaveTapStatusLine(status: status, isProblem: media.tapStatusIsProblem,
                                      needsPermission: media.tapStatusNeedsPermission)
                }
            }

            Section("Should each app get its own volume?") {
                Toggle("Per-app volume", isOn: Binding(
                    get: { appVolume.isEnabled }, set: { appVolume.isEnabled = $0 }))
                    .settingsAnchor(.perAppVolume)
                Text("The sound card switches the output device and moves the system level — the things macOS hides behind an Option-click on the menu bar. Per-app volume is the mixer it never shipped: a level and a mute for each app making sound, kept per app and remembered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Off by default, because it is the one thing here that takes over the audio path: an app you turn down has its sound passed through Airlock, made quieter and played back, which asks macOS for permission to hear system audio the first time. Nothing is recorded, stored or sent anywhere. Leave it off and Airlock never touches the sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Deliberately NOT disabled by the Sound switch above, unlike
                // the reactive wave. Hiding the card hides the only mixer, so a
                // disabled switch would leave the taps running with no way to
                // stop them; this one has to stay reachable to be revocable.
                if !sound.isEnabled, appVolume.isEnabled {
                    ProblemCard(sentence: "Sound is switched off above, so the levels still apply but the mixer isn't in the notch.")
                }
            }

            KeepAwakeSection(controls: controls)

            Section(guideOn ? "Developer mode" : "AI agents") {
                // Reads the SURFACE, not the stored flag. While the answer is
                // still derived and no hooks exist, the Agents tab is on screen
                // asking to be set up (`AgentsWidget.isUnconfigured`) — and a
                // switch reading "off" beside a visible tab is one the user
                // cannot use to dismiss it, because switching an off switch off
                // is not a gesture. Flipping it here writes `.chosen(false)`,
                // which is the explicit no that hides it.
                Toggle(guideOn ? "Developer mode" : "AI agents", isOn: Binding(
                    get: { agents.isEnabled || (!guideOn && agents.basis == .noHooksInstalled) },
                    set: { agents.choose($0) }))
                    .settingsAnchor(.agentsSwitch)
                Text(agents.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if guideOn {
                    // Card 3.02. The same switch, named for who it is for.
                    Text("For people who use Claude Code or Codex: the Agents tab and its settings page, connecting them, Claude usage, and handing a question to Claude Code. A request waiting for your answer always shows, whatever this says.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Everything for coding agents: the Agents tab and its quick-prompt bar, the agent icons beside the notch, and Claude usage in the top bar. Everything else — clipboard, Shelf, dictation, calendar, media — works the same either way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // A row and a sheet, not seven toggles inline. Somebody with seven
            // calendars was reading a list as long as every other setting on
            // the pane put together, for a choice they make once — so the pane
            // states the answer and the sheet holds the switches.
            Section("Which calendars should it read?") {
                if !calendar.isEnabled {
                    // Picking calendars for a widget that isn't shown is a
                    // control with nothing behind it.
                    Text("Turn the calendar on above to choose which calendars it reads.")
                        .settingsAnchor(.calendars)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if calendar.authStatus == .fullAccess {
                    if calendar.allCalendars.isEmpty {
                        Text("No calendars found.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Reading") {
                            HStack(spacing: 10) {
                                Text(calendar.selection.summary(
                                    amongst: calendar.allCalendars.map(\.id)))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                Button("Choose…") { choosingCalendars = true }
                            }
                        }
                        .settingsAnchor(.calendars)
                    }
                } else {
                    Button("Allow Calendar") { Task { await calendar.requestAccess() } }
                    if let note = calendar.accessNote {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            // The shelf is a widget; it does not need a room of its own.
            TraySettings()
        }
        .sheet(isPresented: $choosingCalendars) {
            CalendarPickerSheet(calendar: calendar) { choosingCalendars = false }
        }
    }
}

/// Which calendars the notch reads.
///
/// A sheet because this is a set-once choice made against a list only the user
/// knows the length of: seven calendars inline was longer than every other
/// setting on the Widgets pane combined, for something nobody revisits.
private struct CalendarPickerSheet: View {
    let calendar: CalendarWidgetModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendars")
                .font(.headline)
            Text("The notch reads the ones you tick. Read-only — nothing is ever written back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                ForEach(calendar.allCalendars, id: \.id) { entry in
                    Toggle(entry.title, isOn: Binding(
                        get: { calendar.selection.includes(entry.id) },
                        set: { on in
                            calendar.selection = calendar.selection.setting(
                                entry.id, to: on,
                                amongst: calendar.allCalendars.map(\.id))
                        }))
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 120, maxHeight: 260)

            // Unticking the last one is a thing you are allowed to mean, and it
            // used to switch every calendar back on — so the state says so out
            // loud rather than looking like the switches failed to take. Three
            // states, three sentences: see `CalendarSelection.summary`.
            Text(calendar.selection.summary(amongst: calendar.allCalendars.map(\.id)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Tray

/// The shelf's settings, hosted by the Widgets pane.
///
/// It had a room of its own and did not need one: the tray IS a widget, and a
/// pane holding one switch and a folder path was a sidebar row charging full
/// price for two facts. Kept as its own view so the sections stay legible —
/// only its host moved.
private struct TraySettings: View {
    @Environment(TrayModel.self) private var tray

    var body: some View {
        Group {
            Section("What's on the shelf?") {
                LabeledContent("Items") {
                    Text("\(tray.items.count)").foregroundStyle(.secondary)
                }
                .settingsAnchor(.shelf)
                HStack {
                    Button("Open folder") { tray.openFolder() }
                    Button("Clear") { tray.clear() }
                        .disabled(tray.items.isEmpty)
                }
                Text("Clear moves everything to the Trash, so it is recoverable from there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Where are shelf files kept?") {
                LabeledContent("Location") {
                    Text(tray.directory.path)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Dropped files are moved in, so a file leaves the folder you dragged it out of — hold Option while dropping to leave the original where it is. The workspace beside it is where the notch opens a terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

/// Version, updates and diagnostics — hosted by General.
///
/// It was its own sidebar row, which put the two things people actually come
/// looking for (is there an update, and how do I file a bug) one click further
/// away than "Startup". A version number is a line in General, not a
/// destination.
private struct AboutSettings: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(SettingsModel.self) private var model
    /// `lastCheck` and `canCheck` are stored on the model and kept current by
    /// KVO on Sparkle's own properties, so this page redraws when the check
    /// finishes rather than when the app next becomes active. It has to: the
    /// check and its "You're up to date" sheet are in-process, so the app never
    /// resigns active and a re-read on the way back never happens.
    @Environment(UpdaterModel.self) private var updater
    @Environment(LicenseModel.self) private var license
    @Environment(MediaWidgetModel.self) private var media
    @Environment(SoundWidgetModel.self) private var sound
    @Environment(AppVolumeModel.self) private var appVolume
    @Environment(CalendarWidgetModel.self) private var calendar
    @Environment(BatteryWidgetModel.self) private var battery
    @Environment(SystemStatsWidgetModel.self) private var system
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(RepositoryWidgetModel.self) private var repository
    @Environment(ClipboardWidgetModel.self) private var clipboard

    /// Built once when the page appears rather than on every redraw: it asks
    /// EventKit, AVFoundation and the window server, and this pane redraws
    /// whenever Sparkle changes its mind about anything.
    @State private var diagnostics = ""
    @State private var copied = false

    var body: some View {
        @Bindable var updater = updater
        return Group {
            Section {
                LabeledContent("Version") { Text(model.versionLabel) }
                // Support's question, not a customer's: under the advanced
                // switch with the diagnostics paste, rather than a line of
                // reverse-DNS on the page everybody lands on.
                if advanced, model.isBundled, let id = Bundle.main.bundleIdentifier {
                    LabeledContent("Bundle ID") {
                        Text(id).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            // The whole group, not just the button. Packaging leaves the updater
            // out entirely when there is no appcast URL or signing key, and
            // `swift run` has nothing to update either — a section offering to
            // check is worse than no section at all when nothing can come back.
            if updater.isAvailable {
                UpdatesSection(checksAutomatically: $updater.checksAutomatically,
                               lastCheck: updater.lastCheck,
                               canCheck: updater.canCheck,
                               statusLine: updater.statusLine,
                               onCheck: { updater.checkForUpdates() })
            }

            // Shown before it is copied, not described afterwards. A button
            // that puts an unseen block of text about your machine on the
            // clipboard is a button people are right to distrust — and this one
            // is aimed at a public issue tracker, where the way to find out what
            // was in it is to have already posted it.
            // ABOVE the paste. 7c is the better artefact for support and 7d is
            // the better surface for the user, because it names its own next
            // step — so the readable one leads and the copyable one follows.
            Section("Health") {
                DiagnosticsHealthView(
                    health: health,
                    summary: healthSummary,
                    onCopy: { copyDiagnostics() },
                    onOpen: { remedy in
                        switch remedy {
                        case .agentsSettings: model.pane = .agents
                        case .permissionsSettings: model.pane = .permissions
                        case .updateSettings: model.reveal(.updates)
                        }
                    })
                    .settingsAnchor(.diagnostics)
            }

            // The paste itself is for a bug report, and printing it on the page
            // everybody lands on made the app look like a debugger. The Health
            // list above stays: it says what is wrong and offers the fix, which
            // is the half a customer can act on.
            if advanced {
                Section("Diagnostics") {
                    Text("Everything a bug report needs, and nothing else: no licence key, no file paths, nothing about what you are working on or what your agents are doing. This is exactly what gets copied.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(diagnostics)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor)))
                        .accessibilityLabel("Diagnostics, as they will be copied")
                    HStack(spacing: 10) {
                        Button("Copy Diagnostics") { copyDiagnostics() }
                        if copied {
                            Label("Copied", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(Color.green)
                        }
                    }
                }
            }
        }
        // Re-read on the way in. Permissions and hooks change outside this
        // process, so a report built once and cached for the life of the window
        // would eventually describe a machine that no longer exists.
        .onAppear { rebuildDiagnostics() }
    }

    /// The same report the paste is built from, read as rows.
    ///
    /// Rebuilt from the live report rather than cached alongside it, so the two
    /// can never disagree about the machine they are describing.
    private var health: DiagnosticsHealth {
        DiagnosticsHealth.from(SupportDiagnostics.report(
            settings: model, updater: updater, license: license, widgets: widgetStates))
    }

    private var healthSummary: String {
        let report = SupportDiagnostics.report(settings: model, updater: updater,
                                               license: license, widgets: widgetStates)
        return "\(report.hardware) · notch \(report.hasNotch ? "yes" : "no") · "
            + "\(report.displayCount) display\(report.displayCount == 1 ? "" : "s")"
    }

    private func rebuildDiagnostics() {
        copied = false
        diagnostics = DiagnosticsFormatter.text(
            SupportDiagnostics.report(settings: model, updater: updater,
                                      license: license, widgets: widgetStates))
    }

    private func copyDiagnostics() {
        // Re-read first: the pane may have been open while permissions were
        // granted in System Settings, and copying what is on screen is only
        // honest if what is on screen is current.
        rebuildDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        copied = true
    }

    /// The same switches the Widgets pane draws, in the same order.
    ///
    /// Read from the models rather than from `WidgetRegistry`, which is built in
    /// `AppDelegate` and never handed to the settings window — the Widgets pane
    /// reaches for the models for exactly the same reason.
    private var widgetStates: [DiagnosticsReport.WidgetState] {
        [
            .init("Agents", isEnabled: agents.isEnabled),
            .init("Media", isEnabled: media.isEnabled),
            .init("Sound", isEnabled: sound.isEnabled),
            .init("Per-app volume", isEnabled: appVolume.isEnabled),
            .init("Calendar", isEnabled: calendar.isEnabled),
            .init("Battery", isEnabled: battery.isEnabled),
            .init("System", isEnabled: system.isEnabled),
            .init("Repository", isEnabled: repository.isEnabled),
            .init("Clipboard", isEnabled: clipboard.isEnabled),
        ]
    }
}

// MARK: - Agents

// Not private so the state gallery can draw it on its own (`GallerySettings`).
struct AgentsPane: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(SettingsModel.self) private var model
    /// Answering, the sound and the timeout live here now — see the section
    /// comment below.
    @Environment(AgentsWidgetModel.self) private var agents
    @AppStorage(Sounds.levelKey) private var soundLevel: String?
    /// Only for the gate hotkey's conflict check: a chord sharing a modifier
    /// with a hold key opens the microphone for as long as you hold it.
    @Environment(DictationModel.self) private var dictation
    @Environment(UsageAlertModel.self) private var usageAlerts

    /// Everything about being interrupted, gathered.
    ///
    /// These sat in the Widgets pane, which is about what the panel SHOWS. How
    /// you find out a prompt arrived, how you answer it from the keyboard and
    /// how long it waits before handing itself back are all about being
    /// interrupted — the same subject as the hooks above them, and install
    /// order is the order somebody meets them in.
    private var answering: some View {
        Group {
            Section("Answering from the keyboard") {
                Toggle("Answer with a shortcut", isOn: Binding(
                    get: { agents.hotkeyEnabled }, set: { agents.hotkeyEnabled = $0 }))
                    .settingsAnchor(.gateHotkey)
                // A recorder, not three chords somebody else picked. If all
                // three were taken on your Mac the gate simply had no reachable
                // key — and this is the one surface the app cannot afford to
                // leave unreachable.
                LabeledContent("Answers the waiting request") {
                    HotkeyRecorder(binding: Binding(get: { agents.hotkey },
                                                    set: { agents.hotkey = $0 }),
                                   conflict: { chord in
                        CommandBarChord.collision(chord: chord,
                                                  holdKey: dictation.holdKey,
                                                  askKey: dictation.askKey)
                    })
                }
                .disabled(!agents.hotkeyEnabled)

                if let error = agents.hotkeyError {
                    ProblemCard(sentence: error)
                }
                Text("A request never takes the keyboard by itself — it arrives while you're typing somewhere else, and a keypress meant for your editor would answer something you hadn't read. Press this key and the request becomes answerable; only then does it show its shortcuts. With nothing waiting it opens the Agents tab, and pressing it again closes it. It works even with AI agents switched off in Settings › The notch, because a waiting request is shown either way.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if agents.hotkey == .commandShiftA {
                    // The same honesty the clipboard pane gives ⌘⇧C and Maccy:
                    // a global hotkey outranks an app's own menu shortcut, so
                    // this quietly takes one people may already use.
                    Text("⇧⌘A is also Finder's Applications folder. A global hotkey wins, so Finder won't see it while Airlock is running — pick ⌃⌥⌘A above if you'd rather keep it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Knowing a request arrived") {
                // The same setting as General's Sounds, seen from here: off is
                // Off, on is Only important unless All was already chosen.
                Toggle("Play a sound", isOn: Binding(
                    get: { Sounds.binding($soundLevel).wrappedValue != .off },
                    set: { on in
                        let level = Sounds.binding($soundLevel)
                        if !on { level.wrappedValue = .off } else if level.wrappedValue == .off { level.wrappedValue = .important }
                    }))
                    .settingsAnchor(.promptSound)
                LabeledContent("Sound") {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(
                            get: { agents.gateSoundName }, set: { agents.gateSoundName = $0 })) {
                            ForEach(AgentsWidgetModel.gateSoundChoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        // A sound picker you cannot hear is a list of words.
                        Button("Play") { agents.playGateSound() }
                    }
                }
                .disabled(Sounds.binding($soundLevel).wrappedValue == .off)
                Text("Without a sound, the notch opening is the signal, and that reaches you only if you're looking at the screen. A sound reaches you wherever you are; the spoken announcement reaches VoiceOver users. Settings › General › Sounds turns every Airlock sound on or off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Card Agents 1. Here rather than beside the usage figures on The
            // notch page: those rows are about what the top bar shows, and this
            // is about being told something, the subject of this page.
            Section("Knowing you're near Claude's limit") {
                Picker(selection: Binding(get: { usageAlerts.level },
                                          set: { usageAlerts.level = $0 })) {
                    ForEach(UsageAlert.levelChoices, id: \.self) { level in
                        Text(level == 0 ? "Never" : "At \(level)%").tag(level)
                    }
                } label: {
                    Text("Warn me")
                    Text("The notch says so when the 5-hour or the weekly limit gets this full, once each time")
                }
                .settingsAnchor(.usageWarning)
                Toggle(isOn: Binding(get: { usageAlerts.announcesReset },
                                     set: { usageAlerts.announcesReset = $0 })) {
                    Text("Say when it resets")
                    Text("After a warning, the notch says when that limit is back to zero")
                }
                .disabled(usageAlerts.level == 0)
                Text("Claude usage only updates while Claude Code is running in a terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        Form {
            #if AIRLOCK_GUIDE
            if SettingsPane.guideIsOn { DeveloperModeSection() }
            #endif
            if !SettingsPane.guideIsOn || agents.isEnabled { agentSections }
        }
        .formStyle(.grouped)
    }

    /// The hooks, answering and rules. With the guide on they wait behind
    /// Developer mode; with it off they are the page.
    @ViewBuilder private var agentSections: some View {
            ForEach(model.agents) { row in
                Section(row.name) {
                    LabeledContent("Status") { StatusBadge(status: row.status) }
                    // The file's path is for developers (X24): with Advanced
                    // on, or as the conflict card's "Show the file".
                    if advanced {
                        LabeledContent("Settings file") {
                            Text(row.configPath)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    if let note = caption(for: row.kind) {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                    if case .conflict = row.status {
                        // The same card the Agents tab draws (X25): Airlock
                        // never edits lines it didn't write, so the way
                        // forward is the file, then a fresh look.
                        ProblemCard(icon: "exclamationmark.triangle",
                                    sentence: AgentsConnection.blockedSentence(
                                        .init(name: row.name, status: row.status, settingsPath: row.configPath)),
                                    tone: .needs,
                                    button: AgentsEmptyState.showFile,
                                    action: { model.revealConfig(row) })
                        Button("Check again") { model.refresh() }
                    } else {
                        HStack {
                            actionButton(row)
                            if advanced {
                                Button(AgentsEmptyState.showFile) { model.revealConfig(row) }
                            }
                        }
                    }
                    if let error = row.actionError {
                        ProblemCard(sentence: error, tone: .stopped)
                    }
                }
            }
            Section {
                Text("If Airlock isn't running, your agents carry on as before and ask you in the terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Hooks, then how you hear about a prompt, then how long it waits.
            // Install order, not alphabetical: nothing below matters until a
            // hook exists above.
            answering

            // Advanced because it is read-only here and edited in a file: a
            // number you cannot change is not a setting, it is a fact about an
            // installation, and facts belong with the diagnostics.
            if advanced {
                Section("Giving up") {
                    LabeledContent("Hand the question back after") {
                        Text(model.policy.askTimeout > 0
                             ? "\(Int(model.policy.askTimeout)) seconds"
                             : "never — it waits")
                            .foregroundStyle(.secondary)
                    }
                    .settingsAnchor(.givingUp)
                    // `ask_timeout` is read from the policy file but it does not
                    // belong with the rules: rules are about what RUNS, and this is
                    // about being interrupted — the same subject as the two sections
                    // above it. It is shown here and edited in the file, which is
                    // where the value already lives.
                    Text("An unanswered request goes back to the agent's terminal, which asks you there instead. Waiting never approves or denies anything.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Rules live here now rather than in a room of their own. They are
            // what an agent may do without stopping to ask, which is meaningless
            // until there is an agent — and a stranger who opened "Rules" first
            // met a YAML file and a precedence table.
            PolicySections()
            AdvancedSwitch()
    }

    @ViewBuilder
    private func actionButton(_ row: SettingsModel.AgentRow) -> some View {
        switch row.status {
        case .installed:
            Button("Disconnect") { model.toggle(row) }
        case .notInstalled:
            Button("Connect") { model.toggle(row) }
                .buttonStyle(.borderedProminent)
        case .conflict:
            // Drawn as a problem card above, never as a dead button.
            EmptyView()
        }
    }

    private func caption(for kind: AgentKind) -> String? {
        switch kind {
        case .codex:
            return "You'll see what Codex is doing here. Its requests are still answered in the terminal."
        case .claudeCode:
            return "Claude Code's requests come to the notch: Approve, Deny or Always, plus your rules."
        default:
            return nil
        }
    }
}

private struct SuggestionRow: View {
    @Environment(SettingsModel.self) private var model
    let suggestion: PolicySuggestion
    /// Defaults to the recommended rung, not the literal one.
    @State private var choice: String = ""
    @State private var choosingWidth = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.kind == .allow ? "checkmark.circle" : "nosign")
                .foregroundStyle(suggestion.kind == .allow ? Color.green : Color.red)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                // Plain language first, syntax second — the whole point is that
                // you should not have to think in rules to get one.
                Text(headline)
                // A picker only when there is a real choice. One literal
                // command with nothing safe to widen is not a decision.
                if suggestion.candidates.count > 1 {
                    // The chosen width, and a way to see the others. It was a
                    // pop-up menu, which shows one option at a time — and this
                    // is a decision ABOUT scope, so the three widths are worth
                    // reading side by side rather than one at a time.
                    HStack(spacing: 8) {
                        Text(choice)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("How wide?") { choosingWidth = true }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                } else {
                    Text(suggestion.ruleText)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let risk = suggestion.riskReason {
                    Label("Flagged as \(risk)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                Button(suggestion.kind == .allow ? "Always Allow" : "Always Deny") {
                    model.addPolicyRule(choice, kind: suggestion.kind)
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") { model.dismiss(suggestion) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .onAppear { if choice.isEmpty { choice = suggestion.recommended.text } }
        .sheet(isPresented: $choosingWidth) {
            RuleWidthSheet(suggestion: suggestion,
                           destinationPath: model.scopedPolicy.path,
                           choice: $choice) {
                choosingWidth = false
            } add: {
                choosingWidth = false
                model.addPolicyRule(choice, kind: suggestion.kind)
            }
        }
    }

    private var headline: String {
        let times = suggestion.count == 1 ? "once" : "\(suggestion.count) times"
        return suggestion.kind == .allow
            ? "You've approved this \(times) — stop asking?"
            : "You've refused this \(times) — block it outright?"
    }
}

/// How wide should the rule go?
///
/// **A pop-up menu shows one option at a time, and this is a decision about
/// scope** — the difference between "exactly this command", "any npm test" and
/// "every npm command" is the whole question, and it can only be weighed with
/// the three of them in front of you.
///
/// Narrowest first, which is `RuleGeneralizer`'s own order, with the recommended
/// one preselected: the family rule that works forever rather than twice. And it
/// names the file the rule lands in, because a rule you cannot find later is a
/// rule you cannot undo.
private struct RuleWidthSheet: View {
    let suggestion: PolicySuggestion
    /// The file this rule will land in, passed in rather than assumed. Named
    /// here for the reason the header below gives: a rule you cannot find later
    /// is a rule you cannot undo.
    let destinationPath: String
    @Binding var choice: String
    var cancel: () -> Void
    var add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How wide should the rule go?")
                .font(.headline)
            Text(headline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestion.candidates) { candidate in
                    Button { choice = candidate.text } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: choice == candidate.text
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(choice == candidate.text
                                                 ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.text)
                                    .font(.callout.monospaced())
                                Text(candidate.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // The scoped path, not a constant. This type's own doc comment says
            // it names the file the rule lands in "because a rule you cannot
            // find later is a rule you cannot undo" — and then named the global
            // one whatever the switch said.
            Text("Goes in \(destinationPath)")
                .font(.callout)
                .foregroundStyle(.tertiary)

            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add it", action: add)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var headline: String {
        let times = suggestion.count == 1 ? "once" : "\(suggestion.count) times"
        let verb = suggestion.kind == .allow ? "approved" : "refused"
        return "You \(verb) \(suggestion.ruleText) \(times)."
    }
}

private struct GateRow: View {
    let gate: GateRecord

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(gate.subject ?? gate.toolName)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(gate.outcome.label)
                    if let risk = gate.riskReason {
                        Text("· \(risk)")
                    }
                    Text("· \(gate.decidedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch gate.outcome {
        case .allowedOnce, .alwaysAllowed: return "checkmark.circle.fill"
        case .autoAllowed: return "checkmark.circle"
        case .denied, .autoDenied: return "nosign"
        case .deferred: return "clock.arrow.circlepath"
        }
    }

    private var tint: Color {
        switch gate.outcome {
        case .allowedOnce, .alwaysAllowed, .autoAllowed: return .green
        case .denied, .autoDenied: return .red
        case .deferred: return .secondary
        }
    }
}

private struct StatusBadge: View {
    let status: HookInstallStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private var color: Color {
        switch status {
        case .installed: return .green
        case .notInstalled: return Color(nsColor: .tertiaryLabelColor)
        case .conflict: return .orange
        }
    }

    private var label: String {
        switch status {
        case .installed: return "Connected"
        case .notInstalled: return "Not connected"
        case .conflict: return "Needs a hand"
        }
    }
}

// MARK: - Policy

/// Rules, as sections of the Agents pane — see `SettingsPane` for why they no
/// longer have a pane of their own.
private struct PolicySections: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(SettingsModel.self) private var model
    @State private var draft = ""
    @State private var draftKind: PolicyRuleKind = .allow
    @State private var probeTool = "Bash"
    @State private var probeSubject = ""

    var body: some View {
        // Sections, not a Form: `AgentsPane` owns the Form these sit in.
        Group {
            if !model.suggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(model.suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion)
                    }
                    Text("Offered after the second time you answer the same way. Commands Airlock always asks about, like rm -rf or sudo, are never offered: they would still ask, so the rule would be a promise Airlock can't keep.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // ABOVE the sections it governs. A switch that decides which file
            // every control below writes to, drawn under those controls, is a
            // switch people read after acting.
            Section("Rules for") {
                if model.policyScopeCandidates.isEmpty {
                    // The normal state on a Monday morning, not an edge case: no
                    // agent has run, so there is no project to name. A
                    // one-segment segmented control looks broken and a disabled
                    // segment is a promise not being kept, so there is no picker
                    // at all — just the way in.
                    Text("Project rules live in the folder the agent starts in. Nothing has run yet, so there is only the Everywhere file.")
                        .settingsAnchor(.rules)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(
                        get: { model.policyScope },
                        set: { model.policyScope = $0 }
                    )) {
                        Text("Everywhere").tag(PolicyScope.everywhere)
                        ForEach(model.policyScopeCandidates, id: \.self) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .settingsAnchor(.rules)
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if case .project = model.policyScope {
                        // Said once, plainly. Nothing here writes a .gitignore:
                        // a shared project rule is often exactly what a team
                        // wants committed, and deciding that for them is not
                        // this pane's business.
                        Text("This file is inside your project — it will show up in `git status` as untracked.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Where the rules are kept, and the buttons that open it in an
            // editor. The list above is the same content without the file.
            if advanced {
                Section("Policy file") {
                    LabeledContent("File") {
                        Text(model.scopedPolicy.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    // Loud, and above everything else: a file that failed to parse
                    // contributes NO rules, so the lists below would read as
                    // "nothing configured" when the truth is "nothing is working".
                    ForEach(model.scopedPolicy.problems, id: \.self) { problem in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(problem).font(.callout.monospaced())
                                // The clause that actually matters, and the one the
                                // mockup leaves out: a file that does not parse is
                                // ignored ENTIRELY, so the denies written here are
                                // not in force either. Only the built-in risk floor
                                // still holds.
                                Text(model.policyScope == .everywhere
                                     ? "This file is being ignored entirely, so only Airlock's built-in checks are in effect: risky commands still ask."
                                     : "This file is being ignored entirely, so this project is running on the Everywhere rules alone — including its Never runs list.")
                                    .font(.callout)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    }

                    HStack {
                        if model.scopedPolicy.exists {
                            Button("Open in Editor") { model.openPolicyInEditor() }
                            Button("Show in Finder") { model.revealPolicy() }
                        } else {
                            Button("Create Starter Policy") { model.createStarterPolicy() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Reload") { model.refresh() }
                    }
                    if let note = model.policyNote {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Add a rule") {
                HStack(spacing: 8) {
                    Picker("", selection: $draftKind) {
                        ForEach(PolicyRuleKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()

                    TextField("Tool or Tool(pattern)", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)

                    Button("Add", action: add)
                        .buttonStyle(.borderedProminent)
                        // Refused while the file is broken. `PolicyDocument`
                        // never parses it, so the insert SUCCEEDS and reports
                        // "Added" for a rule landing in a file nothing reads —
                        // and it cannot see the broken line, so adding
                        // `Bash(git push)` beside a malformed `Bash(git push`
                        // leaves you with both and the file still broken.
                        .disabled(parsed == nil || model.scopedPolicy.parseFailed)
                }
                Text(draftHelp)
                    .font(.callout)
                    .foregroundStyle(draftIsInvalid ? .orange : .secondary)
            }

            // Deny FIRST. The numbered list below says deny is rule one, and
            // the pane used to show it second; with two files in play that
            // ordering is the safety story — a project deny is the thing that
            // beats an Everywhere allow.
            rules(.deny)
            rules(.allow)

            // Precedence as three sentences, not a diagram.
            //
            // It is the one thing about this pane that can genuinely surprise
            // somebody: a rule they wrote sitting in the allow list, visibly
            // matching, and the notch still asking. The floor is why, and it is
            // the safety story CLAUDE.md makes non-negotiable, so it is stated
            // where the rules are rather than in a help page.
            // A rule tester, a precedence table, a log of recent gates and
            // a note about a YAML file per project. All of it earns its
            // place the day something behaves oddly, and none of it belongs
            // in front of somebody who has just installed the app.
            if advanced {
                Section {
                    Text("Match counts and \u{201c}added by\u{201d} come from the request history, which doesn't record which project a request came from — so they are totals across every project, even under a project scope.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    // Was a second "Order of precedence" (X27); this one is
                    // only about the counts.
                    Text("Match counts")
                }

                Section("Try it") {
                    HStack(spacing: 8) {
                        TextField("Tool", text: $probeTool)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        TextField("Command or file path", text: $probeSubject)
                            .textFieldStyle(.roundedBorder)
                    }
                    if !probeSubject.trimmingCharacters(in: .whitespaces).isEmpty {
                        verdictRow
                    }
                    Text("Uses the same check the notch uses for a real request, so this is the answer you would actually get.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Which rule wins") {
                    precedence(1, "Deny rules", "auto-denied, and the agent is told which rule.")
                    precedence(2, "Risky commands", "rm -rf, sudo, force push and the like always ask, whatever the allow list says. Built in, not editable.")
                    precedence(3, "Allow rules", "auto-approved silently.")
                    precedence(4, "Otherwise", "the notch asks you.")
                }

                Section("Recent requests (\(model.recentGates.count))") {
                    if model.recentGates.isEmpty {
                        Text("Nothing yet. Every request your agents make — and everything your rules settle without asking — shows up here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentGates.prefix(12)) { gate in
                            GateRow(gate: gate)
                        }
                        HStack {
                            Button("Clear History") { model.clearGateHistory() }
                            Text("Kept on this Mac only, the latest 500.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Per-project rules") {
                    Text("Each project can add `.airlock/policy.yaml`. Project rules merge over Everywhere's, and a project deny always beats an Everywhere allow. Switch scope above to edit one or the other; the Always button in the notch writes to the project file when a session has a working directory.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Rule lists

    @ViewBuilder
    /// Section names say what the rules DO, not which list they are in.
    ///
    /// "Allow" and "Deny" are the file's vocabulary and belong in the rule text,
    /// where they are exact. As headings they made someone read a list of
    /// patterns and then work out the consequence; "Runs without asking" is the
    /// consequence, which is the thing being decided.
    private func rules(_ kind: PolicyRuleKind) -> some View {
        let items = model.scopedPolicy.rules(kind)
        // `id: \.self` is safe ONLY because each scope shows one file.
        // `PolicyRule` hashes over its text, and `Policy.merging` concatenates
        // without dedup — so a merged list containing `Read` from both files
        // would have two equal ids and SwiftUI would drop one.
        return Section(kind == .allow ? "Runs without asking" : "Never runs") {
            switch model.scopedPolicy.state {
            case .unreadable:
                // No list at all, ever, beside a parse failure. An empty list
                // next to a warning reads as "this file has no rules", and the
                // truth is "this file is not being read".
                Text("Can't show the rules — this file didn't parse.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .missing:
                Text(model.policyScope == .everywhere
                     ? "No policy file yet."
                     : "No file here yet — this project runs on the Everywhere rules.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .empty:
                Text(emptyRulesCopy(kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .listing:
                if items.isEmpty {
                    Text(emptyRulesCopy(kind))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items, id: \.self) { rule in
                        ruleRow(rule, kind: kind)
                    }
                }
            }
        }
    }

    /// One list is empty while the other is not — which under a project scope
    /// does NOT mean nothing is auto-approved, because the Everywhere file is
    /// still in force underneath.
    private func emptyRulesCopy(_ kind: PolicyRuleKind) -> String {
        if case .project = model.policyScope {
            return kind == .allow
                ? "Nothing extra is auto-approved here — the Everywhere list still applies."
                : "Nothing extra is denied here — the Everywhere list still applies."
        }
        return kind == .allow
            ? "Nothing is auto-approved — every request asks."
            : "Nothing is auto-denied."
    }

    private func ruleRow(_ rule: PolicyRule, kind: PolicyRuleKind) -> some View {
        let record = model.provenance[rule.canonicalText] ?? .unrecorded
        return HStack {
            Image(systemName: kind == .allow ? "checkmark.circle" : "nosign")
                .foregroundStyle(kind == .allow ? Color.green : Color.red)
            // As written, not canonicalised: this should read back
            // exactly like the line in the file you would go and find.
            Text(rule.text).font(.callout.monospaced()).textSelection(.enabled)

            Spacer(minLength: 8)

            // What it has decided, and who put it there. Both come from the gate
            // log because the FILE cannot say — a rule you wrote and a rule an
            // Always click wrote are the same line of YAML.
            VStack(alignment: .trailing, spacing: 1) {
                Text(matchLabel(record))
                    .foregroundStyle(record.hasNeverMatched ? Color.orange : .secondary)
                Text(authorLabel(record))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)

            Button {
                model.removePolicyRule(rule, kind: kind)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this rule")
        }
    }

    /// The number that makes a dead rule visible.
    private func matchLabel(_ record: RuleProvenance) -> String {
        record.hasNeverMatched ? "never matched"
            : "\(record.matches) match\(record.matches == 1 ? "" : "es")"
    }

    /// "you, Tuesday" for a rule an Always click wrote; "from the template" for
    /// one that was in the file before anybody clicked anything.
    private func authorLabel(_ record: RuleProvenance) -> String {
        guard let authored = record.authoredAt else { return "from the template" }
        return "you, \(Self.authoredFormat.string(from: authored))"
    }

    /// Weekday inside the last week, then a date — "you, Tuesday" is a memory
    /// you can actually check against, and "you, 12 Jun" is one you cannot.
    private static let authoredFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - Add

    private var parsed: PolicyRule? {
        try? PolicyRule(parsing: draft)
    }

    private var draftIsInvalid: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && parsed == nil
    }

    private var draftHelp: String {
        if draftIsInvalid {
            return "Not a rule yet. Use a tool name (Read) or a tool with a glob pattern — Bash(git status), Bash(npm run *), Edit(*/secrets/*)."
        }
        if let parsed, parsed.pattern == nil {
            return "\(parsed.tool) matches every use of that tool, whatever the arguments."
        }
        if let parsed, let pattern = parsed.pattern {
            return "Matches \(parsed.tool) when the \(parsed.tool == "Bash" ? "command" : "path") glob-matches \(pattern)."
        }
        return "Tool name for any use, or Tool(pattern) for a glob — Bash(git status), Bash(npm run *), Edit(*/secrets/*)."
    }

    private func add() {
        guard let parsed else { return }
        model.addPolicyRule(parsed.canonicalText, kind: draftKind)
        draft = ""
    }

    // MARK: - Tester

    private var verdictRow: some View {
        let verdict = model.testPolicy(tool: probeTool, subject: probeSubject)
        return Label {
            Text(describe(verdict)).font(.callout)
        } icon: {
            Image(systemName: symbol(verdict))
        }
        .foregroundStyle(tint(verdict))
    }

    private func describe(_ verdict: PolicyVerdict) -> String {
        switch verdict {
        case .allow(let rule): return "Auto-approved by \(rule)"
        case .deny(let rule): return "Auto-denied by \(rule)"
        case .ask(let risk?): return "Always asks — \(risk)"
        case .ask: return "Asks you in the notch — no rule matches"
        }
    }

    private func symbol(_ verdict: PolicyVerdict) -> String {
        switch verdict {
        case .allow: return "checkmark.circle.fill"
        case .deny: return "nosign"
        case .ask(let risk): return risk == nil ? "questionmark.circle" : "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ verdict: PolicyVerdict) -> Color {
        switch verdict {
        case .allow: return .green
        case .deny: return .red
        case .ask(let risk): return risk == nil ? .secondary : .orange
        }
    }

    private func precedence(_ step: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(step)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}
