import SwiftUI
import AirlockCore

/// The island's rows (I) of the inventory: the compact island, the top bar and
/// the open panel's own states.
///
/// **Compact rows go through Core.** Each builds a `CompactIslandInput` and lets
/// `CompactIsland` resolve BOTH halves — the ladder the live island climbs — and
/// draws them with `CompactLeadingGlyph` and `CompactTrailingGlyph`, the views
/// that ship. So a row cannot show a slot the ladder would never pick, and the
/// half you were not asking about is whatever the ladder puts there.
///
/// **The top bar is restated**, the way `TypingBarSnapshot` restates it:
/// `NotchTopBar` reads eight models, two of which own a microphone and a screen
/// reader. The pieces in the band are the real ones (`BatteryGutterView`,
/// `RecordingBadge`, `AirlockMark`); only the band holding them, the tab strip
/// and the plain glyph buttons are drawn here. Tooltips are
/// not drawn at all — a picture has no pointer.
@MainActor
enum GalleryIsland {
    static let area = "Island"

    static var states: [GalleryState] {
        [
            compact("I1", "Compact: nothing going on (bloub)", input()),
            compact("I2", "Compact: agent working",
                    input(agentsEnabled: true, sessionCount: 1, anyRunning: true)),
            compact("I3", "Compact: agent waiting (amber dot)",
                    input(agentsEnabled: true, attentionCount: 1, sessionCount: 1, anyRunning: true)),
            compact("I4", "Compact: agent finished (green cloud)",
                    input(agentsEnabled: true, sessionCount: 1, completionTick: true)),
            compact("I5", "Compact: paused music (no cover art drawn)",
                    input(hasMedia: true, mediaPausedAt: now.addingTimeInterval(-60))),
            compact("I6", "Compact: music playing (wave)", input(hasMedia: true, mediaPlaying: true)),
            compact("I7", "Compact: meeting in 5 minutes", input(meetingSoon: true),
                    meetingStart: now.addingTimeInterval(5 * 60 + 20)),
            compact("I7a", "Compact: meeting now", input(meetingSoon: true), meetingStart: now),
            compact("I8", "Compact: output switched (AirPods, 60%)",
                    input(outputChangedAt: now, outputLevel: 0.6, outputDeviceName: "AirPods Pro",
                          outputTransport: .bluetooth)),
            compact("I9", "Compact: battery critical",
                    input(batteryCritical: true, batteryMinutesRemaining: 12)),
            compact("I9a", "Compact: battery critical, agents open (scared red face)",
                    input(agentsEnabled: true, sessionCount: 3,
                          batteryCritical: true, batteryMinutesRemaining: 12)),
            compact("I9b", "Compact: battery critical, an agent waiting (orange stays)",
                    input(agentsEnabled: true, attentionCount: 1, sessionCount: 3,
                          batteryCritical: true, batteryMinutesRemaining: 12)),
            compact("I10", "Compact: keep awake stopped (cup + \"off\", not a battery)",
                    input(keepingAwake: false, keepAwakeStoppedAt: now, keepAwakeCutoff: 20)),
            compact("I11", "Compact: keeping awake", input(keepingAwake: true)),
            compact("I11a", "Compact: shelf count", input(shelfCount: 3)),
            compact("I12", "Compact: guide running",
                    input(guide: .guiding(step: 2, of: 5, offTrack: false))),
            compact("I13", "Compact: usage limit close",
                    input(usageNotice: .nearLimit(.fiveHour, percent: 90), usageNoticeAt: now)),
            compact("I13a", "Compact: on a WhatsApp call (icon + timer)",
                    input(call: OngoingCall(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp",
                                            startedAt: now.addingTimeInterval(-134)))),
            compact("I13b", "Compact: on a Meet call in Chrome (icon + timer)",
                    input(call: OngoingCall(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                            startedAt: now.addingTimeInterval(-1_412), site: .googleMeet))),
            compact("I13c", "Compact: on a call in Chrome, not Meet (icon + timer)",
                    input(call: OngoingCall(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                            startedAt: now.addingTimeInterval(-307)))),

            // The usage figures left the band for the Agents tab (W67–W69),
            // so these two are the right gutter at its two widths without them.
            GalleryState("I14", area, "Top bar: Agents, arrange, gear and battery (no usage figures)") {
                topBar(agents: 2) { tabStrip(.home) }
            },
            GalleryState("I15", area, "Top bar: on the Agents tab, Clear all beside it") {
                topBar(agents: 2, onAgents: true) { tabStrip(nil) }
            },
            GalleryState("I16", area, "Top bar: battery, low and charging") {
                VStack(spacing: 10) {
                    topBar(battery: lowBattery, agents: 2) { tabStrip(.home) }
                    topBar(battery: chargingBattery, agents: 2) { tabStrip(.home) }
                }
            },
            GalleryState("I17", area, "Top bar badge: Recording (dot starts bright)") {
                topBar(arrange: false) { RecordingBadge(isListening: true) }
            },
            GalleryState("I17a", area, "Top bar badge: Guiding") {
                topBar(arrange: false) {
                    AirlockMark(title: "Guiding")
                    glyph("chevron.up")
                }
            },
            GalleryState("I17b", area, "Top bar badge: Airlock (typing)") {
                topBar(arrange: false) {
                    AirlockMark()
                    glyph("chevron.up")
                }
            },

            GalleryState("I18", area, "Panel opens for a gate (question only + \"Show all agents\")") {
                VStack(alignment: .leading, spacing: 8) {
                    AgentSessionsList(sessions: [gateSession, runningSession])
                    ShowAllAgentsLink {}
                }
                .environment(\.showsOnlyWaitingSessions, true)
                .environment(AppModel())
                .environment(RepositoryWidgetModel())
                .environment(NotchUIState())
                .environment(LicenseModel(previewing: .trialing(daysRemaining: 9)))
            },
            .notYet("I19", area, "Panel too tall",
                    why: "It is the panel's height budget against a real screen; a picture of a view has no screen to overflow."),
            GalleryState("I20", area, "Home: nothing to show") {
                EmptyTabView(anyEnabled: true, onOpenSettings: {})
            },
            GalleryState("I20a", area, "Home: every widget switched off") {
                EmptyTabView(anyEnabled: false, onOpenSettings: {})
            },
            // Placement is the window's, so these two show what Settings now SAYS
            // about it — the real section, with the case that row is about.
            GalleryState("I21", area, "Full screen: Settings says Accessibility is what lets the notch step aside",
                         ground: .window, width: 576) {
                notchScreenSection(followsMainDisplay: true, showsOnExternalWhenClosed: false,
                                   canSeeFullScreen: false)
            },
            .notYet("I22", area, "Monitor without a notch",
                    why: "It is the island's placement on a screen with no camera housing, decided by the window, not a view."),
            GalleryState("I23", area, "Lid shut, nowhere to draw: Settings says so under the switch",
                         ground: .window, width: 576) {
                notchScreenSection(followsMainDisplay: false, showsOnExternalWhenClosed: false,
                                   canSeeFullScreen: true)
            },
            .notYet("I24", area, "File dragged onto the notch",
                    why: "It needs a live drag over the notch window; the shelf it opens onto is drawn in the Shelf rows."),
            GalleryState("I25", area, "Arrange mode: Home, then Agents with a request waiting (pinned first, in words)") {
                VStack(spacing: 12) {
                    ArrangeModeView(registry: WidgetRegistry(widgets: homeWidgets(on: true)),
                                    tab: .home, onOpenSettings: {})
                    ArrangeModeView(registry: WidgetRegistry(widgets: agentsWidgets),
                                    tab: .agents, onOpenSettings: {})
                }
                .environment(NotchUIState())
                .environment(SystemControlsModel())
            },
            GalleryState("I26", area, "Arrange an empty tab") {
                ArrangeModeView(registry: WidgetRegistry(widgets: homeWidgets(on: false)),
                                tab: .home, onOpenSettings: {})
                    .environment(NotchUIState())
                    .environment(SystemControlsModel())
            },
            GalleryState("I27", area, "Bloub's faces: every one, then stressed in blue") {
                bloubFaces
            },
        ]
    }

