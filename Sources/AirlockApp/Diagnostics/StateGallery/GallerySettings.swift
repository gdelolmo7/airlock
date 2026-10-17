import SwiftUI
import AirlockCore

/// The Settings rows (X), each page drawn on its own at the detail column's
/// width.
///
/// Only the pages whose models can stand still are drawn. `SettingsModel` and
/// the agents switch are previews that read nothing from disk; the clipboard,
/// guide and dictation models only read preferences when built. The pages that
/// read live permissions, rebuild key monitors, start Sparkle or read the
/// Keychain stay cards until they have a seam of their own.
@MainActor
enum GallerySettings {
    static let area = "Settings"

    static var states: [GalleryState] {
        [
            GalleryState("X1", area, "Window: Calls, then the pages down the side, Voice open", ground: .window,
                         width: AirlockWindowView.firstSize.width) {
                window
            },
            GalleryState("X1a", area, "Window: Calls chosen, a call's notes beside the list", ground: .window,
                         width: AirlockWindowView.firstSize.width) {
                callsWindow
            },
            .notYet("X2", area, "Search: nothing found / results",
                    why: "What is typed in the search box is the window's private state; there is no way to set it."),
            .notYet("X3", area, "General: About",
                    why: "General builds a live health report and needs Sparkle's updater model."),
            GalleryState("X4", area, "General: Updates", ground: .window, width: paneWidth) {
                GalleryLicence.updates(.quiet, canCheck: true)
            },
            GalleryState("X4a", area, "General: Send crash reports, and what a report is", ground: .window,
                         width: paneWidth) {
                // The switch as it ships, off, then the notes under More
                // options. Only a build with somewhere to send shows it.
                LookColumn {
                    CrashReportsSection(isOn: .constant(false))
                    LookGroupLabel("Crash reports")
                    ForEach(CrashReportsSection.notes, id: \.self) { LookNote($0) }
                }
            },
            GalleryState("X4b", area, "General: Share usage counts, and what a count is", ground: .window,
                         width: paneWidth) {
                // Off as it ships, then the notes under More options. Only a
                // build with somewhere to send shows it.
                LookColumn {
                    UsageCountsSection(isOn: .constant(false))
                    LookGroupLabel("Usage counts")
                    ForEach(UsageCountsSection.notes, id: \.self) { LookNote($0) }
                }
            },
            GalleryState("X5", area, "General: Health", ground: .window, width: paneWidth) {
                health(inputMonitoring: .allowed)
            },
            GalleryState("X5a", area, "General: Health, Input Monitoring on but not working", ground: .window,
                         width: paneWidth) {
                health(inputMonitoring: .notWorking)
            },
            GalleryState("X6", area, "General: launch at login failed", ground: .window, width: paneWidth) {
                GalleryLicence.launchAtLoginRefused
            },
            .notYet("X7", area, "General: guide prototype (hold ⌥)",
                    why: "Reads the guide's key from the Keychain and is unlocked by holding ⌥."),
            .notYet("X8", area, "The notch: island picture",
                    why: "The page needs a dozen widget models whose switches read the real preferences, and the island picture is wired by the app."),
            .notYet("X9", area, "The notch: width",
                    why: "The page needs a dozen widget models whose switches read the real preferences."),
            .notYet("X10", area, "The notch: usage figures connected / replaced / not set up",
                    why: "The page reads Claude's settings file on appear; no preview seam yet."),
            .notYet("X11", area, "The notch: a widget turned off",
                    why: "Turning a widget off means writing a real preference."),
            .notYet("X12", area, "The notch: media wave problem / usage failure",
                    why: "The page needs a dozen widget models whose switches read the real preferences."),
            .notYet("X13", area, "The notch: calendars",
                    why: "The page needs a dozen widget models whose switches read the real preferences."),
            .notYet("X14", area, "Voice: keys clash / microphone missing",
                    why: "The Voice page re-checks the hold key's event tap on appear, which can raise the Input Monitoring prompt."),
            GalleryState("X15", area, "Voice: the six rows", ground: .window, width: paneWidth) {
                voice(moreOptions: false, height: 500)
            },
            GalleryState("X15a", area, "Voice: Catalan on calls, a language only dictation knows",
                         ground: .window, width: paneWidth) {
                voice(moreOptions: true, height: 2300, store: catalanCallsStore, callListeners: catalanListeners)
            },
            // Dictation types either way; only the tidy-up and asking are
            // out of reach, and each says so with the way to turn it on.
            GalleryState("X15b", area, "Voice: Apple Intelligence switched off, tidying and asking say so",
                         ground: .window, width: paneWidth) {
                voice(moreOptions: true, height: 2200, model: .needsAppleIntelligence)
            },
            GalleryState("X15c", area, "Voice: a Mac that can't run Apple Intelligence",
                         ground: .window, width: paneWidth) {
                voice(moreOptions: false, height: 560, model: .deviceNotEligible)
            },
            .notYet("X16", area, "Voice: Input Monitoring stale",
                    why: "The hold key's fault is private to the dictation model; the row is the same Fix as X34, drawn there."),
            GalleryState("X17", area, "Voice: more options open", ground: .window, width: paneWidth) {
                voice(moreOptions: true, height: 2200)
            },
            .notYet("X18", area, "Voice: typed-bar section",
                    why: "The sentence shows only with the typed bar switched on, and switching it on writes a real preference."),
            .notYet("X19", area, "Voice: microphone row",
                    why: "The Voice page re-checks the hold key's event tap on appear, which can raise the Input Monitoring prompt."),
            GalleryState("X20", area, "Clipboard: off / hotkey / auto-paste", ground: .window, width: paneWidth) {
                clipboard
            },
            GalleryState("X21", area, "Clipboard: Clear all", ground: .window, width: paneWidth) {
                clipboard
            },
            GalleryState("X22", area, "Clipboard: where it's kept", ground: .window, width: paneWidth) {
                clipboard(moreOptions: true)
            },
            GalleryState("X23", area, "Clipboard: last copy skipped", ground: .window, width: paneWidth) {
                clipboard(lastSkip: .ignoredApp("com.bitwarden.desktop"))
            },
            GalleryState("X24", area, "Agents: connected / not", ground: .window, width: paneWidth) {
                agents(mixed)
            },
            GalleryState("X24a", area, "Agents: on Free, every agent from the notch carries a Plus tag",
                         ground: .window, width: paneWidth) {
                agents(mixed, license: LicenseModel(previewing: .free))
            },
            GalleryState("X25", area, "Agents: conflict", ground: .window, width: paneWidth) {
                agents(conflicted)
            },
            GalleryState("X26", area, "Agents: jargon", ground: .window, width: paneWidth) {
                agents(mixed)
            },
            GalleryState("X27", area, "Agents: advanced sections (match counts, which rule wins)", ground: .window,
                         width: paneWidth) {
                agents(mixed, advanced: true)
            },
            GalleryState("X28", area, "Agents: rules empty / unreadable / invalid", ground: .window,
                         width: paneWidth) {
                agents(mixed, policy: brokenPolicy, advanced: true)
            },
            GalleryState("X29", area, "Permissions: \"Ask for everything\" leaves Screen Recording", ground: .window,
                         width: paneWidth) {
                permissions(allowed.with { $0.screenRecording = .notAllowed }, sweep: .ran, height: 1400)
            },
            GalleryState("X29a", area, "Permissions: \"Ask for everything\", all allowed", ground: .window,
                         width: paneWidth) {
                permissions(allowed, sweep: .ran, height: 1120)
            },
            GalleryState("X30", area, "Permissions: restricted by your organisation", ground: .window,
                         width: paneWidth) {
                permissions(allowed.with { $0.calendar = .restricted; $0.microphone = .restricted }, height: 1120)
            },
            GalleryState("X31", area, "Permissions: Calendar turned off after it was allowed", ground: .window,
                         width: paneWidth) {
                permissions(allowed.with { $0.calendar = .notAllowed }, height: 1240)
            },
            GalleryState("X31a", area, "Permissions: Calendar not asked yet, macOS kept quiet", ground: .window,
                         width: paneWidth) {
                permissions(allowed.with {
                    $0.calendar = .notAsked
                    $0.calendarNote = CalendarWidgetModel.accessNote(for: .promptSuppressed)
                }, height: 1160)
            },
            GalleryState("X32", area, "Permissions: Microphone turned off, Accessibility and Screen Recording not allowed",
                         ground: .window, width: paneWidth) {
                permissions(allowed.with {
                    $0.microphone = .notAllowed
                    $0.accessibility = .notAllowed
                    $0.screenRecording = .notAllowed
                }, askedForScreenRecording: true, height: 1720)
            },
            GalleryState("X33", area, "Permissions: Input Monitoring not allowed", ground: .window, width: paneWidth) {
                permissions(allowed.with { $0.inputMonitoring = .notAllowed }, askedForInputMonitoring: true,
                            height: 1400)
            },
            GalleryState("X34", area, "Permissions: Input Monitoring on, but an old approval refuses it",
                         ground: .window, width: paneWidth) {
                permissions(allowed.with { $0.inputMonitoring = .notWorking }, height: 1220)
            },
            GalleryState("X35", area, "Permissions: Automation", ground: .window, width: paneWidth) {
                permissions(allowed, height: 1120)
            },
            GalleryState("X36", area, "Permissions: Fix", ground: .window, width: paneWidth) {
                permissions(allowed.with { $0.accessibility = .notAllowed }, height: 1400)
            },
            GalleryState("X37", area, "Permissions: footer", ground: .window, width: paneWidth) {
                permissions(allowed, moreOptions: true, height: 1900)
            },
        ] + guideStates + [
            GalleryState("X41", area, "Voice: call notes on, with Open past calls", ground: .window,
                         width: paneWidth) {
                voice(moreOptions: false, height: 720, store: callNotesStore)
            },
            GalleryState("X41a", area, "Voice: call notes on, words to know listed", ground: .window,
                         width: paneWidth) {
                voice(moreOptions: false, height: 740, store: callNotesStore,
                      knownWords: ["Brightwell", "Velaroja", "Quintela", "Rosamar Ortiz", "Zentrix CRM"])
            },
            GalleryState("X41b", area, "Voice: on Free, notes written online carry a Plus tag", ground: .window,
                         width: paneWidth) {
                voice(moreOptions: false, height: 760, store: callNotesStore,
                      license: LicenseModel(previewing: .free))
            },
        ]
    }

