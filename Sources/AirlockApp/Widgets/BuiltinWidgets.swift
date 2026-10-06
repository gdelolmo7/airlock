import SwiftUI

/// Git status for the checkouts agents are working in.
///
/// On the agents tab, not home: it is meaningless without a session, since the
/// whole premise is that the working directory is already known. That also
/// makes it follow the agents toggle for free — someone who does not run agents
/// never sees a git row for a repo nobody is touching.
@MainActor
struct RepositoryWidget: NotchWidget {
    let repository: RepositoryWidgetModel

    var id: String { "repository" }
    var displayName: String { "Repository" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var tab: NotchTab { .agents }
    var isEnabled: Bool {
        get { repository.isEnabled }
        nonmutating set { repository.isEnabled = newValue }
    }

    func panelSection() -> AnyView? {
        guard isEnabled, !repository.repositories.isEmpty else { return nil }
        return AnyView(RepositorySectionView().environment(repository))
    }
}

/// The agents widget — the product's flagship, and the ONLY interrupt tier on
/// the island.
///
/// It used to be non-toggleable, on the grounds that the product is not
/// optional. That held while the app was only an agent driver; it stopped being
/// true once the notch grew a clipboard, a shelf, dictation and a calendar,
/// which people want without ever having run a coding agent. For them the tab
/// was a permanently empty room.
///
/// The switch does not make the flagship something an agent user has to go and
/// find: the default is derived from whether agent hooks are actually installed
/// (`AgentsPresence`), so it is already on for anyone who wired one up.
@MainActor
struct AgentsWidget: NotchWidget {
    let model: AppModel
    let agents: AgentsWidgetModel
    /// Whether the agent surface is paid up. The nine free widgets never ask.
    let isEntitled: () -> Bool
    /// Buying, not configuring. The blocked card's whole job is to sell, so it
    /// opens the purchase window rather than a preferences tree — "I already
    /// have a key" is a door inside that window.
    var onOpenSettings: () -> Void = {}

    var id: String { "agents" }
    var displayName: String { "AI agents" }
    var tier: WidgetTier { .interrupt }
    var isToggleable: Bool { true }
    var tab: NotchTab { .agents }
    var isEnabled: Bool {
        get { agents.isEnabled }
        // Through `choose`, never a plain store: this write is the user stating
        // a preference, and that has to outrank later hook installs.
        nonmutating set { agents.choose(newValue) }
    }
    /// A gate is an agent blocked on an answer, so it shows even switched off.
    var demandsAttention: Bool { model.attentionCount > 0 }

    /// Nobody has been asked and no agent config names us.
    ///
    /// The derived default sends `isEnabled` false here, which used to take the
    /// whole tab with it — so the app hid the only screen that explains how to
    /// install the hooks from the only person who needed it. It stays visible
    /// until the user says no, and `.chosen(false)` is that no.
    ///
    /// Deliberately NOT routed through `AgentsPresence.showsAgents`: the compact
    /// island's session glyphs and the Claude usage KPI keep following that, so
    /// a Mac with no agents gets a tab explaining itself rather than a gutter
    /// advertising a feature nobody asked for.
    ///
    /// With the guide on, the switch is Developer mode (card 3.02) and the
    /// first-run welcome asks the question this tab used to stand in for, so
    /// a Mac with no hooks keeps the tab off until somebody says yes.
    var isUnconfigured: Bool {
        agents.basis == .noHooksInstalled && !GuideSwitch.isOn
    }

    /// What the trial card names as locked, in the tab's own name — "The
    /// agent surface" was ours, never a word anyone sees on screen.
    static let lockedSurface = "The Agents tab"

    func panelSection() -> AnyView? {
        guard isVisible else { return nil }
        // Unentitled with nothing running gets the card; unentitled with a
        // session gets the SESSION. "Airlock still watches and still shows you
        // everything — it just stops answering for you" is only true if the
        // sessions are still drawn, and the gate is exactly the thing worth
        // seeing: the value being sold is answering it from here, so hiding it
        // hides the argument. `PermissionCardView` swaps its buttons for the
        // ask.
        guard isEntitled() || !model.sessions.isEmpty else {
            return AnyView(LicenseBlockedView(onSubscribe: onOpenSettings,
                                              surface: Self.lockedSurface))
        }
        return AnyView(AgentSessionsSectionView().environment(model).environment(agents))
    }
}

/// The system toggles, on Home beside the Sound card.
///
/// Leading, with Sound trailing (owner, 2026-10-01): both are "change the Mac
/// right now", so they sit side by side under the track that is playing. At
/// half width the six buttons wrap to two rows of three; given the full width
/// they are still one rail (`SystemControlsSectionView`). Toggleable like everything else: a rail
/// of switches somebody never presses is exactly the clutter the widget
/// registry exists to let them remove.
@MainActor
struct SystemControlsWidget: NotchWidget {
    let controls: SystemControlsModel