    /// Every expression in the plain body colour, then `.stressed` again in the
    /// blue it is meant for. Most faces are reachable only through code that
    /// picks them, so this is the one place to see them all side by side.
    private static var bloubFaces: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
        let faces = BloubExpression.allCases.map { ($0, nil as Color?) } + [(.stressed, Theme.running)]
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(faces.indices, id: \.self) { index in
                let (expression, tint) = faces[index]
                VStack(spacing: 6) {
                    BloubView(expression: expression, motion: .still, tint: tint)
                        .frame(width: 72, height: 60)
                    Text(tint == nil ? expression.rawValue : "\(expression.rawValue), blue")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 12)
    }

    /// The Settings section the full-screen and lid-shut rows are about, held
    /// at fixed values: a picture has nothing to toggle.
    private static func notchScreenSection(followsMainDisplay: Bool, showsOnExternalWhenClosed: Bool,
                                           canSeeFullScreen: Bool) -> some View {
        LookColumn {
            NotchScreenSection(followsMainDisplay: .constant(followsMainDisplay),
                               showsOnExternalWhenClosed: .constant(showsOnExternalWhenClosed),
                               canSeeFullScreen: canSeeFullScreen)
        }
    }

    // MARK: - Compact island

    /// One fixed instant, so every row's clocks agree: the route's two seconds,
    /// the keep-awake notice's thirty and the paused track's fifteen minutes
    /// are all measured from here.
    private static let now = Date()