    /// The guide's two pages, only in a build that has the guide.
    private static var guideStates: [GalleryState] {
        #if AIRLOCK_GUIDE
        [
            GalleryState("X38", area, "Guide page: no key, no Screen Recording", ground: .window, width: paneWidth) {
                guide(GuideReadiness(keySaved: false, screenRecording: false), height: 780)
            },
            GalleryState("X38a", area, "Guide page: ready to run", ground: .window, width: paneWidth) {
                guide(GuideReadiness(keySaved: true, screenRecording: true), height: 660)
            },
            GalleryState("X39", area, "Privacy page", ground: .window, width: paneWidth) {
                privacy
            },
            GalleryState("X40", area, "Privacy: never-look list / password blackout", ground: .window,
                         width: paneWidth) {
                privacy
            },
        ]
        #else
        []
        #endif
    }

    // MARK: - Fixtures

    /// About the width a page is given in the Airlock window: `LookPage`
    /// stops growing at 560.
    private static let paneWidth: CGFloat = 576

    private static let mixed: [SettingsModel.AgentRow] = [
        .init(kind: .claudeCode, name: "Claude Code", configPath: "~/.claude/settings.json", status: .installed),
        .init(kind: .codex, name: "Codex", configPath: "~/.codex/config.toml", status: .notInstalled),
    ]