    var id: String { "systemControls" }
    var displayName: String { "System controls" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var column: WidgetColumn { .leading }
    var isEnabled: Bool {
        get { WidgetToggle(key: "widget.systemControls.enabled", defaultValue: true).value }
        nonmutating set {
            WidgetToggle(key: "widget.systemControls.enabled", defaultValue: true).value = newValue
        }
    }

    /// Nil with every button switched off in arrange mode, as well as with
    /// the widget off. A card with an empty rail drew an empty box AND, being
    /// a section, kept the shortcut map from taking the column; arrange mode
    /// lists the switched-off buttons itself, so nothing is lost by going.
    func panelSection() -> AnyView? {
        guard isEnabled, !controls.shown.isEmpty else { return nil }
        return AnyView(SystemControlsSectionView().environment(controls))
    }
}

/// What the notch is listening for, shown while its column has nothing else.
///
/// A fallback rather than an empty state, because the two are not the same
/// thing: an empty state apologises for having nothing, and this has something
/// — the live bindings, which stay true forever. `isFallback` is what keeps it
/// from competing with a playing track for the same slot.
@MainActor
struct KeyMapWidget: NotchWidget {
    let dictation: DictationModel
    let clipboard: ClipboardWidgetModel
    let agents: AgentsWidgetModel

    var id: String { "keymap" }
    /// Home, not Dashboard, and that is what keeps it a fallback in practice.
    /// On Dashboard (2026-10-01, briefly) it had nothing real beside it in a
    /// saved full-width column, so it drew a four-row cheat sheet over the top
    /// of the tab and the owner asked what it was. On Home the music and
    /// control cards are always there to yield to.
    var tab: NotchTab { .home }
    var displayName: String { "Shortcut map" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var column: WidgetColumn { .leading }
    var isFallback: Bool { true }
    var isEnabled: Bool {
        get { WidgetToggle(key: "widget.keymap.enabled", defaultValue: true).value }
        nonmutating set { WidgetToggle(key: "widget.keymap.enabled", defaultValue: true).value = newValue }
    }

    func panelSection() -> AnyView? {
        guard isEnabled else { return nil }
        return AnyView(KeyMapSectionView()
            .environment(dictation)
            .environment(clipboard)
            .environment(agents))
    }
}

@MainActor
struct MediaWidget: NotchWidget {
    let media: MediaWidgetModel

    var id: String { "media" }
    /// Full width, and FIRST. The banner is the tab's headline — cover art, a
    /// title at reading size and the transport all on one line — and it was
    /// sharing a column with the console, which squeezed it into a card too
    /// narrow to be any of those things.
    var column: WidgetColumn { .full }
    var displayName: String { "Media (Spotify & Apple Music)" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { media.isEnabled }
        nonmutating set { media.isEnabled = newValue }
    }

    func panelSection() -> AnyView? {
        // A quit player leaves the card DORMANT rather than removing it — see
        // `MediaWidgetModel.dormant`. Returning nil here was what made the tab
        // reflow the moment the music stopped, which reads as the panel
        // breaking rather than as Spotify closing.
        guard media.isEnabled,
              media.state != nil || media.refusedPlayer != nil || media.dormant != nil else { return nil }
        return AnyView(MediaSectionView().environment(media))
    }
}

/// Output device, output level, and a level per app that is making sound.
///
/// Its own widget rather than a tail on the media card, because the two answer
/// different questions and were only ever together by accident of where output
/// switching was first bolted on. The accident had a cost: everything here was
/// gated on Spotify or Music being detected, so a browser playing a video — the
/// case where you most want to turn one app down — could show nothing at all.
///
/// **On by default**, because output switching was already reachable and taking
/// it away would be a regression for anyone who used it. Per-app levels inside
/// it are a separate switch and default OFF; they are the part that takes over
/// the audio path.
@MainActor
struct SoundWidget: NotchWidget {
    let sound: SoundWidgetModel
    let output: AudioOutputModel
    let appVolume: AppVolumeModel

    var id: String { "sound" }
    /// On Home, trailing, beside the system controls (owner, 2026-10-01): the
    /// two cards you open the notch to change something. It spent one day on
    /// the Dashboard above This Mac. `WidgetArrangement.applyHomeSoundLayoutOnce`
    /// moves existing installs here.
    var tab: NotchTab { .home }
    var column: WidgetColumn { .trailing }
    var displayName: String { "Sound (output & per-app volume)" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { sound.isEnabled }
        nonmutating set { sound.isEnabled = newValue }
    }