    /// The input with only the facts a row names; everything else at rest.
    private static func input(agentsEnabled: Bool = false, attentionCount: Int = 0,
                              sessionCount: Int = 0, anyRunning: Bool = false,
                              completionTick: Bool = false, hasMedia: Bool = false,
                              mediaPlaying: Bool = false, meetingSoon: Bool = false,
                              outputChangedAt: Date? = nil, outputLevel: Float? = nil,
                              outputDeviceName: String? = nil,
                              outputTransport: AudioOutputDevice.Transport = .unknown,
                              mediaPausedAt: Date? = nil, batteryCritical: Bool = false,
                              batteryMinutesRemaining: Int? = nil, shelfCount: Int = 0,
                              keepingAwake: Bool = false, keepAwakeStoppedAt: Date? = nil,
                              keepAwakeCutoff: Int = 0, usageNotice: UsageAlert.Notice? = nil,
                              usageNoticeAt: Date? = nil,
                              guide: GuidePresentation.Compact? = nil,
                              call: OngoingCall? = nil) -> CompactIslandInput {
        CompactIslandInput(agentsEnabled: agentsEnabled, attentionCount: attentionCount,
                           sessionCount: sessionCount, anyRunning: anyRunning,
                           completionTick: completionTick, hasMedia: hasMedia,
                           mediaPlaying: mediaPlaying, meetingSoon: meetingSoon, now: now,
                           outputChangedAt: outputChangedAt, outputLevel: outputLevel,
                           outputDeviceName: outputDeviceName, outputTransport: outputTransport,
                           mediaPausedAt: mediaPausedAt, batteryCritical: batteryCritical,
                           batteryMinutesRemaining: batteryMinutesRemaining, shelfCount: shelfCount,
                           keepingAwake: keepingAwake, keepAwakeStoppedAt: keepAwakeStoppedAt,
                           keepAwakeCutoff: keepAwakeCutoff, usageNotice: usageNotice,
                           usageNoticeAt: usageNoticeAt, guide: guide, call: call)
    }