    private static let conflicted: [SettingsModel.AgentRow] = [
        .init(kind: .claudeCode, name: "Claude Code", configPath: "~/.claude/settings.json",
              status: .conflict("another tool's Notification hook is already there")),
        .init(kind: .codex, name: "Codex", configPath: "~/.codex/config.toml", status: .notInstalled),
    ]

    /// No policy file yet — a new install. `refresh()` would fill the path in;
    /// the preview never runs it.
    private static let noPolicy = SettingsModel.PolicyInfo(
        path: "~/.airlock/policy.yaml", exists: false, allow: [], deny: [],
        askTimeout: Policy.defaultAskTimeout, problems: [])

    /// A policy file that did not parse, so nothing in it is in force.
    private static let brokenPolicy = SettingsModel.PolicyInfo(
        path: "~/.airlock/policy.yaml", exists: true, allow: [], deny: [],
        askTimeout: Policy.defaultAskTimeout,
        problems: ["~/.airlock/policy.yaml, line 4: \u{201c}Bash(git push\u{201d} is missing a closing bracket."])

    /// A suite nothing writes to, with Advanced registered on. Registration is
    /// in memory only, so it reaches no file.
    private static let advancedStore: UserDefaults = {
        let store = UserDefaults(suiteName: "com.airlock.state-gallery.advanced") ?? .standard
        store.register(defaults: [AdvancedSwitch.key: true])
        return store
    }()

