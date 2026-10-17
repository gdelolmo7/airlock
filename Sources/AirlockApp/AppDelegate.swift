import AppKit
import AVFoundation
import AirlockCore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var media: MediaWidgetModel?
    private var calendarWidget: CalendarWidgetModel?
    private var batteryWidget: BatteryWidgetModel?
    private var trayWidget: TrayModel?
    private var clipboardWidget: ClipboardWidgetModel?
    private var appearance: NotchAppearanceModel?
    private var usageConnection: UsageConnectionModel?
    private var systemWidget: SystemStatsWidgetModel?
    private var notch: NotchController?
    private var statusItem: NSStatusItem?
    private var settingsModel: SettingsModel?
    private var appWindow: AirlockWindowController?
    /// Retained here because `UNUserNotificationCenter.delegate` is weak — left
    /// to a local it deallocates immediately and every notification silently
    /// stops being clickable, with nothing to see in either direction.
    private let notificationRouter = NotificationRouter()
    private var onboarding: OnboardingWindowController?
    /// Shared by both surfaces. First run and the menu bar's "Set up Airlock…"
    /// present it in the panel, the window only when there is no panel; one
    /// object, so hooks installed in one are installed in the other and the
    /// completion flag is settled in one place.
    private var onboardingModel: OnboardingModel?
    #if AIRLOCK_GUIDE
    private var welcome: WelcomeWindowController?
    #endif
    /// The once-only "permissions again after the rename" window, kept while
    /// it is up.
    private var permissionsAgain: PermissionsAgainWindowController?
    private var dictation: DictationModel?
    private var assistant: AssistantModel?
    #if AIRLOCK_GUIDE
    private var guide: GuideController?
    #endif
    private var agentsWidget: AgentsWidgetModel?
    private var audioOutput: AudioOutputModel?
    private var appVolume: AppVolumeModel?
    private var sound: SoundWidgetModel?
    private var repositoryWidget: RepositoryWidgetModel?
    private var updater: UpdaterModel?
    private var license: LicenseModel?
    /// The limits last passed on by `watchPlanLimits`.
    private var planLimits: PlanLimits?
    private var systemControls: SystemControlsModel?
    private var tally: UsageTallyStore?

    /// `airlock://activate?key=…` coming back from a finished checkout.
    ///
    /// `application(_:open:)` rather than the Apple-event handler: the modern
    /// callback arrives for a scheme declared in `CFBundleURLTypes` and needs no
    /// manual registration, and this app already has an Apple-event story it
    /// does not need to complicate.
    ///
    /// Everything here is untrusted — a URL can be typed by anyone — so the key
    /// only ever reaches `LicenseModel.apply`, which verifies before it stores.
    /// A URL we do not recognise is ignored in silence rather than reported: it
    /// was not addressed to us in any meaningful sense.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let key = urls.lazy.compactMap({ ActivationURL.key(from: $0) }).first,
              let license else { return }
        // A key that went in shows Settings › Plans already on the new plan,
        // where "Finish paying in your browser" has turned into "You're on
        // Plus". One that failed to verify leaves the page waiting, which is
        // the truth — the browser said something and it was not a licence.
        Task { @MainActor [weak self] in
            if await license.apply(key) { self?.appWindow?.show(pane: .license) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before EVERYTHING, including the identity migration: a snapshot run
        // renders five views and quits, and has no business copying a year of
        // somebody's preferences on the way past. See `PanelSnapshot`.
        if let destination = PanelSnapshot.requested() {
            let ok = PanelSnapshot.write(to: destination, width: NotchAppearanceModel().panelWidth)
            NSApp.terminate(nil)
            _ = ok
            return
        }
        // Same place, same reason: the gallery is the whole app in this run,
        // and it must not leave a trace in anyone's settings. See `StateGallery`.
        if let gallery = StateGallery.requested() {
            StateGallery.run(gallery)
            return
        }

        // FIRST, before anything reads state. AppModel restores sessions in its
        // own `start()`, the widget models seed themselves from UserDefaults at
        // construction, and the policy store is read on the first gate — every
        // one of those would see an empty new-identity world if the copy had
        // not already happened.
        migrateFromLegacyIdentity()
        // Right after the preferences are where they belong, since the answer
        // is one of them, and as early as that allows: a crash later in this
        // launch is one worth a report. Does nothing in a build without a DSN
        // or for anyone who has not said yes. A demo run leaves it alone, so
        // it never touches the marker the installed copy keeps.
        if !Self.isDemoMode { CrashReporter.shared.launch() }
        // The hand over buttons, with another app in front — see the type.
        let cursorOK = BackgroundCursor.enable()
        HoverTrace.note("background cursor \(cursorOK ? "enabled" : "unavailable")")
        refreshStagedHook()
        upgradeInstalledHooks()

        // Nothing here asks the licence whether to work: no plan stops the
        // app. What a plan leaves out is `PlanLimits`, asked at the moment of
        // use by whatever it limits. Made before the bridge and the widgets,
        // so the first gate and the first copy already know the plan; it
        // starts checking with the server further down, as it always has.
        let license = LicenseModel()
        self.license = license
        // Usage counts, for people who said yes (`UsageCounts`). After the
        // licence, whose plan every batch carries, and before anything that
        // counts. A demo run never starts them, so it never sends or touches
        // the waiting file the installed copy keeps.
        UsageCounts.shared.context = { [weak license] in
            UsageCounts.context(plan: license?.entitlement.plan ?? .free)
        }
        if !Self.isDemoMode { UsageCounts.shared.launch() }

        // A demo listens on a socket of its own; `SocketPath.listening(demo:)`
        // says why.
        let model = AppModel(bridge: BridgeServer(path: SocketPath.listening(demo: Self.isDemoMode)))
        self.model = model
        model.oneAgentAtATime = license.entitlement.limits.oneAgentAtATime
        model.start()

        if Self.isDemoMode { model.seedDemo() }

        let media = MediaWidgetModel()
        self.media = media
        media.start()

        let audioOutput = AudioOutputModel()
        self.audioOutput = audioOutput
        audioOutput.start()

        // Off by default, so `start()` is a no-op until somebody switches it on.
        // It is the only surface here that takes over the audio path.
        let appVolume = AppVolumeModel()
        self.appVolume = appVolume
        appVolume.start()

        // The mixer pins whatever app the media card is naming, so the panel
        // cannot show you a track and then leave it out of the list of things
        // you can turn down — see `NowPlayingPin` and `AppVolumeModel.rows`.
        //
        // Here rather than in `NotchController` with the other media callbacks
        // because this one is between the two MODELS, both of which are owned
        // right here and neither of which needs a panel to exist. Weak, so the
        // direction of ownership stays this file's alone; the seed covers the
        // gap before the first `refresh()` lands.
        appVolume.playingBundleID = media.nowPlayingBundleID
        media.onNowPlayingChanged = { [weak appVolume] bundleID in
            appVolume?.playingBundleID = bundleID
        }

        let sound = SoundWidgetModel()
        self.sound = sound

        let calendarWidget = CalendarWidgetModel()
        self.calendarWidget = calendarWidget
        calendarWidget.start()

        let batteryWidget = BatteryWidgetModel()
        self.batteryWidget = batteryWidget
        batteryWidget.start()

        let systemWidget = SystemStatsWidgetModel()
        self.systemWidget = systemWidget
        systemWidget.start()

        let appearance = NotchAppearanceModel()
        self.appearance = appearance

        // Claude's usage figures reach the Agents tab through its status line,
        // and one status line is all Claude has — so another tool writing that
        // setting silently ends them. This puts ours back when the figures are
        // switched on, and takes it out when they are switched off. It never
        // installs hooks, and it cannot stop the launch. See `UsageConnection`.
        let usageConnection = UsageConnectionModel()
        self.usageConnection = usageConnection
        switch usageConnection.sync(wantsUsage: appearance.showsClaudeUsage) {
        case .connected:
            Log.app.notice("put Airlock's usage bridge back into Claude's status line")
        case .disconnected:
            Log.app.notice("took Airlock's usage bridge out of Claude's status line — the figures are off")
        case .failed(let why):
            Log.app.error("could not update Claude's status line — \(why, privacy: .private)")
        case .none:
            break
        }

        let trayWidget = TrayModel()
        self.trayWidget = trayWidget
        trayWidget.start()

        let clipboardWidget = ClipboardWidgetModel()
        self.clipboardWidget = clipboardWidget
        clipboardWidget.plan = { [weak license] in license?.entitlement.limits }
        clipboardWidget.start()

        let dictation = DictationModel()
        dictation.media = media
        self.dictation = dictation

        // Answering a spoken question when nothing editable is focused. The
        // dictation model holds a weak reference so the routing probe knows
        // whether asking is even on the table.
        let assistant = AssistantModel()
        self.assistant = assistant
        dictation.assistant = assistant
        // The screen guide (prototype). Inert unless switched on in the
        // hidden Settings section; the two models reach it only to ask
        // whether it is on and, if so, to hand it a goal.
        #if AIRLOCK_GUIDE
        let guide = GuideController.shared
        self.guide = guide
        dictation.guide = guide
        assistant.guide = guide
        #endif
        // Which languages the app-name scan should read bundle localizations
        // for: the languages that will actually be SPOKEN, which is what the
        // dictation locale settings are. English is dropped — the on-disk
        // bundle name already is English — and an unset primary means the
        // system language, exactly as `DictationModel.prepare` resolves it.
        assistant.spokenLanguageCodes = { [weak dictation] in
            guard let dictation else { return [] }
            let identifiers = [dictation.localeIdentifier.isEmpty
                                   ? Locale.current.identifier
                                   : dictation.localeIdentifier,
                               dictation.secondaryLocaleIdentifier]
            var codes: Set<String> = []
            for identifier in identifiers where !identifier.isEmpty {
                if let code = Locale(identifier: identifier).language.languageCode?.identifier {
                    codes.insert(code)
                }
            }
            codes.remove("en")
            return codes.sorted()
        }
        // Read through self: the agents model is made later in launch.
        assistant.offersAgentHandOff = { [weak self] in self?.agentsWidget?.isEnabled ?? false }
        assistant.onEscalate = { [weak model] question in
            // The same path the quick-prompt bar uses: a fresh Claude Code
            // session in a new terminal, carrying the question.
            guard let model else { return }
            Task { await model.submitQuickPrompt(question) }
        }
        // A dictation with nowhere to land. Same write path as the assistant's
        // Copy, so history suppression is defined once.
        dictation.onCopyTranscript = { [weak clipboardWidget] text in
            clipboardWidget?.suppressNextCopy(of: text)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // Questions about past calls are answered from them while call notes
        // are on, and a source under the answer opens the call at that moment.
        assistant.callNotesEnabled = { [weak model] in model?.meetings.isEnabled ?? false }
        assistant.onShowCall = { [weak model] source in
            model?.meetings.showCall(folder: source.folder, saidAt: source.time)
        }
        // Setup commands go to a VISIBLE terminal the user owns — never run
        // silently in-process. They read it, watch it, and can stop it.
        assistant.onRunInTerminal = { [weak model] command in
            model?.runInTerminal(command)
        }
        assistant.onCopy = { [weak clipboardWidget] text in
            // Tell history to ignore this write BEFORE making it — the poll can
            // fire either side of it.
            clipboardWidget?.suppressNextCopy(of: text)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        // Spoken actions. Assembled here because Core may not reach into the
        // widget models, and the widget models are the only things that know
        // what exists right now.
        //
        // `agentSessions` is left EMPTY, and it is the only field that is.
        // Naming a running session makes `VoiceAgentAction` target it, and the
        // card then reads "Ask airlock: run the tests" — a promise nothing here
        // can keep, because putting text into a session somebody already owns
        // is something `TerminalJumpService` twice says it will not do. With the
        // list empty every spoken instruction proposes a fresh session, which is
        // both what the card says and what happens. See
        // `VoicePerformer.sendToExistingSession`.
        // `weak assistant` matters: this closure is STORED ON `assistant`, so a
        // strong capture is a cycle. It reads two caches that live there.
        assistant.contextProvider = { [weak audioOutput, weak clipboardWidget, weak assistant] in
            VoiceContext(
                audioOutputs: audioOutput?.devices ?? [],
                // Two departures from what the panel renders, both required by
                // what `VoiceClipboardAction` says it is given.
                //
                // Not `ClipboardWidgetModel.items`: that is the panel's FILTERED
                // view, so a search term left in the field would silently narrow
                // what a spoken phrase can find.
                //
                // Re-sorted newest-first: `history.items` is pinned-first,
                // because that is the useful order to look at. Spoken phrases
                // address this list by recency — "the last thing I copied", "the
                // third thing I copied" — and `VoiceClipboardAction` resolves
                // ties by position on exactly that assumption. Handing it a
                // pinned row as "the last thing I copied" would be wrong in the
                // one way nobody would think to check.
                clipboard: (clipboardWidget?.history.items ?? [])
                    .sorted { $0.copiedAt > $1.copiedAt },
                // The cache, never a fresh enumeration: this closure runs on the
                // main actor at the moment of asking, and spawning a subprocess
                // there is exactly the hesitation the pre-warm on key-down
                // exists to avoid. Stale by at most a minute, and a name that
                // has since gone away fails at `perform` rather than silently.
                shortcuts: assistant?.shortcutNames ?? [],
                apps: assistant?.appTargets ?? [],
                sites: assistant?.siteAliases ?? [],
                volume: audioOutput?.volume.map(Double.init))
        }
        let voicePerformer = VoicePerformer(
            copyClipboardItem: { [weak clipboardWidget] id in
                clipboardWidget?.recopy(id: id) == true
            },
            selectAudioOutput: { [weak audioOutput] uid in
                guard let device = audioOutput?.devices.first(where: { $0.uid == uid })
                else { return false }
                audioOutput?.select(device)
                return true
            },
            startSession: { [weak model] text in
                guard let model,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return false }
                // The same path the quick-prompt bar and the escalation use: a
                // new terminal running `claude`, carrying the prompt.
                Task { await model.submitQuickPrompt(text) }
                return true
            },
            runShortcut: { name in
                // Not re-resolved against the cached list first, deliberately:
                // the cache is up to a minute old, and refusing a Shortcut that
                // exists because our copy of the library is stale would be worse
                // than handing the name to the CLI and letting it decide.
                ShortcutsService.launch(name)
            },
            setVolume: { [weak audioOutput] level in
                // Nil `volume` means the current device has no software volume
                // — HDMI and many USB interfaces — and saying so beats a card
                // that claims to have moved something that cannot move.
                guard let audioOutput, audioOutput.volume != nil else { return false }
                audioOutput.setVolume(Float(level))
                return true
            },
            media: { [weak media, weak dictation] command in
                // Read BEFORE cancelling, or the answer is always false.
                let dictationPaused = dictation?.pausedPlaybackForHold ?? false
                // Then cancel: dictation resumes playback after a hold, which
                // would undo this the instant it succeeded. This is what makes
                // `.alreadyThere` an honest answer for `.pause` rather than a
                // command that silently loses to a resume half a second later.
                dictation?.forgetPausedMusic()

                switch MediaCommandPlan.decide(command: command,
                                               isPlaying: media?.state?.isPlaying,
                                               dictationPaused: dictationPaused) {
                case .noPlayer:
                    // Saying so beats a card that claims to have paused silence.
                    return false
                case .alreadyThere:
                    return true
                case .toggle:
                    guard let media else { return false }
                    switch command {
                    case .play, .pause: media.togglePlay()
                    case .next: media.next()
                    case .previous: media.previous()
                    }
                    return true
                }
            },
            open: { target in
                InstalledApps.open(target)
            })
        assistant.onPerform = { voicePerformer.perform($0) }

        dictation.onChooseInput = { [weak self] in self?.appWindow?.show(anchor: .microphoneInput) }
        assistant.onRecordGate = { [weak model] request, outcome, _ in
            // `agent: "voice"` — a free string on `GateRecord`, so the log reads
            // back as what it was without pretending a session existed.
            model?.record(GateRecord(request: request, outcome: outcome,
                                     agent: "voice", decidedAt: Date()))
        }
        assistant.onAlwaysAllow = { rule in
            do {
                // Global, not project: a spoken action has no working directory.
                _ = try PolicyStore().appendAllowRule(rule, projectRoot: nil)
            } catch {
                Log.policy.error("failed to persist spoken rule — \(error.localizedDescription, privacy: .private)")
            }
        }

        // Follows the sessions' working directories, so the git rows describe
        // exactly the checkouts agents are in.
        let repositoryWidget = RepositoryWidgetModel()
        self.repositoryWidget = repositoryWidget

        license.start()
        watchPlanLimits()
        watchPlan()
        // Meeting notes online ask the licence server with the licence's
        // token, on a plan that writes them (`PlanLimits.writesNotesOnline`).
        let cloudNotes = CloudNotesService.shared
        cloudNotes.plan = { [weak license] in license?.entitlement.snapshot ?? .free }
        cloudNotes.access = { [weak license] in license?.notesAccess }
        cloudNotes.hasServer = { [weak license] in license?.hasServer ?? false }
        cloudNotes.start()

        // Reads every integration's hook status once, here, rather than from a
        // SwiftUI body — see `AgentsWidgetModel.hookStatuses`.
        // Before the widgets: `AppModel` and `DictationModel` both raise counts
        // through it, and a store handed over after the first approval would
        // start life already wrong.
        let tally = UsageTallyStore()
        self.tally = tally
        model.tally = tally
        dictation.tally = tally

        let agentsWidget = AgentsWidgetModel()
        self.agentsWidget = agentsWidget
        // For the Agents tab's "Claude usage stopped" card.
        agentsWidget.usage = usageConnection
        agentsWidget.wantsUsage = { [weak appearance, weak agentsWidget] in
            (appearance?.showsClaudeUsage ?? false) && (agentsWidget?.isEnabled ?? false)
        }
        // Registers the gate hotkey. The controller wires `onGateHotkey` when it
        // is built below; a press before then finds a nil handler and does
        // nothing, which is the right nothing.
        agentsWidget.start()

        // Array order is panel order WITHIN a placement; which strip a widget
        // lands in is the widget's own `placement`, and which tab its `tab`.
        let systemControls = SystemControlsModel()
        self.systemControls = systemControls
        systemControls.start()

        WidgetArrangement.applyDashboardLayoutOnce()
        WidgetArrangement.applyHomeSoundLayoutOnce()
        var widgets: [any NotchWidget] = [
            AgentsWidget(model: model, agents: agentsWidget),
            RepositoryWidget(repository: repositoryWidget),
            CalendarWidget(calendar: calendarWidget,
                           onChooseCalendars: { [weak self] in self?.appWindow?.show(anchor: .calendars) }),
            CallsWidget(meetings: model.meetings),
        ]
        #if AIRLOCK_GUIDE
        // Above the banner: with the guide on, asking is what Home is for.
        widgets.append(AskWidget(dictation: dictation, assistant: assistant,
                                 onType: { [weak self] in self?.notch?.toggleCommandBar() },
                                 onOpenSettings: { [weak self] in self?.appWindow?.show(anchor: .commandBar) }))
        #endif
        widgets += [
            // Order inside a placement is panel order, and the banner is the
            // headline: it sits above the rail, not under it.
            MediaWidget(media: media),
            SystemControlsWidget(controls: systemControls),
            KeyMapWidget(dictation: dictation, clipboard: clipboardWidget, agents: agentsWidget),
            SoundWidget(sound: sound, output: audioOutput, appVolume: appVolume),
            BatteryWidget(battery: batteryWidget),
            SystemStatsWidget(system: systemWidget),
            TrayWidget(tray: trayWidget),
            ClipboardWidget(clipboard: clipboardWidget),
        ]
        let registry = WidgetRegistry(widgets: widgets)
        let notch = NotchController(model: model, media: media, calendar: calendarWidget,
                                    battery: batteryWidget, system: systemWidget, tray: trayWidget,
                                    clipboard: clipboardWidget, dictation: dictation,
                                    assistant: assistant, appearance: appearance,
                                    agents: agentsWidget, audioOutput: audioOutput,
                                    sound: sound, appVolume: appVolume,
                                    systemControls: systemControls,
                                    repository: repositoryWidget, license: license,
                                    registry: registry)
        self.notch = notch
        // What is set up, for the once-a-day count. Read when it is sent,
        // never stored.
        UsageCounts.shared.daySnapshot = { [weak license, weak agentsWidget, weak dictation, weak model] in
            .dayActive(plan: license?.entitlement.plan ?? .free,
                       widgetsOn: registry.widgets.filter { $0.isToggleable && $0.isEnabled }.count,
                       agentsConnected: agentsWidget?.connection.connected.count ?? 0,
                       dictationOn: dictation?.isEnabled ?? false,
                       callNotesOn: model?.meetings.isEnabled ?? false,
                       crashReportsOn: CrashReporter.shared.isEnabled)
        }
        // Card C4's scripted check, on the packaged app:
        //   open /Applications/Airlock.app --args --frame-loop 200
        // Started after a few seconds so the island has settled from launch.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--frame-loop") {
            let cycles = arguments.dropFirst(flag + 1).first.flatMap(Int.init) ?? 200
            Task { @MainActor [weak notch] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await notch?.runFrameLoop(cycles: cycles)
            }
        }

        // Constructed here, STARTED after the windows exist — see below. Nothing
        // reaches the network until `start()`, so building it early only means
        // the About pane has something to bind its switch to.
        let updater = UpdaterModel()
        self.updater = updater

        // One SettingsModel, two windows. Onboarding installs hooks through it,
        // so sharing is what keeps the settings window from disagreeing with
        // what the user just did in the first-run window.
        let settingsModel = SettingsModel(projectRoots: { [weak model] in
            model?.sessions.compactMap(\.cwd) ?? []
        })
        self.settingsModel = settingsModel
        // Installing hooks is what turns the agent surfaces on for someone who
        // came for the clipboard and stayed for the agents — so the derived
        // default has to be re-read the moment an install lands, not next launch.
        settingsModel.onHookStatusChange = { [weak agentsWidget, weak usageConnection, weak appearance] in
            agentsWidget?.refreshFromHooks()
            // Hooks arriving are also what makes the usage bridge possible.
            // Without this it would wait for the next launch, and the pane that
            // just said "not connected" would go on saying it.
            usageConnection?.sync(wantsUsage: appearance?.showsClaudeUsage ?? false)
        }
        settingsModel.onOpenPastCalls = { [weak model] in model?.meetings.showPastCalls() }
        // The day-one card installs hooks without going through Settings.
        agentsWidget.onHooksInstalled = { [weak usageConnection, weak appearance] in
            usageConnection?.sync(wantsUsage: appearance?.showsClaudeUsage ?? false)
        }
        appWindow = AirlockWindowController(model: settingsModel, media: media,
                                             sound: sound, appVolume: appVolume,
                                             calendar: calendarWidget,
                                             assistant: assistant,
                                             battery: batteryWidget, system: systemWidget,
                                             tray: trayWidget, clipboard: clipboardWidget,
                                             dictation: dictation, appearance: appearance,
                                             agents: agentsWidget, repository: repositoryWidget,
                                             license: license, updater: updater,
                                             usage: usageConnection,
                                             controls: systemControls,
                                             usageAlerts: model.usageAlerts)
        // The calls are a page of the same window: the island's "Show",
        // "Call Notes…" and a call's notification all land there.
        appWindow?.calls = model.meetings.callsPage
        notch.onOpenSettings = { [weak self] in self?.appWindow?.show() }
        appWindow?.islandPreview = { [weak notch] in notch?.preview() ?? AnyView(EmptyView()) }
        #if AIRLOCK_GUIDE
        self.guide?.onOpenSettings = { [weak self] in self?.appWindow?.show(pane: .general) }
        #endif

        // Clicking a notification lands on the pane that fixes what it reported.
        //
        // The delegate is set here, alongside the window controller it needs,
        // rather than at the top of launch: Apple asks for it before the app
        // finishes launching, and this runs inside
        // `applicationDidFinishLaunching` well before any notification of ours
        // can be posted — every one of them is raised by a user action later.
        // A run with no app bundle has no center, and skips this.
        Notifications.center()?.delegate = notificationRouter
        Notifications.openSettings = { [weak self] pane, anchor in
            if let anchor { self?.appWindow?.show(anchor: anchor) } else { self?.appWindow?.show(pane: pane) }
        }
        // "Call notes ready" lands on that call's notes.
        Notifications.openCall = { [weak model] folder in model?.meetings.showCall(folder: folder) }

        // Settings › Plans, never "whatever Settings page was open last": from
        // the notch's cards, the call notes' plan buttons and the overdue line.
        license.onShowPlans = { [weak self] keyField in
            if keyField { self?.appWindow?.show(anchor: .licenceKey) } else { self?.appWindow?.show(pane: .license) }
        }
        model.meetings.onShowPlans = { [weak license] in license?.showPlans(from: "call_notes") }

        // Free's reminders hear what the plan let go as it happens, and wait
        // for the panel to open: never during a call, never over a question.
        let reminders = license.reminders
        // Usage counts hear them too, by the name of the row in `PlanLimits`.
        clipboardWidget.onCopiesLetGo = { [weak reminders] count in
            reminders?.copiesLetGo(count)
            UsageCounts.shared.recordOnceADay(.freeLimitHit("clipboard_shows"), key: "clipboard_shows")
        }
        model.onPassedOver = { [weak reminders] asking, answering in
            reminders?.agentAskedInTerminal(asking: asking, answering: answering)
            UsageCounts.shared.record(.freeLimitHit("one_agent_at_a_time"))
        }
        model.meetings.onNotesStopped = { [weak reminders] in
            reminders?.notesStopped()
            UsageCounts.shared.record(.freeLimitHit("notes_listen_for"))
        }
        reminders.callOn = { [weak model] in
            guard let model else { return false }
            return model.calls.call != nil || (model.meetings.isEnabled && model.meetings.inPersonCall != nil)
        }
        reminders.agentAsking = { [weak model] in
            model?.sessions.contains { session in
                let status = SessionCardText.pillStatus(of: session)
                return status == .needsAttention || status == .waitingQuestion
            } ?? false
        }
        reminders.listenToTheIsland()

        let onboardingModel = OnboardingModel(settings: settingsModel, calendar: calendarWidget,
                                              dictation: dictation, clipboard: clipboardWidget,
                                              assistant: assistant, agentsWidget: agentsWidget)
        onboardingModel.onReveal = { [weak notch] in notch?.reveal() }
        onboarding = OnboardingWindowController(model: onboardingModel)
        self.onboardingModel = onboardingModel
        #if AIRLOCK_GUIDE
        let welcomeModel = WelcomeModel(agentsWidget: agentsWidget,
                                        dictation: dictation, assistant: assistant,
                                        hookStatuses: settingsModel.agents.map(\.status))
        welcomeModel.onReveal = { [weak notch] in notch?.reveal() }
        welcomeModel.onConnectAgents = { [weak self] in self?.connectAgentsAfterWelcome() }
        welcome = WelcomeWindowController(model: welcomeModel)
        #endif

        // After the windows exist: a first-run update prompt must not race the
        // onboarding wizard for the screen.
        updater.start()

        dictation.start() // after the controller, so the listening hook is wired
        assistant.prepare()
        presentDemoAnswerIfAsked(assistant)
        speakIfAsked(assistant)
        #if AIRLOCK_GUIDE
        previewGuideMotionIfAsked()
        #endif
        installStatusItem()
        // Before any window can open, since a window is where its shortcuts are
        // wanted.
        installMainMenu()

        // Argument as well as environment, for the same reason `--onboarding`
        // has both: `open` passes `--args` but drops the shell environment, so
        // the env form never reaches a bundled launch.
        if ProcessInfo.processInfo.environment["AIRLOCK_OPEN_SETTINGS"] != nil
            || ProcessInfo.processInfo.arguments.contains("--settings") {
            appWindow?.show()
        }
        // After the windows exist, so "Open Settings" has something to open —
        // and before onboarding, which a migrated install will not see anyway.
        presentPermissionNoticeIfNeeded()
        let firstRun = presentOnboardingIfNeeded(settingsModel)
        let whatsNew = presentWhatsNewIfNeeded(isFirstRun: firstRun)
        let usageQuestion = presentUsageQuestionIfNeeded(panelTaken: firstRun || whatsNew)
        presentCrashQuestionIfNeeded(panelTaken: firstRun || whatsNew || usageQuestion)
    }

    /// The question about usage counts, once, for a copy that finished setup
    /// before counts existed (`UsageCounts.hasQuestionWaiting`); a new copy is
    /// asked on setup's first screen. Never over setup or a new version's
    /// card: "Got it" on that card brings it up instead
    /// (`NotchController.whatsNewGotIt`). Forced with `--args
    /// --usage-question`, which never marks it asked.
    /// - Returns: whether the question is now on screen.
    private func presentUsageQuestionIfNeeded(panelTaken: Bool) -> Bool {
        guard !Self.isDemoMode, NotchScreen.target != nil else { return false }
        if ProcessInfo.processInfo.arguments.contains("--usage-question") {
            notch?.showUsageQuestion(remember: false)
            return true
        }
        guard !panelTaken, UsageCounts.shared.hasQuestionWaiting else { return false }
        notch?.showUsageQuestion(remember: true)
        return true
    }

    /// The question about crash reports, after a run that ended unexpectedly
    /// (`CrashReporter.hasQuestionWaiting`). Last, and never over setup or a
    /// new version's card: it stays waiting for a launch that has the panel
    /// to itself. Forced with `--args --crash-question`, which never marks
    /// it asked, so it can be looked at in any build.
    private func presentCrashQuestionIfNeeded(panelTaken: Bool) {
        guard !Self.isDemoMode, NotchScreen.target != nil else { return }
        if ProcessInfo.processInfo.arguments.contains("--crash-question") {
            notch?.showCrashQuestion(remember: false)
            return
        }
        guard !panelTaken, CrashReporter.shared.hasQuestionWaiting else { return }
        notch?.showCrashQuestion(remember: true)
    }

    /// A new version's card, once (`WhatsNew`). After setup, which it never
    /// shows on top of: a new user is told the version is seen instead.
    /// Forced with `--args --whats-new` or `--whats-new-sample`, which never
    /// mark it seen.
    /// - Returns: whether the card is now on screen.
    @discardableResult
    private func presentWhatsNewIfNeeded(isFirstRun: Bool) -> Bool {
        guard !Self.isDemoMode else { return false }
        let forced = WhatsNewLaunch.forcedCard
        guard let card = forced ?? WhatsNewLaunch.cardForLaunch(isFirstRun: isFirstRun) else { return false }
        // No panel to open (a shut lid with the monitor fallback off): left
        // unseen, so the next launch with a panel shows it.
        guard NotchScreen.target != nil, let notch else { return false }
        notch.showWhatsNew(card, remember: forced == nil)
        return true
    }

    /// Sample sessions instead of live ones, and no first-run wizard in the way.
    ///
    /// Argument as well as environment, for the reason recorded on
    /// `--onboarding`: `open` passes `--args` but drops the shell environment,
    /// so the env form alone is unreachable in a packaged build — which is
    /// where the panel is worth looking at.
    static var isDemoMode: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["AIRLOCK_DEMO"] != nil
            || process.arguments.contains("--demo")
    }

    /// Stand an answer up at launch, so the panel state a gate used to be
    /// invisible in can be looked at in a packaged build.
    ///
    /// Both forms for the reason `--onboarding` has both: `open` goes through
    /// LaunchServices, which passes `--args` but drops the shell environment, so
    /// the env form never reaches a bundle. And a bundle is the only place worth
    /// checking this — see `AssistantModel.presentDemoAnswer`.
    ///
    ///   open output/package/Airlock.app --args --demo --demo-answer
    ///
    /// Then Seed Demo Session in the status menu puts a gate behind it — which
    /// is why `--demo` is on that line as well: the item only exists in a demo
    /// run, and pairing them is what CLAUDE.md documents anyway.
    private func presentDemoAnswerIfAsked(_ assistant: AssistantModel) {
        let process = ProcessInfo.processInfo
        guard process.environment["AIRLOCK_DEMO_ANSWER"] != nil
            || process.arguments.contains("--demo-answer") else { return }
        assistant.presentDemoAnswer(
            question: "What's the difference between a rebase and a merge?",
            answer: "A merge keeps both histories and adds a commit that joins "
                + "them. A rebase replays your commits on top of the other "
                + "branch, so the history stays linear — at the cost of "
                + "rewriting the commits you replayed.")
    }

    /// Speak a phrase without speaking it.
    ///
    ///   open output/package/Airlock.app --args --say "put the sound on the airpods"
    ///
    /// Runs the REAL path — the classifier, your real audio devices, your real
    /// `policy.yaml` — and stops exactly where a spoken phrase would, at the
    /// card. Deliberately not a canned proposal like `--demo-answer`: a
    /// synthetic card proves the view renders and proves nothing about whether
    /// the phrase reaches it, which is the half that can actually be broken.
    ///
    /// Argument form only, and `--args` is why: `open` goes through
    /// LaunchServices, which passes arguments and drops the shell environment.
    private func speakIfAsked(_ assistant: AssistantModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--say"),
              arguments.index(after: flag) < arguments.endIndex else { return }
        let phrase = arguments[arguments.index(after: flag)]
        // After a beat, so the audio device list has been enumerated — a
        // classifier run against an empty context resolves to nothing and would
        // look exactly like a classifier that failed.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            assistant.ask(phrase)
        }
    }

    #if AIRLOCK_GUIDE
    /// Play the guide's pretend task a moment after launch, the one Settings'
    /// Motion → Preview plays, so the motion can be looked at in a packaged
    /// build without clicking through to the hidden section.
    ///
    ///   open output/package/Airlock.app --args --guide-motion-preview
    private func previewGuideMotionIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--guide-motion-preview") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            GuideMotionPreview.play()
        }
    }
    #endif

    /// The app is `LSUIElement`, so a launch that opens nothing looks to a new
    /// user exactly like a launch that failed. This is the one moment where
    /// interrupting unasked is the kind thing to do.
    ///
    /// It interrupts *in the panel*. Step one's whole job is "the app is up
    /// there", and a window explaining the notch is still explaining it
    /// somewhere else — where the panel wizard is the thing it is describing,
    /// with the tab strip live above it. The menu bar's "Set up Airlock…" opens
    /// it there too; the window is only the fallback below.
    ///
    /// Skipped under demo mode, which exists for screenshots and dev runs where
    /// a wizard is purely in the way.
    /// - Returns: whether setup opened.
    @discardableResult
    private func presentOnboardingIfNeeded(_ settingsModel: SettingsModel) -> Bool {
        let process = ProcessInfo.processInfo
        guard !Self.isDemoMode else { return false }
        settingsModel.refresh()
        // Forced two ways because the honest path to seeing this window is to be
        // a new user, and the developer never is. The argument form is the one
        // that works on a bundle — `open` goes through LaunchServices, which
        // passes `--args` but drops the shell environment:
        //   open output/package/Airlock.app --args --onboarding
        let forced = process.environment["AIRLOCK_ONBOARDING"] != nil
            || process.arguments.contains("--onboarding")
        #if AIRLOCK_GUIDE
        // The guide's welcome window, on request only. A first run is the
        // setup in the notch on every copy, the guide's included: the owner
        // preferred it to a window in the middle of the screen (2026-10-08).
        //   open output/package/Airlock.app --args --welcome
        if process.arguments.contains("--welcome") {
            welcome?.show()
            return true
        }
        #endif
        guard forced || OnboardingModel.shouldPresentAtLaunch(settings: settingsModel)
        else { return false }
        // Falls back to the window if there is no panel to run in — a shut lid
        // with the external-display fallback off leaves nowhere to draw, and a
        // first run that silently does nothing is the exact failure this
        // function exists to prevent.
        onboardingModel?.beganFirstRun()
        if let onboardingModel, NotchScreen.target != nil {
            notch?.beginOnboarding(onboardingModel)
        } else {
            onboarding?.show()
        }
        return true
    }

    #if AIRLOCK_GUIDE
    /// "Yes, I do" in the welcome: the setup wizard, straight to connecting
    /// agents, in the panel as a first run would show it.
    private func connectAgentsAfterWelcome() {
        guard let onboardingModel else { return }
        onboardingModel.continueFromWelcome()
        if NotchScreen.target != nil {
            notch?.beginOnboarding(onboardingModel)
        } else {
            onboarding?.show()
        }
    }
    #endif

    /// Brings an agentic-notch install across to Airlock.
    ///
    /// Copies rather than moves, and never overwrites — see `IdentityMigration`.
    /// The legacy directories stay exactly where they are, so a user who hits a
    /// problem still has every byte of their old state.
    ///
    /// Hooks are handled by `refreshStagedHook` immediately afterwards rather
    /// than here: the installers recognise commands under BOTH identities, so an
    /// existing install still reads as installed, and restaging rewrites it to
    /// `~/.airlock/bin/airlock-hook`. Copying `~/.agentic-notch/bin` across is
    /// not enough — the binary inside it has been renamed, and the command in
    /// settings.json still names the old one.
    private func migrateFromLegacyIdentity() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")

        let candidates = IdentityMigration.standardCandidates(
            home: home, applicationSupport: support)
        let plan = IdentityMigration.plan(candidates: candidates) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let copied = IdentityMigration.perform(plan)
        if !copied.isEmpty {
            Log.migration.notice(
                "migrated \(copied.count, privacy: .public) director\(copied.count == 1 ? "y" : "ies", privacy: .public) from agentic-notch")
        }

        // Preferences follow the bundle identifier, so the new identity starts
        // with none of them — every toggle back to default, and the wizard again
        // for someone who finished it months ago.
        let moved = IdentityMigration.migrateDefaults(
            fromDomain: IdentityMigration.Legacy.bundleIdentifier, into: .standard)
        if moved > 0 { Log.migration.notice("carried over \(moved, privacy: .public) preference(s)") }

        // Only when something actually came across. A genuinely new install has
        // nothing to re-grant and must never be shown the notice.
        if !copied.isEmpty || moved > 0 {
            IdentityMigration.flagPermissionReview(in: .standard)
        }

        repointLegacyHooks()
    }

    /// Says out loud that the rename reset macOS permissions.
    ///
    /// Justified in an `LSUIElement` app for the same reason the first-run window
    /// is: the alternative is four unrelated features going quiet at once with
    /// nothing on screen connecting them. The calendar simply shows no events —
    /// which is how this was actually reported, as "not syncing properly" rather
    /// than as a permission problem, because that is genuinely what it looks
    /// like.
    ///
    /// Shown once and then cleared whatever the answer is, including "Later".
    /// A window of Airlock's own rather than a system alert: it names every
    /// permission Settings lists (`PermissionsAgainView`).
    private func presentPermissionNoticeIfNeeded() {
        guard IdentityMigration.needsPermissionReview(in: .standard) else { return }
        IdentityMigration.clearPermissionReview(in: .standard)

        let notice = PermissionsAgainWindowController()
        permissionsAgain = notice
        notice.show(guideOn: SettingsPane.guideIsOn) { [weak self] in
            self?.appWindow?.show(pane: .permissions)
        }
    }

    /// Rewrites hook commands that still name the old binary.
    ///
    /// Copying state is not enough, and this is the failure it would otherwise
    /// leave behind: the installed command still says
    /// `~/.agentic-notch/bin/agentic-notch-hook`, and that file still exists and
    /// still runs. It is the OLD binary, so it connects to the OLD socket path —
    /// which nothing is listening on any more. Every hook would fire, succeed,
    /// and reach nobody. Silent, and indistinguishable from the app being shut.
    ///
    /// Goes through the ordinary installer, so managed entries are replaced
    /// rather than duplicated, and the status-line chain is preserved exactly as
    /// a normal reinstall preserves it.
    private func repointLegacyHooks() {
        guard let source = HookBinaryStager.locateSourceHook(near: Bundle.main.executableURL),
              let staged = try? HookBinaryStager.stage(from: source) else { return }

        // The Claude status line first, because nothing else reaches it. It is
        // installed by the setup CLI rather than by an `AgentIntegration`, so
        // the registry loop below walks straight past it — which left it the one
        // entry in settings.json still naming the old binary after everything
        // else had been re-pointed. It feeds the rate-limit figures, so a stale
        // one keeps writing usage into the old Application Support directory and
        // the KPI in the notch quietly ages out.
        //
        // `install` re-reads and preserves whatever status line was chained, so
        // this is the same operation a normal reinstall performs.
        let statusLine = ClaudeStatusLineInstaller()
        if statusLine.isInstalled(),
           let text = try? String(contentsOf: statusLine.configURL, encoding: .utf8),
           text.contains(IdentityMigration.Legacy.hookBinary) {
            do {
                try statusLine.install(bridgeBinaryPath: staged.path)
                Log.app.notice("re-pointed the Claude status line at the renamed binary")
            } catch {
                Log.app.error(
                    "could not re-point the status line — \(error.localizedDescription, privacy: .private)")
            }
        }

        for integration in AgentRegistry.shared.all {
            let installer = integration.installer
            guard installer.status() == .installed,
                  let text = try? String(contentsOfFile: installer.configPath, encoding: .utf8),
                  text.contains(IdentityMigration.Legacy.hookBinary) else { continue }
            do {
                try installer.install(hookBinaryPath: staged.path)
                Log.app.notice(
                    "re-pointed \(integration.kind.displayName, privacy: .public) hooks at the renamed binary")
            } catch {
                // Fail open, like the hooks themselves: a stale hook reaches
                // nothing, which is exactly what an un-migrated install already
                // was. Refusing to launch over it would be worse.
                Log.app.error(
                    "could not re-point \(integration.kind.displayName, privacy: .public) hooks — \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Keeps an installed hook in step with this build, silently.
    ///
    /// No prompt and no button, because which binary the hook command points at
    /// is an implementation detail — there is no version of this a user should
    /// have to think about, and "your hooks are stale" is not a sentence anyone
    /// can act on. It only ever touches a file that already exists.
    ///
    /// Failure is non-fatal by the same logic that makes hooks fail open: a
    /// stale hook still works, and an app that refuses to launch over a file
    /// copy would be worse than the drift it is fixing.
    private func refreshStagedHook() {
        do {
            if try HookBinaryStager.refreshIfInstalled(near: Bundle.main.executableURL) {
                Log.app.notice("refreshed the staged hook binary to match this build")
            }
        } catch {
            Log.app.error("could not refresh the staged hook — \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Subscribes an installed hook to the events added since it was written —
    /// PermissionRequest was the first — silently, for the reason
    /// `refreshStagedHook` is silent: which events Airlock hears is not
    /// something anyone should have to know, let alone fix by reinstalling.
    /// Without it, an install from before an event never hears it.
    ///
    /// After `repointLegacyHooks`, which rewrites a pre-rename install whole.
    /// Only ever adds Airlock's own entries to a file that already has some,
    /// and failure leaves the install working exactly as it did.
    private func upgradeInstalledHooks() {
        let installers = AgentRegistry.shared.all.map { (agent: $0.kind, installer: $0.installer) }
        for outcome in HookUpgrade.run(installers) {
            if let failure = outcome.failure {
                Log.app.error(
                    "could not add new hook events for \(outcome.agent.displayName, privacy: .public) — \(failure, privacy: .private)")
            } else if !outcome.added.isEmpty {
                Log.app.notice(
                    "subscribed \(outcome.agent.displayName, privacy: .public) hooks to \(outcome.added.joined(separator: ", "), privacy: .public)")
            }
        }
    }

    /// The menu bar mark: the app icon reduced to what survives at 18 points.
    ///
    /// It replaces a literal `◐` character left over from the scaffold, which
    /// read as a half-filled circle because that is exactly what it was — a
    /// placeholder nobody had gone back for.
    ///
    /// **A template image, not a coloured one.** `isTemplate` hands macOS the
    /// alpha and lets it do the tinting, which is the only way the mark stays
    /// right in a light menu bar, a dark one, and inverted while the menu is
    /// open. A drawn-in-cyan icon would be correct in exactly one of those.
    ///
    /// The menu bar mark: the bloub, eyes knocked OUT rather than filled over.
    ///
    /// **This is the one place the source artwork's mask actually matters.** In
    /// the panel the eyes are two plain fills, because a template image is the
    /// only surface where that will not do — it carries one colour plus alpha, so
    /// light can exist only as absence. Fill the eyes here and they vanish into
    /// the body the moment macOS tints the image.
    ///
    /// Drawn into a FLIPPED context on purpose. The eye poses are in the source
    /// artwork's space, which is y-down like SwiftUI and unlike AppKit; taking
    /// the default y-up context puts every eye below the centre line instead of
    /// above it, which reads as a different character rather than as a bug.
    ///
    /// `.attentive` because the mark is the app's identity and has to hold one
    /// face: it has the widest eyes of the plausible ones (~1.8pt at this size,
    /// where the chamber's lamp needed 2.1pt to survive antialiasing), and it is
    /// the same face the island wears while a session works, so the menu bar and
    /// the notch agree.
    private static func statusMark() -> NSImage {
        let size = NSSize(width: 17, height: 17)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Barely inset. The body is landscape (193×167 in source units) so it
            // fills the width and centres in the height on its own.
            let box = rect.insetBy(dx: 0.5, dy: 0.5)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(BloubBody().path(in: box).cgPath)
            context.fillPath()

            context.setBlendMode(.destinationOut)
            context.addPath(BloubEyes(expression: .attentive).path(in: box).cgPath)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Test-only door onto `statusMark()`; the menu bar's own compositing is
    /// the only way to see whether the knockout survived.
    static func statusMarkForPreview() -> NSImage { statusMark() }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.statusMark()
        item.button?.toolTip = "Airlock"
        item.menu = makeStatusMenu()
        statusItem = item
        #if AIRLOCK_GUIDE
        watchGuideForStatusItem()
        #endif
    }

    /// The status item's menu. Built apart from the item so a test can open
    /// it without putting anything in the menu bar.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // No key equivalent. A status-menu one only fires while that menu is
        // already open, so ⌘T here advertised a shortcut the app did not have —
        // and promoting it to a real global hotkey would be worse, since ⌘T is
        // New Tab in every app on this Mac. ⌘, and ⌘Q below are the exception
        // because `installMainMenu` claims them properly.
        menu.addItem(makeItem("Show / Hide Panel", #selector(togglePanel), ""))
        menu.addItem(makeItem("Settings…", #selector(openSettings), ","))
        // Every call's notes, whenever, not only the one the island offers
        // as it ends. Shown only while call notes are on (`menuNeedsUpdate`).
        let callNotes = makeItem("Call Notes…", #selector(openCallNotes), "")
        callNotes.tag = Self.callNotesMenuTag
        menu.addItem(callNotes)
        // Notes of a meeting in the room, with no call, or "Stop Notes"
        // while notes are taken. Same rule as the row above.
        let handNotes = makeItem("Take Notes", #selector(pressNotesButton), "")
        handNotes.tag = Self.handNotesMenuTag
        menu.addItem(handNotes)
        // Notes from a recording somebody already has. Same rule again.
        let addRecording = makeItem("Add Recording…", #selector(addRecording), "")
        addRecording.tag = Self.addRecordingMenuTag
        menu.addItem(addRecording)
        // Findable again on purpose: "walk me through it" is the first thing
        // anyone asks for support, and re-running setup should not require
        // deleting a preference key.
        menu.addItem(makeItem("Setup Guide…", #selector(openOnboarding), ""))
        // Only in a real bundle: `swift run` has nothing to update, and a menu
        // item that cannot work is worse than one that is not there.
        if updater?.isAvailable == true {
            menu.addItem(makeItem("Check for Updates…", #selector(checkForUpdates), ""))
        }
        // Demo runs only. Sample sessions are a screenshot and dev-run tool, and
        // seeding four invented agents into somebody's real notch is not a
        // feature — it shipped in the menu of every packaged build regardless.
        if Self.isDemoMode {
            menu.addItem(makeItem("Seed Demo Session", #selector(seedDemo), "d"))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Airlock", #selector(quit), "q"))
        // Rows that depend on a setting are settled each time the menu opens
        // (`menuNeedsUpdate`).
        menu.delegate = self
        return menu
    }

    /// Marks "Call Notes…", so `menuNeedsUpdate` can find it wherever the
    /// guide's rows have pushed it. Any tag but 0 (every other row) and the
    /// guide's.
    static let callNotesMenuTag = 1

    /// Shows "Call Notes…" only while call notes are on, as the Voice page
    /// shows its call rows only then.
    static func showCallNotes(in menu: NSMenu, when on: Bool) {
        menu.items.first { $0.tag == callNotesMenuTag }?.isHidden = !on
    }

    /// Marks "Take Notes" / "Stop Notes", for `menuNeedsUpdate`.
    static let handNotesMenuTag = 2

    /// Names the notes row after what it does now (`MeetingNotesFlow.handButton`),
    /// and hides it while call notes are off (nil) or the last notes are
    /// still being written.
    static func showHandNotes(in menu: NSMenu, as button: MeetingNotesFlow.HandButton?) {
        guard let item = menu.items.first(where: { $0.tag == handNotesMenuTag }) else { return }
        let title = button.flatMap(handNotesTitle)
        item.isHidden = title == nil
        if let title { item.title = title }
    }

    static func handNotesTitle(_ button: MeetingNotesFlow.HandButton) -> String? {
        switch button {
        case .takeNotes, .takeNotesOfCall: "Take Notes"
        case .stop: "Stop Notes"
        case .busy: nil
        }
    }

    /// Marks "Add Recording…", for `menuNeedsUpdate`.
    static let addRecordingMenuTag = 4

    /// Shows "Add Recording…" only while call notes are on. While one is
    /// being read it says so, and opens the window on it.
    static func showAddRecording(in menu: NSMenu, when on: Bool, reading: Bool) {
        guard let item = menu.items.first(where: { $0.tag == addRecordingMenuTag }) else { return }
        item.isHidden = !on
        item.title = reading ? "Reading a Recording…" : "Add Recording…"
    }

    /// A plan change reaches what it limits at once, not at the next launch:
    /// the clipboard shows or hides its older copies, and the bridge starts or
    /// stops answering one agent at a time. Neither takes away anything open.
    ///
    /// Re-arms itself: `withObservationTracking` fires once per change.
    private func watchPlanLimits() {
        guard let license else { return }
        let limits = withObservationTracking {
            license.entitlement.limits
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchPlanLimits() }
        }
        guard limits != planLimits else { return }
        let first = planLimits == nil
        planLimits = limits
        model?.oneAgentAtATime = limits.oneAgentAtATime
        if !first { clipboardWidget?.planDidChange() }
    }

    /// The plan at the last look, so usage counts hear a change and not the
    /// first read at launch.
    private var countedPlan: AirlockPlan?

    private func watchPlan() {
        guard let license else { return }
        let plan = withObservationTracking {
            license.entitlement.plan
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchPlan() }
        }
        defer { countedPlan = plan }
        guard let before = countedPlan, before != plan else { return }
        UsageCounts.shared.record(.planChanged(from: before, to: plan))
    }

    #if AIRLOCK_GUIDE
    // MARK: - The guide in the menu bar (card 3.08)

    /// Marks the rows `updateGuideRows` owns, so it can take them out again.
    private static let guideMenuTag = 3_08

    /// What the icon shows now, so a session change that leaves the dots
    /// alone does not redraw the menu bar.
    private var statusDots: GuidePresentation.MenuBarDots?

    /// Swaps the cloud for the task's progress dots while a guide is on a
    /// step, and back once it is not. On a Mac with no notch the menu bar is
    /// where a glance goes; with one, the dots repeat the pill's.
    ///
    /// Re-arms itself: `withObservationTracking` fires once per change.
    private func watchGuideForStatusItem() {
        guard let guide else { return }
        let (dots, plan) = withObservationTracking {
            (GuidePresentation.menuBarDots(guide.session), GuidePresentation.plan(guide.session))
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchGuideForStatusItem() }
        }
        guard dots != statusDots else { return }
        statusDots = dots
        guard let button = statusItem?.button else { return }
        if let dots, let plan {
            button.image = Self.progressMark(dots)
            button.toolTip = "Airlock: \(plan.title), step \(plan.number) of \(plan.count)"
        } else {
            button.image = Self.statusMark()
            button.toolTip = "Airlock"
        }
    }

    /// The dots: solid up to this step, rings after. A template, like the
    /// cloud, so the menu bar tints it for light, dark and a selected item.
    private static func progressMark(_ dots: GuidePresentation.MenuBarDots) -> NSImage {
        let diameter: CGFloat = 5, gap: CGFloat = 3, height: CGFloat = 17
        let width = CGFloat(dots.total) * diameter + CGFloat(max(dots.total - 1, 0)) * gap + 2
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for index in 0..<dots.total {
                let x = 1 + CGFloat(index) * (diameter + gap)
                let box = NSRect(x: x, y: (height - diameter) / 2, width: diameter, height: diameter)
                NSColor.black.set()
                if index < dots.filled {
                    NSBezierPath(ovalIn: box).fill()
                } else {
                    let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.6, dy: 0.6))
                    ring.lineWidth = 1.2
                    ring.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The status menu's guide rows, from the guide as it is now: "Stop the
    /// guide" while a task runs, "Ask for help…" while it is on and idle.
    /// Never both — asking mid-task would replace the running one.
    private func updateGuideRows(in menu: NSMenu) {
        for item in menu.items where item.tag == Self.guideMenuTag {
            menu.removeItem(item)
        }
        guard let guide, guide.isEnabled else { return }
        let row = guide.session.isLive
            ? makeItem("Stop the Guide", #selector(stopGuide), "")
            : makeItem("Ask for Help…", #selector(askGuide), "")
        row.tag = Self.guideMenuTag
        let separator = NSMenuItem.separator()
        separator.tag = Self.guideMenuTag
        menu.insertItem(row, at: 0)
        menu.insertItem(separator, at: 1)
    }

    @objc private func askGuide() {
        // The bar is opt-in (`assistant.commandBar.enabled`), and the notch
        // declines it silently when off; the menu sends you to the switch.
        if assistant?.commandBarEnabled == true {
            notch?.toggleCommandBar()
        } else {
            appWindow?.show(anchor: .commandBar)
        }
    }

    @objc private func stopGuide() { guide?.stop() }
    #endif

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// The main menu — drawn in the menu bar only while a full window of ours
    /// is open, and needed at every other moment too.
    ///
    /// `NSApplication` dispatches command-key equivalents through `mainMenu`,
    /// and only through it. With none installed, ⌘V did nothing in ANY text
    /// field the app has: the licence key box whose own copy says "paste it
    /// instead", the policy rule field, both dictation prompt editors. Nothing
    /// was broken about those fields — the command had nowhere to be handled.
    ///
    /// ⌘, and ⌘W come along for free, and the second one was a stated promise:
    /// `OnboardingWindowController` counts ⌘W as one of the ways its window
    /// closes.
    ///
    /// It changes nothing about activation. At rest the policy is
    /// `.accessory` and no menu bar is drawn; while a full window is open or
    /// minimised Airlock is an ordinary app and these menus are in the menu
    /// bar (`DockPresenceController`). The notch panel remains a
    /// non-activating panel either way, so its shortcuts reach this menu only
    /// while it holds the keyboard for typing.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Airlock")
        appMenu.addItem(makeItem("Settings…", #selector(openSettings), ","))
        appMenu.addItem(makeItem("Setup Guide…", #selector(openOnboarding), ""))
        appMenu.addItem(.separator())
        // No Hide item, and therefore no ⌘H. Hiding is safe now: every panel
        // that must stay (the notch, the drop catcher, the window beside a
        // live call, the guide's overlays) has `canHide = false`, because
        // `NSApplication.hide(_:)` orders out every window that allows it and
        // the kit's state machine never orders its panel back in. And the
        // Dock icon offers Hide whenever there is a window to hide. A ⌘H here
        // would add only a way to hide the windows from inside the notch,
        // whose search field takes the keyboard while you are in another app.
        appMenu.addItem(makeItem("Quit Airlock", #selector(quit), "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // Untargeted on purpose: these travel the responder chain to whatever
        // field editor is first responder, which is the only thing that knows
        // what "copy" means right now.
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        edit.addItem(NSMenuItem(title: "Select All",
                                action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close",
                                  action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimise",
                                  action: #selector(NSWindow.performMiniaturize(_:)),
                                  keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)

        // Not handed to AppKit as `windowsMenu`: that would have it keep a list
        // of our windows in there, and the notch panel is not a window anyone
        // should be offered by name. The two shortcuts are the whole point.
        NSApp.mainMenu = main
    }

    /// Every quit comes through here, whichever menu, key or Dock item
    /// started it. While call notes are being taken it asks first
    /// (`QuitQuestion`); at any other time it says yes at once, as it always
    /// has.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitQuestion.reply(takingNotes: model?.meetings.takingNotes)
    }

    /// A click on the Dock icon, or Airlock opened again from Finder or
    /// Spotlight while it runs. `hasVisibleWindows` is no help: the notch
    /// panel is always a visible window. So the full windows are asked
    /// instead, and a minimised one comes back; with none, the Airlock
    /// window opens where it was left, calls or a Settings page.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !DockPresenceController.shared.reopen() { appWindow?.showWhereLeft() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // This run ended the way a run should, so the next launch does not
        // ask about crash reports. See `CleanExitMarker`.
        CrashReporter.shared.noteCleanExit()
        // Counts still waiting go to a file and are sent after the next launch.
        UsageCounts.shared.willQuit()
        model?.persistNow()
        // Saves are debounced by a second, so a quit inside that second would
        // otherwise lose whatever you last copied — or the last gate answered.
        clipboardWidget?.persistNow()
        model?.persistGateLogNow()
    }

    @objc private func togglePanel() { notch?.toggle() }
    @objc private func openSettings() { appWindow?.show() }
    @objc private func openCallNotes() { model?.meetings.showPastCalls() }
    @objc private func pressNotesButton() { model?.meetings.pressHandButton() }
    @objc private func addRecording() { model?.meetings.addRecording() }
    /// "Set up Airlock…" — the same setup a first run gets, in the notch, from
    /// the first step. The owner preferred it there to a window (2026-10-08).
    ///
    /// Only one surface at a time: both drive the same model, so a window left
    /// up beside the notch copy would be two live views on one wizard, each
    /// stepping the other. The window is still the fallback when there is no
    /// panel to run in, for the reason `presentOnboardingIfNeeded` gives.
    @objc private func openOnboarding() {
        guard let onboardingModel, NotchScreen.target != nil else {
            notch?.endOnboarding()
            onboarding?.showFromStart()
            return
        }
        onboarding?.close()
        onboardingModel.restart()
        notch?.beginOnboarding(onboardingModel)
    }
    @objc private func checkForUpdates() { updater?.checkForUpdates() }
    @objc private func seedDemo() { model?.seedDemo() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    /// Settles the status menu just before it shows. Call notes being on is
    /// read here rather than watched: the menu is the only place the row
    /// shows, and nobody sees the menu closed. One method for both builds,
    /// because a type can conform to `NSMenuDelegate` only once, so the
    /// guide's rows are a call from here rather than a second conformance.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let notesOn = model?.meetings.isEnabled ?? false
        Self.showCallNotes(in: menu, when: notesOn)
        Self.showHandNotes(in: menu, as: notesOn ? model?.meetings.handButton : nil)
        Self.showAddRecording(in: menu, when: notesOn, reading: model?.meetings.recordings.isBusy ?? false)
        #if AIRLOCK_GUIDE
        updateGuideRows(in: menu)
        #endif
    }
}