    /// Both halves of the island, resolved from one input. The face's ambient
    /// facts are taken from the same input, as `NotchCompactLeadingView`
    /// derives them, so the bloub cannot disagree with the slot beside it.
    /// The 4pt either side is the live views' own padding.
    ///
    /// Internal so other areas' rows (the call notes, K) draw the island the
    /// same way. `notesMark` is what `NotchCompactTrailingView` hands the call
    /// pill from the notes model, which a row has no copy of, and `notesLimit`
    /// Free's word about the notes' limit beside it. Read when the
    /// row is drawn, not when the list is made, so a countdown in it starts
    /// from the top however late in an export its row comes.
    static func compact(_ id: String, _ name: String, _ input: CompactIslandInput,
                        area: String = GalleryIsland.area, meetingStart: Date? = nil,
                        notesMark: @escaping @MainActor () -> MeetingNotesFlow.PillMark = { .none },
                        notesLimit: @escaping @MainActor () -> CallNotesLimit? = { nil })
        -> GalleryState {
        let ambient = BloubFace.Ambient(batteryCritical: input.batteryCritical,
                                        meetingSoon: input.meetingSoon, guide: input.guide)
        var state = GalleryState(id, area, name, ground: .compact) {
            // Empty levels draw the canned loop, which is what most Macs see:
            // there is usually no audio tap.
            CompactTrailingGlyph(slot: CompactIsland.trailing(input),
                                 meetingStart: { meetingStart }, waveLevels: { [] })
                .environment(\.callNotesMark, notesMark())
                .environment(\.callNotesLimit, notesLimit())
                .padding(.horizontal, 4)
        }
        state.leading = {
            // No artwork URL: `ArtworkView` would fetch it, and a picture may not.
            AnyView(CompactLeadingGlyph(slot: CompactIsland.leading(input),
                                        ambient: { ambient }, artworkURL: { nil })
                .padding(.horizontal, 4))
        }
        return state
    }

    // MARK: - Top bar