    /// And the same with it off, so a real "Show advanced" in the debug
    /// domain cannot leak into the plain pictures.
    private static let plainStore = UserDefaults(suiteName: "com.airlock.state-gallery") ?? .standard

    /// Call notes registered on, the same way: the Voice page's call rows
    /// show only then.
    private static let callNotesStore: UserDefaults = {
        let store = UserDefaults(suiteName: "com.airlock.state-gallery.call-notes") ?? .standard
        store.register(defaults: [MeetingNotesModel.enabledKey: true])
        return store
    }()

    private static var clipboardItems: [ClipboardItem] {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        return [
            ClipboardItem(payload: .text("git push origin main"), fingerprint: "g1", copiedAt: now, pinned: true),
            ClipboardItem(payload: .text("https://useairlock.app"), fingerprint: "g2", copiedAt: now),
            ClipboardItem(payload: .image(file: "gallery.png", width: 1280, height: 800), fingerprint: "g3",
                          copiedAt: now),
        ]
    }

    // MARK: - Drawing

    /// Calendar never asked for and a Codex nobody connected: neither is
    /// something to fix, so neither is amber. With `.notWorking`, the old
    /// Input Monitoring approval is the one thing that is.
    private static func health(inputMonitoring: DiagnosticsReport.PermissionState) -> some View {
        let report = DiagnosticsReport(
            version: "1.4.0 (642)", macOS: "26.0", hardware: "Mac16,7", hasNotch: true, displayCount: 1,
            permissions: [.init("Calendar", .notAsked), .init("Microphone", .allowed),
                          .init("Accessibility", .allowed), .init("Input Monitoring", inputMonitoring),
                          .init("Audio capture", .asksOnFirstUse)],
            hooks: [.init("Claude Code", .installed), .init("Codex", .notInstalled)],
            updater: .configured(automaticChecks: true), license: .trial(daysRemaining: 10),
            widgets: [.init("Agents", isEnabled: true), .init("Calendar", isEnabled: true)],
            secureInput: .off)
        return LookColumn {
            LookGroupLabel("Health")
            DiagnosticsHealthView(health: DiagnosticsHealth.from(report),
                                  summary: nil,
                                  onCopy: {}, onOpen: { _ in })
                .lookRowBox()
        }
    }

    private static var clipboard: some View { clipboard() }

    /// The previewing model: nothing starts watching the pasteboard, and the
    /// last skip is a value.
    private static func clipboard(lastSkip: ClipboardSkipReason? = nil, moreOptions: Bool = false) -> some View {
        ClipboardPane(moreOptions: moreOptions)
            .environment(ClipboardWidgetModel(previewing: ClipboardHistory(items: clipboardItems),
                                              lastSkip: lastSkip))
            .environment(SettingsModel(previewing: []))
            .frame(height: moreOptions ? 1900 : 1100)
    }

    /// With no `license` the page is drawn the way it was before plans: no tag.
    private static func agents(_ rows: [SettingsModel.AgentRow], policy: SettingsModel.PolicyInfo = noPolicy,
                               advanced: Bool = false, license: LicenseModel? = nil) -> some View {
        AgentsPane(moreOptions: advanced)
            .environment(SettingsModel(previewing: rows, policy: policy))
            .environment(license)
            .environment(AgentsWidgetModel(previewing: .hooksInstalled))
            .environment(DictationModel())
            .environment(UsageAlertModel())
            .defaultAppStorage(advanced ? advancedStore : plainStore)
            .frame(height: advanced ? 2920 : 1760)
    }

    /// Everything allowed, with the guide on so Screen Recording has a row.
    private static let allowed = PermissionFacts(
        calendar: .allowed, microphone: .allowed, inputMonitoring: .allowed,
        accessibility: .allowed, screenRecording: .allowed)