    func panelSection() -> AnyView? {
        guard isEnabled else { return nil }
        // Nothing to switch and nothing to turn down is a card with a border and
        // no contents. `SoundSectionView` makes the same check; this one keeps
        // an empty view out of the stack's spacing.
        // `slots`, so a card holding nothing but idle apps still draws — the
        // whole point of holding their places is that the card does not
        // restructure the moment an app goes quiet.
        // A named device counts as something: an HDMI output alone, with no
        // software volume and nothing playing, used to take the card with it,
        // and then nothing said where the sound was going.
        guard output.hasRow || !appVolume.slots.shown.isEmpty || output.currentDeviceName != nil
        else { return nil }
        return AnyView(SoundSectionView())
    }
}

@MainActor
struct CalendarWidget: NotchWidget {
    let calendar: CalendarWidgetModel
    /// Settings at the calendar list, for when every calendar is unticked.
    var onChooseCalendars: () -> Void = {}

    var id: String { "calendar" }
    var tab: NotchTab { .dashboard }
    /// Leading, on its own — see `SoundWidget.column`.
    var column: WidgetColumn { .leading }
    var displayName: String { "Calendar" }
    var tier: WidgetTier { .glance }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { calendar.isEnabled }
        nonmutating set { calendar.isEnabled = newValue }
    }

    func panelSection() -> AnyView? {
        guard calendar.isEnabled else { return nil }
        // The section itself renders the grant CTA when access is missing.
        return AnyView(CalendarSectionView(onChooseCalendars: onChooseCalendars).environment(calendar))
    }
}

@MainActor
struct BatteryWidget: NotchWidget {
    let battery: BatteryWidgetModel

    var id: String { "battery" }
    var displayName: String { "Battery" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    /// Right-hand gutter of the top bar, beside the camera housing — rendered
    /// by `NotchTopBar`, not as a panel section.
    var placement: WidgetPlacement { .gutter }
    var isEnabled: Bool {
        get { battery.isEnabled }
        nonmutating set { battery.isEnabled = newValue }
    }

    /// Nothing: a `.gutter` widget is drawn by `NotchTopBar`, which reads the
    /// model directly, and only `.stack` sections are ever requested. Returning
    /// a view here would be one that can never appear.
    func panelSection() -> AnyView? { nil }
}

@MainActor
struct SystemStatsWidget: NotchWidget {
    let system: SystemStatsWidgetModel

    var id: String { "system" }
    var tab: NotchTab { .dashboard }
    /// Under Sound — see `SoundWidget.column`.
    var column: WidgetColumn { .trailing }
    var displayName: String { "System (CPU, GPU & Memory)" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { system.isEnabled }
        nonmutating set { system.isEnabled = newValue }
    }

    func panelSection() -> AnyView? {
        // Not waiting for `stats`: the section draws its rings empty until
        // the first figures land, so switching it on doesn't jump the column
        // a few seconds later.
        guard system.isEnabled else { return nil }
        return AnyView(SystemStatsSectionView().environment(system))
    }
}

@MainActor
struct TrayWidget: NotchWidget {
    let tray: TrayModel

    var id: String { "tray" }
    var displayName: String { "Shelf" }
    var tier: WidgetTier { .ambient }
    /// The tab would be empty without it, so it isn't optional.
    var isToggleable: Bool { false }
    var isEnabled: Bool {
        get { true }
        nonmutating set {}
    }
    var tab: NotchTab { .tray }

    func panelSection() -> AnyView? {
        // Always renders: the drop target IS the empty state.
        AnyView(TraySectionView().environment(tray))
    }
}

@MainActor
struct ClipboardWidget: NotchWidget {
    let clipboard: ClipboardWidgetModel

    var id: String { "clipboard" }
    var displayName: String { "Clipboard history" }
    var tier: WidgetTier { .ambient }
    /// Toggleable, unlike the tray: a clipboard manager records everything you
    /// copy, and someone who does not want that must be able to say so — the
    /// switch also stops the poller, so "off" costs nothing and stores nothing.
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { clipboard.isEnabled }
        nonmutating set { clipboard.isEnabled = newValue }
    }
    var tab: NotchTab { .clipboard }
    var column: WidgetColumn { .full }

    func panelSection() -> AnyView? {
        guard clipboard.isEnabled else { return nil }
        // Renders empty too: "copy something and it lands here" is the tab's
        // only explanation of itself.
        return AnyView(ClipboardSectionView().environment(clipboard))
    }
}