    /// The band beside the camera: whatever stands in the left gutter, the
    /// reserved centre, and the right gutter's Clear all, Agents tab, arrange,
    /// gear and battery in `NotchTopBar`'s order. Internal so the typed-bar
    /// rows can sit under the same band. `agents` is the Agents tab's session
    /// count, nil for no Agents tab (agents off, or a mode has the band);
    /// `onAgents` selects it, which is when Clear all is offered.
    ///
    /// Measured as the default panel lays it out: 640 wide, a 190pt centre
    /// (roughly a 14-inch housing — the real figure is the person's own
    /// screen's), so each gutter gets 225. The gutters are fixed frames, as in
    /// `NotchTopBar`, so a cluster wider than its gutter spills toward the
    /// camera here exactly as it does there, rather than being squeezed to fit.
    /// The gallery's ground is the panel's 640; the island the kit draws is
    /// 60pt wider (`IslandChrome`), so the end items sitting hard against the
    /// ground's edge is the picture's, not the app's.
    static func topBar<Left: View>(battery: BatteryState = halfBattery,
                                   arrange: Bool = true, agents: Int? = nil, onAgents: Bool = false,
                                   @ViewBuilder left: () -> Left) -> some View {
        let gutter = GutterBudget(panelWidth: NotchAppearanceModel.defaultPanelWidth, notchWidth: 190)
        return HStack(spacing: 0) {
            HStack(spacing: 3) {
                left()
                Spacer(minLength: 0)
            }
            .frame(width: gutter.layoutGutter, alignment: .leading)
            .padding(.leading, 8)

            Color.clear.frame(width: gutter.reservedCentre)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let agents {
                    if onAgents { glyph("xmark.circle", tint: Theme.textTertiary) }
                    tab(.agents, selected: onAgents, count: agents)
                }
                if arrange { glyph("rectangle.on.rectangle") }
                glyph("gear")
                BatteryGutterView(state: battery, showsPercentage: true)
            }
            .frame(width: gutter.layoutGutter, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .frame(height: 32)
        // The panel ground's own inset would take 28pt the real band has.
        .frame(width: NotchAppearanceModel.defaultPanelWidth - 28)
    }

    /// `selected` drawn selected, the other tabs grey; nil when the selected
    /// tab is Agents, on the right. Every tab on the left, as
    /// `registry.visibleTabs()` gives them with every widget on and call notes
    /// on, split as `NotchTopBar` splits them: Agents is on the right
    /// (`topBar(agents:)`). The strip's own tests cover which ones drop out.
    private static func tabStrip(_ selected: NotchTab?) -> some View {
        HStack(spacing: 3) {
            ForEach(NotchTab.topBarSides(NotchTab.allCases).leading) { tab in
                self.tab(tab, selected: tab == selected)
            }
            glyph("chevron.up")
        }
    }

    /// `NotchTopBar.tabButton`'s look, without the button: the cloud for
    /// Home, the symbol otherwise, and a session count when there is one.
    private static func tab(_ tab: NotchTab, selected: Bool, count: Int? = nil) -> some View {
        HStack(spacing: 3) {
            if tab == .home {
                BloubView(expression: .attentive, tint: selected ? Theme.running : Theme.textTertiary)
                    .frame(width: 18, height: 15)
            } else {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: .semibold))
            }
            if let count {
                Text("\(count)")
                    .font(Theme.gutter(11, .bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
        .frame(width: count == nil ? 36 : 48, height: 26)
        .background {
            if selected { Capsule().fill(Color.white.opacity(0.16)) }
        }
    }

    /// `NotchTopBar.iconButton`'s glyph, without the button.
    static func glyph(_ symbol: String, tint: Color = Theme.textSecondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
    }

    static let halfBattery = BatteryState(percentage: 63, isCharging: false, isCharged: false,
                                          isPluggedIn: false, minutesRemaining: 214)
    private static let lowBattery = BatteryState(percentage: 14, isCharging: false, isCharged: false,
                                                 isPluggedIn: false, minutesRemaining: 38)
    private static let chargingBattery = BatteryState(percentage: 81, isCharging: true, isCharged: false,
                                                      isPluggedIn: true, minutesRemaining: nil)

    // MARK: - Panel

    /// The session `AgentsTabSnapshot` draws as the gate, and a running one the
    /// question-only view must leave out.
    private static let gateSession = AgentSession(
        id: "a", agent: .claudeCode, projectName: "storefront", cwd: "/Users/you/storefront",
        terminal: TerminalInfo(app: "iTerm.app", tty: "ttys002"), status: .needsAttention,
        lastSummary: "Running a shell command", lastPrompt: "ship the new checkout to production",
        startedAt: now.addingTimeInterval(-27 * 60), lastActivity: now,
        pendingPermission: PermissionRequest(id: "req-1", toolName: "Bash", summary: "Run shell command",
                                             command: "rm -rf ./dist && npm run deploy:prod", createdAt: now),
        jumpTarget: JumpTarget(terminalApp: "iTerm.app"), turns: 6)
    private static let runningSession = AgentSession(
        id: "b", agent: .codex, projectName: "api-gateway", cwd: "/Users/you/api",
        terminal: TerminalInfo(app: "tmux"), status: .running,
        lastSummary: "Editing 3 files", lastPrompt: "add rate limiting to the login route",
        startedAt: now.addingTimeInterval(-4 * 60), lastActivity: now,
        jumpTarget: JumpTarget(terminalApp: "tmux"), turns: 2)

    // MARK: - Arrange mode

    /// Home's blocks in `AppDelegate`'s registry order, as names: arrange mode
    /// draws a widget's `displayName` and never its section, so a stand-in is
    /// everything it reads. The names are the real widgets' and must follow
    /// them. Ids are the gallery's own, so the person's saved arrangement
    /// never reorders a picture.
    private static func homeWidgets(on: Bool) -> [any NotchWidget] {
        [
            ArrangeStandIn(id: "gallery.ask", displayName: "Ask", on: on),
            ArrangeStandIn(id: "gallery.media", displayName: "Media (Spotify & Apple Music)", on: on),
            ArrangeStandIn(id: "gallery.systemControls", displayName: "System controls",
                           column: .leading, on: on, hasButtonRow: true),
            ArrangeStandIn(id: "gallery.keymap", displayName: "Shortcut map", column: .leading, on: on),
            ArrangeStandIn(id: "gallery.sound", displayName: "Sound (output & per-app volume)",
                           column: .trailing, on: on),
        ]
    }

    private static let agentsWidgets: [any NotchWidget] = [
        ArrangeStandIn(id: "gallery.agents", displayName: "AI agents", tab: .agents,
                       demandsAttention: true),
        ArrangeStandIn(id: "gallery.repository", displayName: "Repository", tab: .agents),
    ]
}

/// A widget as arrange mode sees it: a name, a tab, a column, on or off.
private struct ArrangeStandIn: NotchWidget {
    let id: String
    let displayName: String
    var tab: NotchTab = .home
    var column: WidgetColumn = .full
    var on = true
    var demandsAttention = false
    var hasButtonRow = false

    var tier: WidgetTier { demandsAttention ? .interrupt : .ambient }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { on }
        nonmutating set { }
    }

    func panelSection() -> AnyView? { nil }
}