    /// The page drawn from values: no permission is read and nothing can ask.
    private static func permissions(_ facts: PermissionFacts, sweep: PermissionSweepState = .notRun,
                                    askedForInputMonitoring: Bool = false,
                                    askedForScreenRecording: Bool = false,
                                    moreOptions: Bool = false,
                                    height: CGFloat) -> some View {
        PermissionsPage(facts: facts, sweep: sweep,
                        askedForInputMonitoring: askedForInputMonitoring,
                        askedForScreenRecording: askedForScreenRecording,
                        moreOptions: moreOptions)
            .environment(SettingsModel(previewing: []))
            .frame(height: height)
    }

    /// The Voice page as a fresh install sees it. Nothing here re-checks the
    /// hold key: that happens only when a permission changes or Airlock comes
    /// back to the front, and neither happens in an export.
    /// `knownWords` stands in for the saved list, so no picture shows this
    /// Mac's own words.
    /// `model` stands in for what Apple's on-device model can do here.
    private static func voice(moreOptions: Bool, height: CGFloat, store: UserDefaults = plainStore,
                              callListeners: CallListeners? = nil, knownWords: [String] = [],
                              model: ModelAvailability? = nil, license: LicenseModel? = nil) -> some View {
        let dictation = DictationModel()
        dictation.previewCleanupAvailability = model
        let assistant = AssistantModel()
        assistant.previewAvailability = model
        return DictationPane(moreOptions: moreOptions, callListeners: callListeners, knownWords: knownWords)
            .environment(dictation)
            .environment(assistant)
            .environment(license)
            .environment(SettingsModel(previewing: []))
            .defaultAppStorage(store)
            .frame(height: height)
    }

    /// Call notes on, and calls set to Catalan with nothing beside it.
    /// Registered only, like `advancedStore`.
    private static let catalanCallsStore: UserDefaults = {
        let store = UserDefaults(suiteName: "com.airlock.state-gallery.calls") ?? .standard
        store.register(defaults: [MeetingNotesModel.enabledKey: true, CallLanguage.primaryKey: "ca_ES"])
        return store
    }()

    /// A few of this Mac's languages, as the two recognisers list them, with
    /// Catalan known to dictation alone and not downloaded yet.
    private static let catalanListeners = CallListeners(
        speech: ["en_GB", "en_US", "es_ES", "fr_FR", "it_IT"],
        dictation: ["ca_ES", "en_GB", "en_US", "es_ES", "eu_ES", "fr_FR", "gl_ES", "it_IT"])

    /// The whole window, the first time it opens: Calls, then every page
    /// the guide build shows (the most there can be) down the side, and the
    /// Voice page beside them. Drawn here rather than taken from
    /// `AirlockWindowView`, whose pages read live models; the pieces are the
    /// same ones.
    private static var window: some View {
        HStack(alignment: .top, spacing: 0) {
            LookSidebar(pages: SettingsPane.sidebar(guideOn: true),
                        selection: .constant(.voice), calls: .constant(false), query: .constant(""))
            voice(moreOptions: false, height: AirlockWindowView.firstSize.height - 30)
                .padding(.top, 2)
                .frame(maxWidth: .infinity)
        }
        // The real window's title bar, which the page and column sit under.
        .safeAreaPadding(.top, 28)
        .frame(width: AirlockWindowView.firstSize.width, height: AirlockWindowView.firstSize.height)
        .background(SettingsLook.ground)
    }

    /// The window on Calls: the real one this time, since the calls read
    /// no live model, with sample calls and no disk.
    private static var callsWindow: some View {
        let model = SettingsModel(previewing: [])
        model.showsCalls = true
        return AirlockWindowView()
            .environment(model)
            .environment(GalleryMeetings.sampleLibrary())
            .defaultAppStorage(plainStore)
            .safeAreaPadding(.top, 28)
            .frame(width: AirlockWindowView.firstSize.width, height: AirlockWindowView.firstSize.height)
    }

    #if AIRLOCK_GUIDE
    /// The readiness is a value, so the keychain is never asked.
    private static func guide(_ readiness: GuideReadiness, height: CGFloat) -> some View {
        GuidePane(fixedReadiness: readiness)
            .environment(AssistantModel())
            .environment(DictationModel())
            .environment(SettingsModel(previewing: []))
            .frame(height: height)
    }

    private static var privacy: some View {
        PrivacyPane(readsKey: false)
            .environment(SettingsModel(previewing: []))
            .frame(height: 560)
    }
    #endif
}
