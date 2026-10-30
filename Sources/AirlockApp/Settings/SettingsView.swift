import AVFAudio
import SwiftUI
import AirlockCore

/// The Settings side of the Airlock window (`AirlockWindowView`), in the
/// notch's look: the page chosen in the left column, or what the search at
/// its top found.
///
/// It was a native sidebar and grouped forms, system light or dark. The owner
/// asked for Settings to look like the notch it configures: Voice was drawn in
/// the new rows (`SettingsLook`) first, approved on the real screen, and every
/// page followed. Each is a `LookPage`: one line per setting, the longer
/// explanations behind More options.
///
/// A column rather than tabs across the top: the owner tried both on
/// 2026-10-07 and chose the column. Nine pages filled the top row, and the
/// icons make a page easier to spot than a word in a line of words.
struct SettingsColumn: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is typed in the search field (card Settings 3).
    @Binding var query: String
    /// The last reveal that was scrolled to (`land`). Held by the window,
    /// which outlives this column: a visit to the calls takes it away, and
    /// coming back must not scroll to an old link again.
    @Binding var landedSerial: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SettingsSearchResults(query: query) { query = "" }
                } else {
                    page
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: model.revealRequest) { await land(model.revealRequest, proxy: proxy) }
        }
    }

    @ViewBuilder private var page: some View {
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
        case .license: PlansPane()
        // The screen guide's two panes, which are gone; never in the column.
        case .guide, .privacy: EmptyView()
        // `resolved` never returns these; they are listed so the switch
        // stays exhaustive if a case is ever un-folded.
        case .widgets, .policy, .tray, .about: EmptyView()
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

/// What is shown while something is typed in the search field: matching
/// settings, best first, each with the page it is on. Choosing one opens that
/// page on that row.
struct SettingsSearchResults: View {
    let query: String
    var onChoose: () -> Void
    @Environment(SettingsModel.self) private var model

    var body: some View {
        let results = SettingsAnchor.search(query)
        ScrollView {
            VStack(spacing: SettingsLook.rowSpacing) {
                if results.isEmpty {
                    Text("Nothing called \u{201C}\(query)\u{201D}")
                        .font(Theme.chrome(12))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 40)
                } else {
                    ForEach(results) { anchor in
                        Button {
                            model.reveal(anchor)
                            onChoose()
                        } label: {
                            LookRow(anchor.title) {
                                Text(anchor.pane.title)
                                    .font(Theme.chrome(11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .clickable()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
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
        // A row: the sentence on the left, the way there on the right.
        HStack(spacing: 12) {
            // Optional, because the sentence is only worth saying once. Where
            // the row above already states the fact, repeating it here just
            // makes VoiceOver read it twice — the button's own label carries
            // the destination.
            if let text {
                Text(text)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // A real button, not a tappable phrase: the label says where it
            // goes, so VoiceOver reads the destination rather than "link".
            LookButton(label ?? String(localized: "Open \(pane.title)")) {
                if let anchor { model.reveal(anchor) } else { model.pane = pane }
            }
        }
        .lookRowBox()
    }
}

// MARK: - General

extension SoundLevel {
    /// What the level plays, in words.
    var explanation: String {
        switch self {
        case .off:
            String(localized: "Airlock makes no sound. The notch still opens when a request needs you.")
        case .important:
            String(localized: "A soft call when a request needs you, and a chime when an agent finishes. As loud as your Mac's alert sounds.")
        case .all:
            String(localized: "Also a light tap when you approve a request. As loud as your Mac's alert sounds.")
        }
    }
}

private struct GeneralPane: View {
    @Environment(SettingsModel.self) private var model
    @AppStorage(Ticks.defaultsKey) private var trackpadTicks = true
    @AppStorage(Sounds.levelKey) private var soundLevel: String?
    @State private var moreOptions = false

    /// Rows that live behind "More options": a link to one opens them first.
    static let anchorsInMoreOptions: Set<SettingsAnchor> = [.diagnostics]

    /// What the chosen level plays, in words.
    private var soundsExplanation: String {
        Sounds.binding($soundLevel).wrappedValue.explanation
    }

    private var soundsName: String {
        switch Sounds.binding($soundLevel).wrappedValue {
        case .off: String(localized: "Off")
        case .important: String(localized: "Only important")
        case .all: String(localized: "All")
        }
    }

    var body: some View {
        @Bindable var model = model
        LookPage(String(localized: "General"), subtitle: String(localized: "Startup, sounds, updates and diagnostics."),
                 moreOptions: $moreOptions, anchorsInMoreOptions: Self.anchorsInMoreOptions) {
            LookToggleRow("Launch at login",
                          subtitle: model.isBundled ? nil : String(localized: "Only works in the installed Airlock app"),
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .settingsAnchor(.launchAtLogin)
                .disabled(!model.isBundled)
            if let note = model.launchAtLoginNote {
                LaunchAtLoginProblem(note: note)
            }
            LanguageRow()

            NotchScreenSection(followsMainDisplay: $model.followsMainDisplay,
                               showsOnExternalWhenClosed: $model.showsOnExternalWhenClosed,
                               canSeeFullScreen: TypeService.isTrusted,
                               hidesWhenIdle: NotchScreen.target?.standInCutout != nil
                                   ? $model.hidesIdleStandIn : nil)

            LookRow("Sounds") {
                LookMenu(soundsName) {
                    Picker("Sounds", selection: Sounds.binding($soundLevel)) {
                        Text("Off").tag(SoundLevel.off)
                        Text("Only important").tag(SoundLevel.important)
                        Text("All").tag(SoundLevel.all)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .settingsAnchor(.sounds)
            LookToggleRow("Trackpad feedback", subtitle: String(localized: "A light tap under your finger for things you do"),
                          isOn: $trackpadTicks)

            // Version and updates. What was the About pane, where people were
            // already going to look for it.
            AboutRows()
            if CrashReporter.shared.isAvailable {
                CrashReportsSection(isOn: Binding(get: { CrashReporter.shared.isEnabled },
                                                  set: { CrashReporter.shared.isEnabled = $0 }))
            }
            if UsageCounts.shared.isAvailable {
                UsageCountsSection(isOn: Binding(get: { UsageCounts.shared.isEnabled },
                                                 set: { UsageCounts.shared.choose($0, from: .settings) }))
            }
        } more: {
            LookGroupLabel("Screen")
            LookNote(NotchScreenSection.explanation(followsMainDisplay: model.followsMainDisplay))
            LookGroupLabel("Sound and touch")
            LookNote(soundsExplanation)
            LookNote("Trackpad feedback is a light tap when you approve or deny a request, switch tabs, drop a file on the shelf, or scroll to the end of a list. Only things you do, never things that happen on their own. Mac trackpads only.")
            // Updates, crash reports, health, and the diagnostics paste
            // under the advanced switch.
            AboutDetails()
            AdvancedSwitch()
        }
    }
}

/// "Which screen is the notch on?" — the placement switches, and the two
/// cases where the notch cannot do what the explanation promises.
///
/// Values in rather than models read, so the state gallery draws these rows
/// as they ship (I21, I23). It changes no placement; it only says what the
/// placement rules already do.
struct NotchScreenSection: View {
    @Binding var followsMainDisplay: Bool
    @Binding var showsOnExternalWhenClosed: Bool
    /// Whether Accessibility is granted — full screen is read through it.
    var canSeeFullScreen: Bool
    /// "Only show it when something's happening". Nil where the island sits
    /// over a real notch, which is black hardware either way, so the row is
    /// not drawn there.
    var hidesWhenIdle: Binding<Bool>? = nil

    /// Without Accessibility, `FullScreenFront` cannot see a full-screen
    /// window, so the notch stays over it — and nothing said why.
    static let fullScreenNeedsAccessibility =
        String(localized: "Without the Accessibility permission the notch can't tell when an app is full screen, so it stays on top of it.")
    /// Lid closed, this switch off: there is no screen left to draw on, and
    /// until this sentence nothing said so before it happened.
    static let lidClosedHidesTheNotch =
        String(localized: "With this off, the notch has nowhere to show while the lid is closed, so nothing on screen will tell you when something needs you.")

    /// The long version, behind "More options" on General.
    static func explanation(followsMainDisplay: Bool) -> String {
        followsMainDisplay
            ? String(localized: "The notch goes wherever your main display is (the one set as main in System Settings › Displays). On a monitor it sits in the middle of the menu bar and works the same. In full screen it hides with the menu bar and comes back when you move the pointer to the top. It still appears on its own when an agent needs you.")
            : String(localized: "The notch stays on your MacBook. With the lid closed, it can sit in the middle of the menu bar on your main display instead, and works the same. In full screen it hides with the menu bar and comes back when you move the pointer to the top. It still appears on its own when an agent needs you.")
    }

    var body: some View {
        LookToggleRow("Show on the main display",
                      subtitle: followsMainDisplay ? String(localized: "Follows the display set as main") : String(localized: "Stays on your MacBook"),
                      isOn: $followsMainDisplay)
            .settingsAnchor(.displays)
        if !followsMainDisplay {
            LookToggleRow("Show on an external display when the lid is closed",
                          isOn: $showsOnExternalWhenClosed)
            if !showsOnExternalWhenClosed {
                ProblemCard(sentence: Self.lidClosedHidesTheNotch)
            }
        }
        if let hidesWhenIdle {
            LookToggleRow("Only show the notch when something's happening",
                          subtitle: hidesWhenIdle.wrappedValue
                              ? String(localized: "Hidden until you dictate, a call starts, an agent needs you or you move the pointer to the top")
                              : String(localized: "Always in the middle of the menu bar"),
                          isOn: hidesWhenIdle)
        }
        if !canSeeFullScreen {
            ProblemCard(sentence: Self.fullScreenNeedsAccessibility, button: String(localized: "Turn it on"),
                        action: { TypeService.openAccessibilitySettings() })
        }
    }
}

// MARK: - Appearance

/// How the notch looks, and what it shows — one pane, because they are one
/// question. See `SettingsPane` for why the two were merged.
///
/// The picture first, then how it looks, what sits beside the camera, and
/// what shows when it is open. Every paragraph is behind "More options".
private struct NotchPane: View {
    @Environment(\.islandPreview) private var islandPreview
    @Environment(SystemControlsModel.self) private var controls
    @State private var moreOptions = false

    var body: some View {
        LookPage(String(localized: "The notch"), subtitle: String(localized: "What it shows, and how it looks."),
                 learnMore: SettingsPane.appearance.learnMore,
                 moreOptions: $moreOptions) {
            // The island as it is now, redrawn as anything below changes
            // (card Settings 2).
            if let islandPreview {
                islandPreview()
                    .lookRowBox()
                    .padding(.bottom, 4)
            }
            NotchLookRows()
            WidgetRows()
            LookGroupLabel("Keep awake")
            KeepAwakeSection(controls: controls)
            LookGroupLabel("Window layouts")
            WindowLayoutsSection(layouts: .shared)
        } more: {
            NotchLookNotes()
            WidgetNotes()
            AdvancedSwitch()
        }
    }
}

/// Background, width, text size, what sits beside the camera, and Claude
/// usage on the Agents tab.
private struct NotchLookRows: View {
    @Environment(NotchAppearanceModel.self) private var appearance
    /// Whether the battery is in the gutter at all is the Widgets toggle, and
    /// both the demand figure and the percentage switch depend on it.
    @Environment(BatteryWidgetModel.self) private var battery
    /// Same again for the Agents tab, which the demand counts, and for usage:
    /// the rate-limit figures go with the agent surfaces.
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(UsageConnectionModel.self) private var usage
    /// For the link down to the widget switches, which are on this same page.
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var appearance = appearance
        LookRow("Background") {
            LookMenu(appearance.surface.label) {
                Picker("Background", selection: $appearance.surface) {
                    ForEach(NotchSurface.allCases) { surface in
                        Text(surface.label).tag(surface)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.surface)

        // The screen's range, not the product's: half the screen is the whole
        // window, the island drawn around the panel has to fit in it, and
        // points past it are clipped by the window edge rather than scrolled.
        // Relative to the default, not in points: "640pt" asked people to
        // know what a point is (X9).
        LookRow("Width") {
            LookSlider(value: $appearance.panelWidth, range: appearance.widthRange, step: 10,
                       label: String(localized: "\(Int((appearance.panelWidth / NotchAppearanceModel.defaultPanelWidth * 100).rounded()))%"))
        }
        .settingsAnchor(.panelWidth)
        // Width is not a free choice: the gutters flank the camera, and
        // content wider than its gutter is drawn behind the housing. Saying
        // so live beats letting it be discovered by eye.
        if let advice = appearance.widthAdvice(batteryVisible: battery.isEnabled,
                                               agentsTabVisible: AgentsWidget.showsTabAtRest(agents)) {
            ProblemCard(sentence: advice)
        }

        LookRow("Text size") {
            LookSlider(value: $appearance.textScale, range: NotchAppearanceModel.textScaleRange, step: 0.1,
                       label: String(localized: "\(Int(appearance.textScale * 100))%"))
        }
        .settingsAnchor(.textSize)
        if appearance.textScale > 1.2 {
            // Honest rather than silent: at the top of the range a narrow
            // panel runs out of width before it runs out of height, and the
            // fix is the slider directly above.
            LookNote("At this size a wider notch helps — long lines are cut short before they wrap.")
        }

        LookGroupLabel("Beside the camera")
        LookToggleRow("Battery percentage", isOn: $appearance.showsBatteryPercentage)
            .settingsAnchor(.batteryPercentage)
            .disabled(!battery.isEnabled)

        // Its own group now that the figures are not beside the camera: they
        // are one line at the top of the Agents tab, over the sessions.
        LookGroupLabel("Agents tab")
        LookToggleRow("Claude usage limits", subtitle: String(localized: "Your 5-hour and weekly limits, at the top of the Agents tab"),
                      isOn: $appearance.showsClaudeUsage)
            .settingsAnchor(.usageLimits)
            .disabled(!agents.isEnabled)
            // The switch is not only a display choice: with it on, Airlock
            // keeps itself connected to where the figures come from, and with
            // it off it disconnects rather than leaving a reader nobody reads.
            // See `UsageConnection`.
            .onChange(of: appearance.showsClaudeUsage) { _, on in
                usage.sync(wantsUsage: on)
            }
        if appearance.showsClaudeUsage, agents.isEnabled { usageConnection }
        // Naming the switch that is actually in the way, rather than leaving
        // a dead control to be poked at. The switches are further down this
        // same page, so the way there scrolls to them rather than "opening"
        // the page you are already on (X11).
        if let off = disabledNote {
            LookRow(off) {
                LookButton("Show the switches") { model.reveal(SettingsAnchor.widgets) }
            }
        }
    }

    /// Whether the figures can reach the Agents tab at all, said plainly.
    ///
    /// A switch that is on for something that cannot work is what this pane was
    /// quietly offering: the figures arrive through Claude's status line,
    /// Claude keeps only one, and another tool taking it leaves the switch on
    /// and the line frozen for good. So the state is on screen, with the one
    /// button that fixes it.
    @ViewBuilder
    private var usageConnection: some View {
        Group {
            switch usage.state {
            case .connected:
                LookNote("Connected. The figures come from a Claude session in a terminal; the desktop app never reports them.")
            case .replaced:
                ProblemCard(sentence: String(localized: "Not connected, so these figures can't update. Something else is using the line at the bottom of a Claude session. Connecting puts Airlock back without changing what you see there."),
                            button: String(localized: "Connect"), action: { usage.connect() })
            case .hooksMissing:
                PaneReference(String(localized: "Connect Claude Code first. Claude usage comes from it."), to: .agents)
            }
        }
        // Reading it touches the settings file, so it happens when the pane
        // appears rather than on every redraw — and it has to happen at all,
        // because the status line can change while this window is open.
        .onAppear { usage.refresh() }
        if let failure = usage.failure {
            ProblemCard(sentence: failure, tone: .stopped)
        }
    }

    private var disabledNote: String? {
        switch (agents.isEnabled, battery.isEnabled) {
        case (true, true): return nil
        case (false, true): return String(localized: "AI agents are off below, so Claude usage isn't shown")
        case (true, false): return String(localized: "The battery is off below, so it isn't shown")
        case (false, false): return String(localized: "AI agents and the battery are both off below")
        }
    }
}

/// The look's explanations, behind "More options".
private struct NotchLookNotes: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(NotchAppearanceModel.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        LookGroupLabel("Look")
        LookNote(surfaceNote)
        LookNote(gutterSummary)
        LookNote("Text size makes the notch's text up to 140% bigger. The strip beside the camera keeps its size — text that grew there would be cut off rather than wrap — and the top bar grows only part way, because it has to stay clear of the camera.")
        LookRow("Width and text size", subtitle: String(localized: "Back to how they came")) {
            HStack(spacing: 6) {
                LookButton("Reset width") { appearance.panelWidth = NotchAppearanceModel.defaultPanelWidth }
                LookButton("Reset text size") { appearance.textScale = 1 }
            }
        }
        LookNote("The battery sits to the right of the camera, beside the Agents tab and the gear. Turning it off frees room there, which is the other way to stop them running behind the camera.")

        // A slider measured in points, for the space around a camera —
        // nobody's first question, and a stranger reading it learns that
        // this app expects them to know what a point is.
        if advanced {
            LookGroupLabel("Camera")
            // "Reserved centre" named the mechanism; this names the thing
            // being set: how much room the camera housing is given.
            LookRow("Clear space around the camera") {
                LookSlider(value: $appearance.centreTightening, range: 0...40, step: 2,
                           label: "−\(Int(appearance.centreTightening))")
            }
            LookNote("How much narrower than the camera's measured cutout to keep clear. Anything above zero is space the camera actually covers, so whatever is placed there disappears. Leave it at zero unless you need a little more room beside the camera.")
        }
    }

    private var surfaceNote: String {
        switch appearance.surface {
        case .black:
            return String(localized: "Solid black, so the notch reads as one piece with the camera housing — which is black whatever you do.")
        case .darkGlass:
            return String(localized: "Blurs the desktop behind the notch using Liquid Glass. Only visible over a colourful desktop; against a dark wallpaper it looks much like black.")
        case .lightGlass:
            return String(localized: "Blurs the desktop behind the notch using Liquid Glass. The camera area itself is always black, so a light notch shows a black strip where it meets it when closed.")
        }
    }

    /// In words, not points (X9): what the width buys, which is room either
    /// side of the camera for the top bar.
    private var gutterSummary: String {
        guard appearance.centreTightening > 0 else {
            return String(localized: "A wider notch leaves more room either side of the camera for the tabs and the battery.")
        }
        return String(localized: "A wider notch leaves more room either side of the camera for the tabs and the battery. Some of that room is the clear space set under Camera below.")
    }
}

// MARK: - Widgets

/// One widget: whether it shows, and where.
///
/// The column menu writes the same `widget.column` the panel's arrange-mode
/// drag writes — deliberately, so the two are editors of one setting rather
/// than two competing sources of layout.
private struct WidgetRow: View {
    let title: LocalizedStringKey
    var subtitle: String?
    let id: String
    @Binding var isOn: Bool
    /// UserDefaults is invisible to `@Observable`, so the menu needs a nudge
    /// to re-read after it writes.
    @State private var revision = 0

    init(_ title: LocalizedStringKey, subtitle: String? = nil, id: String, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.id = id
        self._isOn = isOn
    }

    private var column: Binding<WidgetColumn> {
        Binding(get: { _ = revision; return WidgetArrangement.column(for: id) ?? .full },
                set: { WidgetArrangement.setColumn($0, for: id); revision += 1 })
    }

    private static func name(_ column: WidgetColumn) -> String {
        switch column {
        case .leading: String(localized: "Leading")
        case .trailing: String(localized: "Trailing")
        case .full: String(localized: "Full width")
        }
    }

    var body: some View {
        LookRow(title, subtitle: subtitle) {
            HStack(spacing: 10) {
                LookMenu(Self.name(column.wrappedValue)) {
                    Picker(title, selection: column) {
                        Text("Leading").tag(WidgetColumn.leading)
                        Text("Trailing").tag(WidgetColumn.trailing)
                        Text("Full width").tag(WidgetColumn.full)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                // A column for something that is not drawn is a choice with no
                // effect, so it follows the switch.
                .disabled(!isOn)

                Toggle(title, isOn: Binding(get: { isOn }, set: {
                    isOn = $0
                    UsageCounts.shared.record(.widgetSwitched(id, on: $0))
                }))
                    .toggleStyle(LookSwitchStyle())
                    .labelsHidden()
            }
        }
    }
}

private struct WidgetRows: View {
    @Environment(MediaWidgetModel.self) private var media
    @Environment(SoundWidgetModel.self) private var sound
    @Environment(AppVolumeModel.self) private var appVolume
    @Environment(CalendarWidgetModel.self) private var calendar
    @Environment(BatteryWidgetModel.self) private var battery
    @Environment(SystemStatsWidgetModel.self) private var system
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(RepositoryWidgetModel.self) private var repository
    @Environment(TrayModel.self) private var tray
    @State private var choosingCalendars = false

    var body: some View {
        // Switch AND column on one row. They are the same decision about the
        // same widget — "show this, there" — and the column menu writes
        // `widget.column`, which is exactly what arrange mode's drag writes.
        LookGroupLabel("When it's open")
        WidgetRow("Media", subtitle: String(localized: "Spotify and Apple Music"), id: "media",
                  isOn: Binding(get: { media.isEnabled }, set: { media.isEnabled = $0 }))
            .settingsAnchor(.widgets)
        WidgetRow("Sound", subtitle: String(localized: "Output and per-app volume"), id: "sound",
                  isOn: Binding(get: { sound.isEnabled }, set: { sound.isEnabled = $0 }))
        WidgetRow("Calendar", id: "calendar",
                  isOn: Binding(get: { calendar.isEnabled }, set: { calendar.isEnabled = $0 }))
        WidgetRow("System", subtitle: String(localized: "CPU, GPU and memory"), id: "system",
                  isOn: Binding(get: { system.isEnabled }, set: { system.isEnabled = $0 }))
        WidgetRow("Repository status", subtitle: String(localized: "Branch and changes, on the Agents tab"), id: "repository",
                  isOn: Binding(get: { repository.isEnabled }, set: { repository.isEnabled = $0 }))
        // No column: it is gutter chrome, drawn beside the housing on every
        // tab, so there is no slot to place it in.
        LookToggleRow("Battery", isOn: Binding(get: { battery.isEnabled }, set: {
            battery.isEnabled = $0
            UsageCounts.shared.record(.widgetSwitched("battery", on: $0))
        }))

        LookToggleRow("Wave follows the audio", subtitle: String(localized: "The music bars move with the real sound"),
                      isOn: Binding(get: { media.reactiveWave }, set: { media.reactiveWave = $0 }))
            .settingsAnchor(.reactiveWave)
            .disabled(!media.isEnabled)
        if let status = media.tapStatus {
            WaveTapStatusLine(status: status, isProblem: media.tapStatusIsProblem,
                              needsPermission: media.tapStatusNeedsPermission)
        }

        LookToggleRow("Per-app volume", subtitle: String(localized: "A level and a mute for each app"),
                      isOn: Binding(get: { appVolume.isEnabled }, set: { appVolume.isEnabled = $0 }))
            .settingsAnchor(.perAppVolume)
        // Deliberately NOT disabled by the Sound switch above, unlike the
        // reactive wave. Hiding the card hides the only mixer, so a disabled
        // switch would leave the taps running with no way to stop them; this
        // one has to stay reachable to be revocable.
        if !sound.isEnabled, appVolume.isEnabled {
            ProblemCard(sentence: String(localized: "Sound is switched off above, so the levels still apply but the mixer isn't in the notch."))
        }

        // Reads the SURFACE, not the stored flag. While the answer is still
        // derived and no hooks exist, the Agents tab is on screen asking to be
        // set up (`AgentsWidget.isUnconfigured`) — and a switch reading "off"
        // beside a visible tab is one the user cannot use to dismiss it,
        // because switching an off switch off is not a gesture. Flipping it
        // here writes `.chosen(false)`, which is the explicit no that hides it.
        LookToggleRow("AI agents", subtitle: String(localized: "Claude Code and Codex in the notch"),
                      isOn: Binding(get: { agents.isEnabled || agents.basis == .noHooksInstalled },
                                    set: {
                                        agents.choose($0)
                                        UsageCounts.shared.record(.widgetSwitched("agents", on: $0))
                                    }))
            .settingsAnchor(.agentsSwitch)

        calendarsRow

        // The shelf is a widget; it does not need a page of its own.
        LookRow("Shelf", subtitle: tray.items.count == 1 ? String(localized: "1 item") : String(localized: "\(tray.items.count) items")) {
            HStack(spacing: 6) {
                LookButton("Open folder") { tray.openFolder() }
                LookButton("Clear") { tray.clear() }
                    .disabled(tray.items.isEmpty)
            }
        }
        .settingsAnchor(.shelf)
        .sheet(isPresented: $choosingCalendars) {
            CalendarPickerSheet(calendar: calendar) { choosingCalendars = false }
        }
    }

    // A row and a sheet, not seven toggles inline. Somebody with seven
    // calendars was reading a list as long as every other setting on the
    // pane put together, for a choice they make once — so the page states
    // the answer and the sheet holds the switches.
    @ViewBuilder private var calendarsRow: some View {
        if !calendar.isEnabled {
            // Picking calendars for a widget that isn't shown is a control
            // with nothing behind it.
            LookRow("Calendars", subtitle: String(localized: "Turn the calendar on above to choose"))
                .opacity(0.45)
                .settingsAnchor(.calendars)
        } else if calendar.authStatus == .fullAccess {
            if calendar.allCalendars.isEmpty {
                LookRow("Calendars") { LookValue("None found") }
                    .settingsAnchor(.calendars)
            } else {
                LookRow("Calendars",
                        subtitle: calendar.selection.summary(amongst: calendar.allCalendars.map(\.id))) {
                    LookButton("Choose…") { choosingCalendars = true }
                }
                .settingsAnchor(.calendars)
            }
        } else {
            LookRow("Calendars", subtitle: String(localized: "Airlock needs your permission to read them")) {
                LookButton("Allow Calendar", prominent: true) { Task { await calendar.requestAccess() } }
            }
            .settingsAnchor(.calendars)
            if let note = calendar.accessNote {
                LookNote(note)
            }
        }
    }
}

/// The widgets' explanations, behind "More options".
private struct WidgetNotes: View {
    @Environment(MediaWidgetModel.self) private var media
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(TrayModel.self) private var tray

    var body: some View {
        LookGroupLabel("Widgets")
        LookNote("Repository status shows the branch and uncommitted changes for whatever checkout each agent session is working in — so it lives on the Agents tab, and appears only when a session is running in a git repository.")
        LookNote(media.isEnabled
                 ? "The music bars normally run their own animation. With Wave follows the audio on, they follow the actual audio coming out of Spotify or Music — which means asking macOS for permission to hear the music the first time something plays, and listening while it does. Nothing is recorded, stored or sent anywhere; the only thing computed is how tall to draw five bars."
                 : "Turn media on to make the music bars follow the audio.")
        LookNote("The sound card switches the output device and moves the system level — the things macOS hides behind an Option-click on the menu bar. Per-app volume is the mixer it never shipped: a level and a mute for each app making sound, kept per app and remembered.")
        LookNote("Per-app volume is off by default, because it is the one thing here that takes over the audio path: an app you turn down has its sound passed through Airlock, made quieter and played back, which asks macOS for permission to hear system audio the first time. Nothing is recorded, stored or sent anywhere. Leave it off and Airlock never touches the sound.")

        LookGroupLabel("AI agents")
        LookNote(agents.explanation)
        LookNote("Everything for coding agents: the Agents tab with Claude usage and its quick-prompt bar, and the agent icons beside the notch. Everything else — clipboard, Shelf, dictation, calendar, media — works the same either way.")

        LookGroupLabel("Shelf")
        LookRow("Kept in") {
            LookValue(tray.directory.path, monospaced: true)
                .textSelection(.enabled)
        }
        LookNote("Clear moves everything to the Trash, so it is recoverable from there. Dropped files are moved in, so a file leaves the folder you dragged it out of — hold Option while dropping to leave the original where it is. A format or action in the drop box never moves anything: it leaves the original alone and puts a new file here. The workspace beside it is where the notch opens a terminal.")
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

// MARK: - About

/// Version and updates — rows on General.
///
/// It was its own sidebar row, which put the two things people actually come
/// looking for (is there an update, and how do I file a bug) one click further
/// away than "Startup". A version number is a line in General, not a
/// destination.
private struct AboutRows: View {
    @Environment(SettingsModel.self) private var model
    /// `lastCheck` and `canCheck` are stored on the model and kept current by
    /// KVO on Sparkle's own properties, so this page redraws when the check
    /// finishes rather than when the app next becomes active. It has to: the
    /// check and its "You're up to date" sheet are in-process, so the app never
    /// resigns active and a re-read on the way back never happens.
    @Environment(UpdaterModel.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        LookRow("Version") { LookValue(model.versionLabel) }
        // The whole group, not just the button. Packaging leaves the updater
        // out entirely when there is no appcast URL or signing key, and
        // `swift run` has nothing to update either — rows offering to check
        // are worse than none when nothing can come back.
        if updater.isAvailable {
            UpdatesSection(checksAutomatically: $updater.checksAutomatically,
                           lastCheck: updater.lastCheck,
                           canCheck: updater.canCheck,
                           statusLine: updater.statusLine,
                           onCheck: { updater.checkForUpdates() })
        }
    }
}

/// Health and the diagnostics paste — behind "More options" on General.
private struct AboutDetails: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(SettingsModel.self) private var model
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
        if updater.isAvailable {
            LookGroupLabel("Updates")
            ForEach(UpdatesSection.notes, id: \.self) { LookNote($0) }
        }
        // In the order of the rows above: the switch sits under Updates.
        if CrashReporter.shared.isAvailable {
            LookGroupLabel("Crash reports")
            ForEach(CrashReportsSection.notes, id: \.self) { LookNote($0) }
        }
        if UsageCounts.shared.isAvailable {
            LookGroupLabel("Usage counts")
            ForEach(UsageCountsSection.notes, id: \.self) { LookNote($0) }
        }

        // Shown before it is copied, not described afterwards. A button
        // that puts an unseen block of text about your machine on the
        // clipboard is a button people are right to distrust — and this one
        // is aimed at a public issue tracker, where the way to find out what
        // was in it is to have already posted it.
        // ABOVE the paste. 7c is the better artefact for support and 7d is
        // the better surface for the user, because it names its own next
        // step — so the readable one leads and the copyable one follows.
        LookGroupLabel("Health")
        DiagnosticsHealthView(
            health: health,
            summary: advanced ? healthSummary : nil,
            onCopy: { copyDiagnostics() },
            onOpen: { remedy in
                switch remedy {
                case .agentsSettings: model.pane = .agents
                case .permissionsSettings: model.pane = .permissions
                case .updateSettings: model.reveal(.updates)
                }
            })
            .lookRowBox()
            .settingsAnchor(.diagnostics)
            // Re-read on the way in. Permissions and hooks change outside this
            // process, so a report built once and cached for the life of the
            // window would eventually describe a machine that no longer exists.
            .onAppear { rebuildDiagnostics() }

        // The paste itself is for a bug report, and printing it on the page
        // everybody lands on made the app look like a debugger. The Health
        // list above stays: it says what is wrong and offers the fix, which
        // is the half a customer can act on.
        if advanced {
            LookGroupLabel("Diagnostics")
            // Support's question, not a customer's: under the advanced
            // switch with the diagnostics paste, rather than a line of
            // reverse-DNS on the page everybody lands on.
            if model.isBundled, let id = Bundle.main.bundleIdentifier {
                LookRow("Bundle ID") { LookValue(id, monospaced: true) }
            }
            LookNote("Everything a bug report needs, and nothing else: no licence key, no file paths, nothing about what you are working on or what your agents are doing. This is exactly what gets copied.")
            Text(diagnostics)
                .font(Theme.chrome(11).monospaced())
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lookRowBox()
                .accessibilityLabel("Diagnostics, as they will be copied")
            HStack(spacing: 10) {
                LookButton("Copy diagnostics") { copyDiagnostics() }
                if copied {
                    LookStatus(ok: true, text: String(localized: "Copied"))
                }
            }
            .padding(.horizontal, 12)
        }
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
        let notch = report.hasNotch ? String(localized: "notch yes") : String(localized: "notch no")
        let displays = report.displayCount == 1
            ? String(localized: "1 display")
            : String(localized: "\(report.displayCount) displays")
        return "\(report.hardware) · \(notch) · \(displays)"
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
        AirlockCopy.put(diagnostics)
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
    /// Optional so the state gallery can draw the page without it.
    @Environment(LicenseModel.self) private var license: LicenseModel?
    @State private var moreOptions: Bool

    init(moreOptions: Bool = false) {
        _moreOptions = State(initialValue: moreOptions)
    }

    var body: some View {
        LookPage(SettingsPane.agents.title,
                 subtitle: String(localized: "Coding agents, how their requests reach you, and what they may do without asking."),
                 learnMore: SettingsPane.agents.learnMore, moreOptions: $moreOptions, anchorsInMoreOptions: [.givingUp]) {
            agentRows
        } more: {
            agentNotes
            AdvancedSwitch()
        }
    }

    // Hooks, then how you hear about a prompt, then the rules. Install order,
    // not alphabetical: nothing below matters until a hook exists above.
    @ViewBuilder private var agentRows: some View {
        LookGroupLabel("Connected")
        ForEach(model.agents) { row in connectionRows(row) }
        if license?.entitlement.limits.oneAgentAtATime == true {
            // Under the agents it limits, tagged, rather than a surprise the
            // second agent meets in its terminal.
            LookRow("Answer every agent from the notch",
                    subtitle: String(localized: "On Free, the notch answers one coding agent at a time. Others ask in their own terminal.")) {
                PlanTagButton(.plus) { model.reveal(.plans) }
            }
        }

        answering

        // Rules live here rather than in a room of their own. They are what
        // an agent may do without stopping to ask, which is meaningless until
        // there is an agent — and a stranger who opened "Rules" first met a
        // YAML file and a precedence table.
        PolicyRows()
    }

    @ViewBuilder private func connectionRows(_ row: SettingsModel.AgentRow) -> some View {
        LookRow(row.name, subtitle: caption(for: row.kind)) {
            HStack(spacing: 10) {
                StatusBadge(status: row.status)
                actionButton(row)
            }
        }
        if case .conflict = row.status {
            // The same sentence the Agents tab draws (X25): Airlock never
            // edits lines it didn't write, so the way forward is the file —
            // the bright button on the row — then a fresh look from here.
            ProblemCard(icon: "exclamationmark.triangle",
                        sentence: AgentsConnection.blockedSentence(
                            .init(name: row.name, status: row.status, settingsPath: row.configPath)),
                        tone: .needs,
                        button: String(localized: "Check again"),
                        action: { model.refresh() })
        }
        if let error = row.actionError {
            ProblemCard(sentence: error, tone: .stopped)
        }
    }

    /// Everything about being interrupted, gathered.
    ///
    /// These sat in the Widgets pane, which is about what the panel SHOWS. How
    /// you find out a prompt arrived, how you answer it from the keyboard and
    /// how long it waits before handing itself back are all about being
    /// interrupted — the same subject as the hooks above them, and install
    /// order is the order somebody meets them in.
    @ViewBuilder private var answering: some View {
        LookGroupLabel("Answering")
        LookToggleRow("Answer with a shortcut", isOn: Binding(
            get: { agents.hotkeyEnabled }, set: { agents.hotkeyEnabled = $0 }))
            .settingsAnchor(.gateHotkey)
        // A recorder, not three chords somebody else picked. If all three were
        // taken on your Mac the gate simply had no reachable key — and this is
        // the one surface the app cannot afford to leave unreachable.
        HotkeyRecorder("Answers the waiting request",
                       binding: Binding(get: { agents.hotkey }, set: { agents.hotkey = $0 }),
                       conflict: { chord in
            HoldKeyChord.collision(chord: chord, holdKey: dictation.holdKey)
        })
        .disabled(!agents.hotkeyEnabled)
        if let error = agents.hotkeyError {
            ProblemCard(sentence: error)
        } else if agents.hotkey == .commandShiftA {
            // The same honesty the clipboard pane gives ⌘⇧C and Maccy: a
            // global hotkey outranks an app's own menu shortcut, so this
            // quietly takes one people may already use.
            LookNote("⇧⌘A is also Finder's Applications folder. A global shortcut wins, so Finder won't see it while Airlock is running — pick ⌃⌥⌘A above if you'd rather keep it.")
        }

        // The same setting as General's Sounds, seen from here: off is Off, on
        // is Only important unless All was already chosen.
        LookToggleRow("Play a sound", subtitle: String(localized: "When a request arrives"), isOn: Binding(
            get: { Sounds.binding($soundLevel).wrappedValue != .off },
            set: { on in
                let level = Sounds.binding($soundLevel)
                if !on { level.wrappedValue = .off } else if level.wrappedValue == .off { level.wrappedValue = .important }
            }))
            .settingsAnchor(.promptSound)
        LookRow("Sound") {
            HStack(spacing: 6) {
                LookMenu(agents.gateSoundName) {
                    Picker("Sound", selection: Binding(
                        get: { agents.gateSoundName }, set: { agents.gateSoundName = $0 })) {
                        ForEach(AgentsWidgetModel.gateSoundChoices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                // A sound picker you cannot hear is a list of words.
                LookButton("Play") { agents.playGateSound() }
            }
        }
        .disabled(Sounds.binding($soundLevel).wrappedValue == .off)

        // Card Agents 1. Here rather than beside the usage figures on The
        // notch page: those rows are about what the top bar shows, and this is
        // about being told something, the subject of this page.
        LookRow("Warn me near Claude's limit", subtitle: String(localized: "When the 5-hour or weekly limit gets this full")) {
            LookMenu(usageAlerts.level == 0 ? "Never" : "At \(usageAlerts.level)%") {
                Picker("Warn me", selection: Binding(get: { usageAlerts.level },
                                                     set: { usageAlerts.level = $0 })) {
                    ForEach(UsageAlert.levelChoices, id: \.self) { level in
                        Text(level == 0 ? "Never" : "At \(level)%").tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.usageWarning)
        LookToggleRow("Say when it resets", subtitle: String(localized: "After a warning, once that limit is back to zero"),
                      isOn: Binding(get: { usageAlerts.announcesReset },
                                    set: { usageAlerts.announcesReset = $0 }))
            .disabled(usageAlerts.level == 0)
    }

    @ViewBuilder private var agentNotes: some View {
        LookGroupLabel("Connected")
        LookNote("If Airlock isn't running, your agents carry on as before and ask you in the terminal.")
        // The file's path is for developers (X24): with Advanced on, or as
        // the conflict row's "Show the file".
        if advanced {
            ForEach(model.agents) { row in
                LookRow(row.name, subtitle: row.configPath) {
                    LookButton(AgentsEmptyState.showFile) { model.revealConfig(row) }
                }
            }
        }

        LookGroupLabel("Answering")
        LookNote("A request never takes the keyboard by itself — it arrives while you're typing somewhere else, and a keypress meant for your editor would answer something you hadn't read. Press the shortcut and the request becomes answerable; only then does it show its shortcuts.")
        LookNote("With nothing waiting it opens the Agents tab, and pressing it again closes it. It works even with AI agents switched off in Settings › \(SettingsPane.appearance.tabTitle), because a waiting request is shown either way.")
        LookNote("Without a sound, the notch opening is the signal, and that reaches you only if you're looking at the screen. A sound reaches you wherever you are; the spoken announcement reaches VoiceOver users. Settings › General › Sounds turns every Airlock sound on or off.")
        LookNote("Claude usage only updates while Claude Code is running in a terminal.")

        // Read-only here and edited in a file: a number you cannot change is
        // not a setting, it is a fact about an installation. `ask_timeout` is
        // read from the policy file but it is about being interrupted, not
        // about what runs, so it sits with answering.
        LookRow("Hand the question back after") {
            LookValue(model.policy.askTimeout > 0
                      ? "\(Int(model.policy.askTimeout)) seconds"
                      : "never — it waits")
        }
        .settingsAnchor(.givingUp)
        LookNote("An unanswered request goes back to the agent's terminal, which asks you there instead. Waiting never approves or denies anything.")

        PolicyDetails()
    }

    @ViewBuilder
    private func actionButton(_ row: SettingsModel.AgentRow) -> some View {
        switch row.status {
        case .installed:
            LookButton("Disconnect") { model.toggle(row) }
        case .notInstalled:
            LookButton("Connect", prominent: true) { model.toggle(row) }
        case .conflict:
            // The fix is an edit in that file, so the file is the first thing
            // to reach for; the card below has the fresh look after it.
            LookButton(AgentsEmptyState.showFile, prominent: true) { model.revealConfig(row) }
        }
    }

    private func caption(for kind: AgentKind) -> String? {
        switch kind {
        case .codex:
            return String(localized: "Shows what Codex is doing. Its requests are still answered in the terminal.")
        case .claudeCode:
            return String(localized: "Requests come to the notch: Approve, Deny or Always, plus your rules.")
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
                .foregroundStyle(suggestion.kind == .allow ? Theme.done : Theme.danger)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                // Plain language first, syntax second — the whole point is that
                // you should not have to think in rules to get one.
                Text(headline)
                    .font(Theme.chrome(13, .medium))
                    .foregroundStyle(Theme.textPrimary)
                // A picker only when there is a real choice. One literal
                // command with nothing safe to widen is not a decision.
                if suggestion.candidates.count > 1 {
                    // The chosen width, and a way to see the others. It was a
                    // pop-up menu, which shows one option at a time — and this
                    // is a decision ABOUT scope, so the three widths are worth
                    // reading side by side rather than one at a time.
                    HStack(spacing: 8) {
                        Text(choice)
                            .font(Theme.chrome(11.5).monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                        LookButton("How wide?") { choosingWidth = true }
                    }
                } else {
                    Text(suggestion.ruleText)
                        .font(Theme.chrome(11.5).monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                if let risk = suggestion.riskReason {
                    Label("Flagged as \(risk)", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.chrome(11.5))
                        .foregroundStyle(Theme.needs)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                LookButton(suggestion.kind == .allow ? "Always Allow" : "Always Deny", prominent: true) {
                    model.addPolicyRule(choice, kind: suggestion.kind)
                }
                LookButton("Dismiss") { model.dismiss(suggestion) }
            }
        }
        .lookRowBox()
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
        let count = suggestion.count
        switch (suggestion.kind == .allow, count == 1) {
        case (true, true): return String(localized: "You've approved this once — stop asking?")
        case (true, false): return String(localized: "You've approved this \(count) times — stop asking?")
        case (false, true): return String(localized: "You've refused this once — block it outright?")
        case (false, false): return String(localized: "You've refused this \(count) times — block it outright?")
        }
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
        let rule = suggestion.ruleText
        let count = suggestion.count
        switch (suggestion.kind == .allow, count == 1) {
        case (true, true): return String(localized: "You approved \(rule) once.")
        case (true, false): return String(localized: "You approved \(rule) \(count) times.")
        case (false, true): return String(localized: "You refused \(rule) once.")
        case (false, false): return String(localized: "You refused \(rule) \(count) times.")
        }
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
                    .font(Theme.chrome(11.5).monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(gate.outcome.label)
                    if let risk = gate.riskReason {
                        Text("· \(risk)")
                    }
                    Text("· \(gate.decidedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textTertiary)
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
        case .allowedOnce, .alwaysAllowed, .autoAllowed: return Theme.done
        case .denied, .autoDenied: return Theme.danger
        case .deferred: return Theme.textTertiary
        }
    }
}

private struct StatusBadge: View {
    let status: HookInstallStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var color: Color {
        switch status {
        case .installed: return Theme.done
        case .notInstalled: return Theme.textTertiary
        case .conflict: return Theme.needs
        }
    }

    private var label: String {
        switch status {
        case .installed: return String(localized: "Connected")
        case .notInstalled: return String(localized: "Not connected")
        case .conflict: return String(localized: "Needs a hand")
        }
    }
}

// MARK: - Policy

/// Rules, as rows of the Agents pane — see `SettingsPane` for why they no
/// longer have a pane of their own. What you decide is here; how it works,
/// the tester and the history are `PolicyDetails`, behind More options.
private struct PolicyRows: View {
    @Environment(SettingsModel.self) private var model
    @State private var draft = ""
    @State private var draftKind: PolicyRuleKind = .allow

    var body: some View {
        if !model.suggestions.isEmpty {
            LookGroupLabel("Suggestions")
            ForEach(model.suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion)
            }
        }

        LookGroupLabel("Rules")
        // ABOVE the lists it governs. A switch that decides which file every
        // control below writes to, drawn under those controls, is a switch
        // people read after acting.
        if model.policyScopeCandidates.isEmpty {
            // The normal state on a Monday morning, not an edge case: no agent
            // has run, so there is no project to name, and a menu of one is a
            // promise not being kept.
            LookRow("Rules for", subtitle: String(localized: "Projects appear here once an agent has run in one")) {
                LookValue(PolicyScope.everywhere.label)
            }
            .settingsAnchor(.rules)
        } else {
            LookRow("Rules for", subtitle: scopeSubtitle) {
                LookMenu(model.policyScope.label) {
                    Picker("Rules for", selection: Binding(
                        get: { model.policyScope },
                        set: { model.policyScope = $0 }
                    )) {
                        Text(PolicyScope.everywhere.label).tag(PolicyScope.everywhere)
                        ForEach(model.policyScopeCandidates, id: \.self) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .settingsAnchor(.rules)
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LookMenu(draftKind.label) {
                    Picker("Kind", selection: $draftKind) {
                        ForEach(PolicyRuleKind.allCases) { Text($0 == .allow ? String(localized: "Allow") : String(localized: "Deny")).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .fixedSize()

                TextField("Read, or Bash(git push)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)

                LookButton("Add", prominent: true, action: add)
                    // Refused while the file is broken. `PolicyDocument` never
                    // parses it, so the insert SUCCEEDS and reports "Added" for
                    // a rule landing in a file nothing reads — and it cannot
                    // see the broken line, so adding `Bash(git push)` beside a
                    // malformed `Bash(git push` leaves you with both and the
                    // file still broken.
                    .disabled(parsed == nil || model.scopedPolicy.parseFailed)
            }
            Text(draftHelp)
                .font(Theme.chrome(11))
                .foregroundStyle(draftIsInvalid ? Theme.needs : Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lookRowBox()

        // Deny FIRST. Deny is rule one, and with two files in play that
        // ordering is the safety story — a project deny is the thing that
        // beats an Everywhere allow.
        rules(.deny)
        rules(.allow)
    }

    /// The project's folder, because the segment title is only its last
    /// component. Nothing here writes a .gitignore: a shared project rule is
    /// often exactly what a team wants committed.
    private var scopeSubtitle: String? {
        guard case .project = model.policyScope else { return nil }
        return String(localized: "Kept inside the project, so git shows it as a new file")
    }

    // MARK: - Rule lists

    /// Headings say what the rules DO, not which list they are in.
    ///
    /// "Allow" and "Deny" are the file's vocabulary and belong in the rule text,
    /// where they are exact. As headings they made someone read a list of
    /// patterns and then work out the consequence; "Runs without asking" is the
    /// consequence, which is the thing being decided.
    @ViewBuilder
    private func rules(_ kind: PolicyRuleKind) -> some View {
        let items = model.scopedPolicy.rules(kind)
        LookGroupLabel(kind == .allow ? "Runs without asking" : "Never runs")
        switch model.scopedPolicy.state {
        case .unreadable:
            // No list at all, ever, beside a parse failure. An empty list next
            // to a warning reads as "this file has no rules", and the truth is
            // "this file is not being read".
            // The way out on the first of the two lists only: one button is
            // enough for one file.
            ProblemCard(sentence: String(localized: "Can't show the rules: this file has a mistake in it. Fix it in your editor, then press Reload."),
                        tone: .stopped,
                        button: kind == .deny ? String(localized: "Open in editor") : nil,
                        action: kind == .deny ? { model.openPolicyInEditor() } : nil)
        case .missing:
            LookNote(model.policyScope == .everywhere
                     ? "No rules yet."
                     : "No rules here yet — this project runs on the Everywhere rules.")
        case .empty:
            LookNote(emptyRulesCopy(kind))
        case .listing:
            if items.isEmpty {
                LookNote(emptyRulesCopy(kind))
            } else {
                // `id: \.self` is safe ONLY because each scope shows one file.
                // `PolicyRule` hashes over its text, and `Policy.merging`
                // concatenates without dedup — so a merged list containing
                // `Read` from both files would have two equal ids and SwiftUI
                // would drop one.
                ForEach(items, id: \.self) { rule in
                    ruleRow(rule, kind: kind)
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
                ? String(localized: "Nothing extra is auto-approved here — the Everywhere list still applies.")
                : String(localized: "Nothing extra is denied here — the Everywhere list still applies.")
        }
        return kind == .allow
            ? String(localized: "Nothing is auto-approved — every request asks.")
            : String(localized: "Nothing is auto-denied.")
    }

    private func ruleRow(_ rule: PolicyRule, kind: PolicyRuleKind) -> some View {
        let record = model.provenance[rule.canonicalText] ?? .unrecorded
        return HStack(spacing: 9) {
            Image(systemName: kind == .allow ? "checkmark.circle" : "nosign")
                .foregroundStyle(kind == .allow ? Theme.done : Theme.danger)
            // As written, not canonicalised: this should read back
            // exactly like the line in the file you would go and find.
            Text(rule.text)
                .font(Theme.chrome(12).monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            // What it has decided, and who put it there. Both come from the gate
            // log because the FILE cannot say — a rule you wrote and a rule an
            // Always click wrote are the same line of YAML.
            VStack(alignment: .trailing, spacing: 1) {
                Text(matchLabel(record))
                    .foregroundStyle(record.hasNeverMatched ? Theme.needs : Theme.textSecondary)
                Text(authorLabel(record))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.chrome(10.5))

            Button {
                model.removePolicyRule(rule, kind: kind)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .clickable()
            .help("Remove this rule")
        }
        .lookRowBox()
    }

    /// The number that makes a dead rule visible.
    private func matchLabel(_ record: RuleProvenance) -> String {
        if record.hasNeverMatched { return String(localized: "never matched") }
        return record.matches == 1
            ? String(localized: "1 match")
            : String(localized: "\(record.matches) matches")
    }

    /// "you, Tuesday" for a rule an Always click wrote; "from the template" for
    /// one that was in the file before anybody clicked anything.
    private func authorLabel(_ record: RuleProvenance) -> String {
        guard let authored = record.authoredAt else { return String(localized: "from the template") }
        let when = Self.authoredFormat.string(from: authored)
        return String(localized: "you, \(when)")
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
            return String(localized: "Not a rule yet. Type a tool's name, like Read, or a tool with what it acts on in brackets, like Bash(git status).")
        }
        if let parsed, parsed.pattern == nil {
            return String(localized: "\(parsed.tool) matches every use of that tool, whatever the arguments.")
        }
        if let parsed, let pattern = parsed.pattern {
            return parsed.tool == "Bash"
                ? String(localized: "Matches \(parsed.tool) when its command fits \(pattern). A * stands for anything.")
                : String(localized: "Matches \(parsed.tool) when its file fits \(pattern). A * stands for anything.")
        }
        return String(localized: "A tool's name covers every use of it. Add what it acts on in brackets to narrow it down: Bash(git status), Bash(npm run *), Edit(*/secrets/*). A * stands for anything.")
    }

    private func add() {
        guard let parsed else { return }
        model.addPolicyRule(parsed.canonicalText, kind: draftKind)
        draft = ""
    }
}

/// The rules' More options: how they combine, a tester, the history and the
/// file. All of it earns its place the day something behaves oddly, and none
/// of it belongs in front of somebody who has just installed the app.
private struct PolicyDetails: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(SettingsModel.self) private var model
    @State private var probeTool = "Bash"
    @State private var probeSubject = ""

    var body: some View {
        LookGroupLabel("Rules")
        LookNote("A rule is suggested after the second time you answer the same way. Commands Airlock always asks about, like rm -rf or sudo, are never suggested: they would still ask, so the rule would be a promise Airlock can't keep.")
        // Precedence as four lines, not a diagram. It is the one thing about
        // rules that can genuinely surprise somebody: a rule they wrote,
        // visibly matching, and the notch still asking. The floor is why.
        VStack(alignment: .leading, spacing: 8) {
            Text("Which rule wins")
                .font(Theme.chrome(13, .medium))
                .foregroundStyle(Theme.textPrimary)
            precedence(1, "Never runs", "auto-denied, and the agent is told which rule.")
            precedence(2, "Risky commands", "rm -rf, sudo, force push and the like always ask, whatever the other list says. Built in, not editable.")
            precedence(3, "Runs without asking", "auto-approved silently.")
            precedence(4, "Otherwise", "the notch asks you.")
        }
        .lookRowBox()
        LookNote("Each project can have its own rules, kept in the project's folder. They add to the Everywhere rules, and a project's Never runs always beats an Everywhere Runs without asking. The Always button in the notch writes to the project's rules when the agent was started in a folder.")

        if advanced {
            LookGroupLabel("Try a request")
            VStack(alignment: .leading, spacing: 8) {
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
            }
            .lookRowBox()
            LookNote("Uses the same check the notch uses for a real request, so this is the answer you would actually get.")

            LookGroupLabel("Recent requests (\(model.recentGates.count))")
            if model.recentGates.isEmpty {
                LookNote("Nothing yet. Every request your agents make — and everything your rules settle without asking — shows up here.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.recentGates.prefix(12)) { gate in
                        GateRow(gate: gate)
                    }
                }
                .lookRowBox()
                LookRow("Kept on this Mac only, the latest 500") {
                    LookButton("Clear history") { model.clearGateHistory() }
                }
            }
            LookNote("Match counts and \u{201c}added by\u{201d} come from the request history, which doesn't record which project a request came from — so they are totals across every project.")

            LookGroupLabel("Rules file")
            // Loud: a file that failed to parse contributes NO rules, so the
            // lists would read as "nothing configured" when the truth is
            // "nothing is working".
            ForEach(model.scopedPolicy.problems, id: \.self) { problem in
                // The clause that actually matters: a file that does not parse
                // is ignored ENTIRELY, so the denies written in it are not in
                // force either. Only the built-in risk floor still holds.
                ProblemCard(icon: "exclamationmark.triangle",
                            sentence: problem + " " + (model.policyScope == .everywhere
                                ? String(localized: "This file is being ignored entirely, so only Airlock's built-in checks are in effect: risky commands still ask.")
                                : String(localized: "This file is being ignored entirely, so this project is running on the Everywhere rules alone — including its Never runs list.")))
            }
            LookRow("File", subtitle: model.scopedPolicy.path) {
                HStack(spacing: 6) {
                    if model.scopedPolicy.exists {
                        LookButton("Open in editor") { model.openPolicyInEditor() }
                        LookButton("Show in Finder") { model.revealPolicy() }
                    } else {
                        LookButton("Create starter rules", prominent: true) { model.createStarterPolicy() }
                    }
                    LookButton("Reload") { model.refresh() }
                }
            }
            if let note = model.policyNote {
                LookNote(note)
            }
        }
    }

    // MARK: - Tester

    private var verdictRow: some View {
        let verdict = model.testPolicy(tool: probeTool, subject: probeSubject)
        return Label {
            Text(describe(verdict)).font(Theme.chrome(11.5))
        } icon: {
            Image(systemName: symbol(verdict))
        }
        .foregroundStyle(tint(verdict))
    }

    private func describe(_ verdict: PolicyVerdict) -> String {
        switch verdict {
        case .allow(let rule): return String(localized: "Auto-approved by \(rule)")
        case .deny(let rule): return String(localized: "Auto-denied by \(rule)")
        case .ask(let risk?): return String(localized: "Always asks — \(risk)")
        case .ask: return String(localized: "Asks you in the notch — no rule matches")
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
        case .allow: return Theme.done
        case .deny: return Theme.danger
        case .ask(let risk): return risk == nil ? Theme.textSecondary : Theme.needs
        }
    }

    private func precedence(_ step: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(step)")
                .font(Theme.chrome(11.5, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
