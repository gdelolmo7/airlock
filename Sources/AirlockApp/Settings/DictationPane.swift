import SwiftUI
import AirlockCore

/// The Voice page, the first page in the notch's look.
///
/// Six rows say what most people come here for: the two keys, the language,
/// tidying, music, and whether macOS has allowed it all. Everything else,
/// and every explanation longer than a line, is behind "More options". The
/// page used to open on a paragraph under every switch, which is how a
/// settings window tells a stranger it was not written for them.
///
/// The language picker is not a nicety. `Locale.current` on the machine this was
/// built on reads `en_US@rg=eszzzz` — US language, Spain region — which resolves
/// to an English model and then transcribes spoken Spanish into English-sounding
/// nonsense. Nothing in a region subtag can say which language you intend to
/// *speak*, so it has to be asked.
struct DictationPane: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    /// Call notes: on unless switched off here. Their other rows show only
    /// while they are on.
    @AppStorage(MeetingNotesModel.enabledKey) private var callNotesOn = MeetingNotesModel.onByDefault
    @AppStorage(CallLanguage.primaryKey) private var callLocale = ""
    @AppStorage(CallLanguage.secondaryKey) private var callSecondaryLocale = ""
    /// On unless turned off, once the voice model is on this Mac.
    @AppStorage(CallVoiceModel.enabledKey) private var callVoicesOn = true
    /// Notes online: on unless the hidden switch says false. Their row shows
    /// only then, and only for a subscriber.
    @AppStorage(CloudNotesService.enabledKey) private var cloudNotesOn = CloudNotesService.onByDefault
    /// "Write notes online", three ways: nil until touched, which counts
    /// as on (`CloudNotesSetting.isOn`).
    @AppStorage(CloudNotesService.settingKey) private var notesOnline: Bool?
    @Environment(DictationModel.self) private var dictation
    @Environment(AssistantModel.self) private var assistant
    /// Optional so the state gallery can draw the page without the window.
    @Environment(SettingsModel.self) private var settings: SettingsModel?
    /// Optional for the same reason.
    @Environment(LicenseModel.self) private var license: LicenseModel?

    @State private var editingCleanup = false
    @State private var editingAnswers = false
    @State private var moreOptions: Bool
    /// Whether the prompt has been asked for from here. The System Settings
    /// route appears only after it, because macOS shows the dialog once per app
    /// signature and offering both at once teaches people to skip the one that
    /// works.
    @State private var triedRequesting = false
    /// Every language a call can be heard in, dictation's own among them
    /// (`CallListeners`): asked when the page opens, unless given.
    @State private var callListeners: CallListeners
    private let asksCallListeners: Bool

    /// Rows that live behind "More options": a link to one opens them first,
    /// or it would scroll to a row that is not there.
    static let anchorsInMoreOptions: Set<SettingsAnchor> = [.microphoneInput, .commandBar]

    /// `callListeners`, when set, stands in for asking the Mac: the state
    /// gallery's pictures do not wait on it.
    /// Stands in for the words typed under "Words to know", for the state
    /// gallery's pictures.
    private let knownWords: [String]?

    init(moreOptions: Bool = false, callListeners: CallListeners? = nil, knownWords: [String]? = nil) {
        _moreOptions = State(initialValue: moreOptions)
        _callListeners = State(initialValue: callListeners ?? .none)
        asksCallListeners = callListeners == nil
        self.knownWords = knownWords
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
                LookPageHeader(title: "Voice", subtitle: "Hold a key, talk, and your words are typed.")
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                keyRows
                languageRow
                callNotesRow
                if callNotesOn {
                    callLanguageRow
                    pastCallsRow
                    if offersNotesOnline { notesOnlineRow } else if showsNotesOnlineTag { notesOnlineTagRow }
                    KnownWordsRow(words: knownWords)
                        .settingsAnchor(.knownWords)
                    if CallVoiceModel.isInstalled { callVoicesRow }
                }
                tidyRow
                LookToggleRow("Pause music while I talk", isOn: Bindable(dictation).pausesMusic)
                    .settingsAnchor(.pauseMusic)
                permissionRows
                LookMoreButton(isOpen: $moreOptions)
                    .padding(.top, 6)
                if moreOptions {
                    VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
                        microphoneOptions
                        languageOptions
                        tidyOptions
                        askingOptions
                        actingOptions
                        typingOptions
                        permissionDetails
                        advancedOptions
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsLook.ground)
        .environment(\.colorScheme, .dark)
        .environment(\.problemCardLook, .notch)
        .onAppear(perform: openForReveal)
        .onChange(of: settings?.revealRequest?.serial) { openForReveal() }
        // Input Monitoring is granted in System Settings, outside this process,
        // with nothing to observe. Re-measuring on the way back is what stops
        // this page insisting the key is dead after the user has just fixed it —
        // and it rebuilds the taps, which is the part that actually makes a
        // granted permission take effect.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            dictation.recheckHoldKey()
        }
        // And while System Settings sits beside this page, not only once
        // Airlock is clicked again.
        .watchingPermissions { _ in dictation.recheckHoldKey() }
        .sheet(isPresented: $editingCleanup) {
            CleanupInstructionsSheet(dictation: dictation) { editingCleanup = false }
        }
        .sheet(isPresented: $editingAnswers) {
            AnswerInstructionsSheet(assistant: assistant) { editingAnswers = false }
        }
    }

    private func openForReveal() {
        guard let anchor = settings?.revealRequest?.anchor,
              Self.anchorsInMoreOptions.contains(anchor) else { return }
        moreOptions = true
    }

    // MARK: - The six rows

    /// BOTH holds together, which is the whole point: the two keys are chosen
    /// against each other, and the clash between them is the one failure on
    /// this page that reads as a bug rather than a setting.
    @ViewBuilder private var keyRows: some View {
        LookRow("Hold to dictate") {
            LookMenu(dictation.isEnabled ? dictation.holdKey.displayName : "Off") {
                Picker("Hold to dictate", selection: dictateChoice) {
                    ForEach(HoldKeyMonitor.Key.allCases) { key in
                        Text(key.displayName).tag(HoldKeyMonitor.Key?.some(key))
                    }
                    Divider()
                    Text("Off").tag(HoldKeyMonitor.Key?.none)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.holdToDictate)

        LookRow("Hold to ask", subtitle: asksNow ? nil : "Ask a question and the answer shows in the notch") {
            LookMenu(askChoice.wrappedValue?.displayName ?? "Off") {
                Picker("Hold to ask", selection: askChoice) {
                    ForEach(HoldKeyMonitor.Key.allCases) { key in
                        Text(key.displayName).tag(HoldKeyMonitor.Key?.some(key))
                    }
                    Divider()
                    Text("Off").tag(HoldKeyMonitor.Key?.none)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.holdToAsk)
        .disabled(!dictation.isEnabled)

        // Directly under the pair that causes it.
        if dictation.isEnabled, asksNow, dictation.askKey == dictation.holdKey {
            ProblemCard(sentence: "Pick different keys for the two holds. On the same key, asking loses and every hold types instead.")
        }
    }

    /// Off is a key choice, not a second switch: "which key?" with "none" as
    /// an answer reads as one question, where a switch beside a picker read
    /// as two.
    private var dictateChoice: Binding<HoldKeyMonitor.Key?> {
        Binding(
            get: { dictation.isEnabled ? dictation.holdKey : nil },
            set: { key in
                if let key {
                    dictation.holdKey = key
                    dictation.isEnabled = true
                } else {
                    dictation.isEnabled = false
                }
            })
    }

    private var asksNow: Bool { assistant.isEnabled && dictation.askKey != nil }

    private var askChoice: Binding<HoldKeyMonitor.Key?> {
        Binding(
            get: { assistant.isEnabled ? dictation.askKey : nil },
            set: { key in
                dictation.askKey = key
                if key != nil { assistant.isEnabled = true }
            })
    }

    private var languageRow: some View {
        LookRow("Language") {
            LookMenu(dictation.localeIdentifier.isEmpty
                     ? displayName(Locale.current.identifier)
                     : displayName(dictation.localeIdentifier)) {
                Picker("Language", selection: Bindable(dictation).localeIdentifier) {
                    Text("Follow the system").tag("")
                    Divider()
                    ForEach(localeIDs, id: \.self) { id in
                        Text(displayName(id)).tag(id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.language)
        .disabled(!dictation.isEnabled)
    }

    /// Beside dictation's language because it is the same question asked of
    /// calls, and calls are often in another language. Asked rather than
    /// guessed: the recogniser transcribes in whatever language it is given.
    /// Not disabled with dictation: call notes listen without the hold key.
    private var callLanguageRow: some View {
        LookRow("Language on calls", subtitle: "What call notes listen for") {
            LookMenu(callLocale.isEmpty ? "Same as dictation" : displayName(callLocale)) {
                Picker("Language on calls", selection: $callLocale) {
                    Text("Same as dictation").tag("")
                    Divider()
                    ForEach(callLocaleIDs, id: \.self) { id in
                        Text(callLanguageName(id)).tag(id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.callLanguages)
        // Fetched now, so the first call in it is not spent downloading.
        .onChange(of: callLocale) { prepareCallModel(callLocale) }
        .task {
            guard asksCallListeners, callNotesOn else { return }
            callListeners = await CallListeners.current()
        }
    }

    /// The one switch for everything calls do: the offer to take notes as a
    /// call starts, the Calls tab, past calls in the menu bar, and the rows
    /// under this one. Off, a call is only a call again.
    private var callNotesRow: some View {
        LookToggleRow("Call notes",
                      subtitle: "Offers to take notes when a call starts. "
                          + (writesNotesOnline ? "Written online, or on your Mac without internet"
                                               : "Written on your Mac"),
                      isOn: $callNotesOn)
            .settingsAnchor(.callNotes)
    }

    /// A subscriber's: "Write notes online" shows.
    private var offersNotesOnline: Bool { cloudNotesOn && license?.entitlement.limits.writesNotesOnline == true }

    /// Where the notes are written, for the line under "Call notes".
    private var writesNotesOnline: Bool { offersNotesOnline && CloudNotesSetting.isOn(notesOnline) }

    /// The way back to calls already over. Here because this is where call
    /// notes are set up, and the island only offers a call as it ends.
    private var pastCallsRow: some View {
        LookRow("Past calls", subtitle: "Every call's notes and transcript, on this Mac") {
            LookButton("Open past calls") { settings?.onOpenPastCalls?() }
        }
        .settingsAnchor(.pastCalls)
    }

    /// On a plan that writes notes on the Mac only: the row is there with
    /// a Plus tag instead of a switch, so what Plus adds is seen where it
    /// would be set, not only on the Plans page.
    private var showsNotesOnlineTag: Bool {
        guard cloudNotesOn, let license else { return false }
        return !license.entitlement.limits.writesNotesOnline
    }

    private var notesOnlineTagRow: some View {
        let minutes = Int(PlanLimits.freeNotesListen / 60)
        return LookRow(CloudNotesSetting.title,
                       subtitle: "The whole call, with notes written online by a better model. On Free: "
                           + "words, transcript and notes for the first \(minutes) minutes, on your Mac.") {
            PlanTagButton(.plus) { settings?.reveal(.plans) }
        }
        .settingsAnchor(.notesOnline)
    }

    /// Where a meeting's notes are written (`CloudNotesService`). Says where
    /// the transcript goes, and what off means. On until switched off: off
    /// keeps every meeting's transcript on this Mac.
    private var notesOnlineRow: some View {
        LookToggleRow(CloudNotesSetting.title,
                      subtitle: CloudNotesSetting.subtitle(for: license?.entitlement.license?.plan),
                      isOn: Binding(get: { CloudNotesSetting.isOn(notesOnline) },
                                    set: { CloudNotesService.setSwitch($0) }))
            .settingsAnchor(.notesOnline)
    }

    /// Only once the voice model is here: until it can be downloaded, the
    /// trial is the only way it arrives.
    private var callVoicesRow: some View {
        LookToggleRow("Tell voices apart",
                      subtitle: "Numbers the other side Person 1, Person 2\u{2026} by sound, on your Mac. "
                          + "Never names anyone, and remembers no voice after the call",
                      isOn: $callVoicesOn)
    }

    @ViewBuilder private var tidyRow: some View {
        LookToggleRow("Tidy up what I said",
                      subtitle: "Removes \u{201C}um\u{201D}s and fixes punctuation, on your Mac",
                      isOn: Bindable(dictation).cleansTranscript)
            .settingsAnchor(.cleanup)
        if let line = TranscriptCleanup.noModelLine(dictation.cleanupAvailability) {
            // Said whether the switch is on or not, and not as a problem:
            // dictation works, only the tidy-up is out of reach. Switched
            // off, the way back is one button away.
            LookRow("Needs Apple Intelligence", subtitle: line) {
                if dictation.cleanupAvailability == .needsAppleIntelligence,
                   let url = AppleIntelligenceSetup.Button.openSystemSettings.url {
                    LookButton(AppleIntelligenceSetup.Button.openSystemSettings.title) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if dictation.cleansTranscript,
                  let message = dictation.cleanupAvailability.message(feature: "cleanup") {
            ProblemCard(sentence: message)
        }
    }

    /// One line when macOS has allowed everything; otherwise one row per
    /// permission still missing, each with the button that fixes it. A dead
    /// hold key has no symptom, so this is the row that has to say it.
    @ViewBuilder private var permissionRows: some View {
        let missing = missingPermissions
        LookRow("Permissions") {
            LookStatus(ok: missing == 0,
                       text: missing == 0 ? "All set" : (missing == 1 ? "1 needs you" : "\(missing) need you"))
        }

        if !microphoneReady {
            LookRow("Microphone", subtitle: "So it can hear you") {
                if dictation.readiness.blocker == .microphoneDenied {
                    // A "no" is never asked again, so once it is turned off
                    // the way back is the switch in System Settings.
                    LookButton(PermissionPage.button) { PermissionPage.permission(.microphone).open() }
                } else {
                    LookButton("Allow", prominent: true) { Task { await dictation.requestMicrophoneAccess() } }
                }
            }
        }

        switch dictation.holdKeyFault {
        case .none:
            if !dictation.readiness.canWatchHoldKey { inputMonitoringRow }
        case .notGranted:
            inputMonitoringRow
        case .grantIsNotWorking:
            // The same Fix the Permissions page offers, here, rather than a
            // sentence pointing at it (X16).
            PermissionFixRow(kind: .inputMonitoring, knownOldApproval: true)
                .lookRowBox()
        }

        if !dictation.readiness.canType {
            LookRow("Accessibility", subtitle: "So it can type. Until then your words go to the clipboard") {
                LookButton(PermissionPage.button) { PermissionPage.permission(.accessibility).open() }
            }
        }

        // Not while the hold key has a fault: the rows above already say it,
        // with the button, and this would repeat it pointing somewhere else.
        if let message = dictation.statusMessage, dictation.holdKeyFault == nil {
            ProblemCard(sentence: message)
        }
    }

    @ViewBuilder private var inputMonitoringRow: some View {
        LookRow("Input Monitoring", subtitle: "So it notices the key. Without it, holding it does nothing") {
            HStack(spacing: 6) {
                if triedRequesting {
                    LookButton(PermissionPage.button) { PermissionPage.permission(.inputMonitoring).open() }
                }
                LookButton("Allow", prominent: true) { requestInputMonitoring() }
            }
        }
        if triedRequesting {
            LookNote("macOS asks only once per app. Switch Airlock on under Input Monitoring "
                     + "there, or add it with +. This page checks again when you come back.")
        }
    }

    private var missingPermissions: Int {
        [microphoneReady, dictation.readiness.canWatchHoldKey && dictation.holdKeyFault == nil,
         dictation.readiness.canType].filter { !$0 }.count
    }

    // MARK: - More options

    @ViewBuilder private var microphoneOptions: some View {
        LookGroupLabel("Microphone")
        LookRow("Microphone") {
            LookMenu(microphoneName) {
                Picker("Microphone", selection: Bindable(dictation).inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(dictation.availableInputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Look for microphones again") { dictation.refreshDevices() }
            }
        }
        .settingsAnchor(.microphoneInput)
        .disabled(!dictation.isEnabled)
        if case .unavailable = dictation.inputResolution {
            // The one failure worth interrupting for: a chosen device that has
            // gone. Dictation still works on the default, but silently.
            ProblemCard(sentence: "The microphone you picked isn't connected — using the system default.")
        }
        LookNote("Worth setting if you have more than one. Your Mac may pick one you didn't "
                 + "mean, like an iPhone in another room over Continuity.")
    }

    @ViewBuilder private var languageOptions: some View {
        LookGroupLabel("Language")
        LookRow("Also listen for") {
            LookMenu(dictation.secondaryLocaleIdentifier.isEmpty
                     ? "Nothing else" : displayName(dictation.secondaryLocaleIdentifier)) {
                Picker("Also listen for", selection: Bindable(dictation).secondaryLocaleIdentifier) {
                    Text("Nothing else").tag("")
                    Divider()
                    ForEach(localeIDs, id: \.self) { id in
                        Text(displayName(id)).tag(id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .disabled(!dictation.isEnabled)
        LookNote(localeNote)
        LookNote("A second language lets you switch mid-thought: it listens for both and keeps "
                 + "whichever it heard more clearly. A little more work per dictation, and it "
                 + "downloads the second language the first time you pick it.")
        if callNotesOn { callLanguageOptions }
    }

    /// The call's second language, only once calls have a language of their
    /// own: "Same as dictation" brings dictation's second along.
    @ViewBuilder private var callLanguageOptions: some View {
        if !callLocale.isEmpty {
            LookRow("Also listen for on calls") {
                LookMenu(callSecondaryLocale.isEmpty ? "Nothing else" : displayName(callSecondaryLocale)) {
                    Picker("Also listen for on calls", selection: $callSecondaryLocale) {
                        Text("Nothing else").tag("")
                        Divider()
                        ForEach(callLocaleIDs, id: \.self) { id in
                            Text(callLanguageName(id)).tag(id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .onChange(of: callSecondaryLocale) { prepareCallModel(callSecondaryLocale) }
        }
        LookNote(callLanguageNote)
    }

    @ViewBuilder private var tidyOptions: some View {
        LookGroupLabel("Tidying")
        if dictation.cleansTranscript, dictation.cleanupAvailability.isReady {
            // A sheet, not an inline editor: this is read once and edited
            // rarely, and ten lines of prompt would dwarf every other row.
            LookRow("How to tidy",
                    subtitle: dictation.cleanupInstructions == TranscriptCleanup.defaultInstructions
                        ? "As it came" : "Edited by you") {
                LookButton("Edit…") { editingCleanup = true }
            }
        }
        LookNote("Removes filler words, collapses self-corrections and fixes punctuation with "
                 + "Apple's model on this Mac, so nothing is sent anywhere. It adds a beat before "
                 + "the text appears, and types what you said as-is whenever the model is "
                 + "unavailable or returns something it shouldn't.")
    }

    @ViewBuilder private var askingOptions: some View {
        LookGroupLabel("Asking")
        if let message = assistant.availability.message(feature: "answering") {
            ProblemCard(sentence: message)
        }
        if assistant.isEnabled {
            LookRow("How it answers",
                    subtitle: assistant.instructions == AssistantPrompt.defaultInstructions
                        ? "As it came" : "Edited by you") {
                LookButton("Edit…") { editingAnswers = true }
            }
        }
        // Said plainly rather than left to be discovered. The on-device model
        // is small, and a user who thinks it is Claude will read every shallow
        // answer as the app being broken.
        LookNote("The ask key uses Apple's model on this Mac and shows the answer in the notch. "
                 + "It's small: good for quick facts, definitions and rewording, weak on news, "
                 + "maths and your code. Every answer has an \u{201C}Ask Claude Code\u{201D} button "
                 + "for that reason.")
    }

    @ViewBuilder private var actingOptions: some View {
        @Bindable var assistant = assistant
        LookToggleRow("Let it do things, not just answer",
                      subtitle: "It shows what it would do. Nothing happens until you approve",
                      isOn: $assistant.actionsEnabled)
            .disabled(!dictation.isEnabled || !assistant.isEnabled)
        if assistant.actionsEnabled {
            // Says the unflattering thing on purpose: instructions are
            // recognised by their shape, and the rest is answered.
            LookNote("It knows three: \u{201C}put the sound on the AirPods\u{201D}, \u{201C}copy that "
                     + "terminal command again\u{201D} and \u{201C}tell Claude to run the tests\u{201D}. "
                     + "It recognises them instantly, never turns a question into an action, and "
                     + "answers anything else as before. Sending an instruction to an agent always asks.")
        }
        LookToggleRow("Ask the model when it doesn't recognise a phrase",
                      subtitle: "A pause before answering, and the same card before anything happens",
                      isOn: $assistant.modelFallbackEnabled)
            .disabled(!assistant.actionsEnabled && !assistant.commandBarEnabled)
        if assistant.modelFallbackEnabled {
            ProblemCard(sentence: "Apple's on-device model often gets this wrong: it can act "
                        + "on things you didn't mean as instructions, and turn questions into cards.")
        }
        // Its own switch: this is the one action whose vocabulary you wrote.
        LookToggleRow("Let it run my Shortcuts",
                      subtitle: "Say \u{201C}run my morning focus shortcut\u{201D}",
                      isOn: $assistant.shortcutsEnabled)
        if assistant.shortcutsEnabled {
            LookNote("\(assistant.shortcutNames.count) found. A Shortcut always asks and never offers "
                     + "Always: its steps can be edited later, and a rule would still allow it.")
        }
        // The phrases, editable in place.
        LookGroupLabel("Phrases")
        SiteAliasEditor()
            .lookRowBox()
    }

    @ViewBuilder private var typingOptions: some View {
        @Bindable var assistant = assistant
        LookGroupLabel("Typing")
        // Not nested under "Let it do things" and not disabled with dictation:
        // this is the way in for people who never want to talk to their Mac.
        LookToggleRow("Type at the notch too",
                      subtitle: "A one-line bar that knows the same instructions",
                      isOn: $assistant.commandBarEnabled)
            .settingsAnchor(.commandBar)
        if assistant.commandBarEnabled {
            // Three, not a recorder: each is a scarce global chord, and a
            // recorder mostly produces ones that are already taken.
            LookRow("Shortcut") {
                LookMenu(Self.chordName(assistant.commandBarHotkey)) {
                    Picker("Shortcut", selection: $assistant.commandBarHotkey) {
                        ForEach(Self.chords, id: \.self) { chord in
                            Text(Self.chordName(chord)).tag(chord)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            LookNote("Typing can't write a rule: the bar shows Do it and No but never Always. "
                     + "A rule you already have still applies.")
        }
        if let error = assistant.commandBarHotkeyError {
            ProblemCard(sentence: error)
        }
        // A chord built on a hold key opens the microphone on the way down.
        if assistant.commandBarEnabled,
           let clash = CommandBarChord.collision(chord: assistant.commandBarHotkey,
                                                 holdKey: dictation.holdKey,
                                                 askKey: dictation.askKey) {
            ProblemCard(sentence: clash)
        }
    }

    /// Each permission with what it is for, whether or not it is missing.
    /// TWO for the key, not one: Input Monitoring to see it, Accessibility to
    /// type — a page that said "Accessibility twice over" sent people with a
    /// dead key to a pane where Airlock was already ticked.
    @ViewBuilder private var permissionDetails: some View {
        LookGroupLabel("Permissions")
        LookRow("Microphone", subtitle: "To hear you") {
            LookStatus(ok: microphoneReady, text: microphoneText)
        }
        LookRow("Input Monitoring", subtitle: "To notice the hold key") {
            LookStatus(ok: dictation.readiness.canWatchHoldKey && dictation.holdKeyFault == nil,
                       text: holdKeyText)
        }
        LookRow("Accessibility", subtitle: "To type the words where you are") {
            LookStatus(ok: dictation.readiness.canType, text: accessibilityText)
        }
    }

    @ViewBuilder private var advancedOptions: some View {
        AdvancedSwitch()
        // Kept for the permission case it was written for, shown only to
        // somebody looking for it.
        if advanced, let last = dictation.lastTranscript {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last dictation")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                Text(last)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                Text("Kept so a transcript is never lost to a permission problem.")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lookRowBox()
        }
    }

    // MARK: - Words

    private var microphoneReady: Bool {
        dictation.readiness.blocker != .microphoneDenied
            && dictation.readiness.blocker != .microphoneUndetermined
    }

    private var microphoneText: String {
        switch dictation.readiness.blocker {
        case .microphoneDenied: return "Turned off"
        case .microphoneUndetermined: return "Not asked yet"
        default: return "Allowed"
        }
    }

    private var accessibilityText: String {
        dictation.readiness.canType ? "Allowed" : "Not allowed"
    }

    /// Reports what was MEASURED, not what TCC has on file.
    ///
    /// The two can disagree, and the machine this was found on is the proof: the
    /// Input Monitoring record existed and read as granted while being pinned to
    /// a certificate the app no longer carried, so nothing could satisfy it and
    /// every tap came back disabled. "Allowed" there would have been the fourth
    /// surface agreeing with the three that were already wrong.
    private var holdKeyText: String {
        switch dictation.holdKeyFault {
        case .grantIsNotWorking: return "On, but not working"
        case .notGranted: return "Not allowed"
        case nil: return dictation.readiness.canWatchHoldKey ? "Allowed" : "Not allowed"
        }
    }

    private var microphoneName: String {
        guard !dictation.inputDeviceUID.isEmpty else { return "System default" }
        return dictation.availableInputs.first { $0.uid == dictation.inputDeviceUID }?.name ?? "System default"
    }

    private var localeIDs: [String] {
        dictation.availableLocales.map(\.identifier).sorted()
    }

    /// Dictation's languages, and those only the older dictation
    /// recogniser knows (Catalan among them): a call can be heard in either.
    private var callLocaleIDs: [String] {
        Array(Set(localeIDs + callListeners.speech + callListeners.dictation)).sorted()
    }

    /// "Catalan (Spain) · one-time download" for a language only dictation
    /// knows whose model is not on this Mac yet: picking it fetches it.
    private func callLanguageName(_ identifier: String) -> String {
        let downloads = callListeners.dictationOnly.contains(identifier)
            && !callListeners.installedDictation.contains(identifier)
        return displayName(identifier) + (downloads ? " · one-time download" : "")
    }

    private func prepareCallModel(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        Task {
            guard let listener = await CallListening.resolved(Locale(identifier: identifier)) else { return }
            await CallListening.prepare(listener)
            // A language just fetched loses its "one-time download".
            if asksCallListeners { callListeners = await CallListeners.current() }
        }
    }

    private func requestInputMonitoring() {
        triedRequesting = true
        dictation.requestInputMonitoring()
    }

    private var localeNote: String {
        guard dictation.localeIdentifier.isEmpty else {
            return "Dictation listens for \(displayName(dictation.localeIdentifier))."
        }
        // The language's name, never the raw code ("en_ES" meant nothing to
        // anyone who did not already know what it was).
        return "Your Mac is set to \(displayName(Locale.current.identifier)), so that is what "
            + "dictation listens for. If you speak another language, pick it above: the region "
            + "your Mac is set to says nothing about which language you talk in."
    }

    private var callLanguageNote: String {
        guard !callLocale.isEmpty else {
            return "Call notes listen for the same languages as dictation. If your calls are in "
                + "another language, pick it under Language on calls."
        }
        let picked = [callLocale, callSecondaryLocale].filter { !$0.isEmpty }
        let names = picked.map(displayName)
        var note = "Call notes listen for \(names.joined(separator: " and ")), and the notes are "
            + "written in the language the call was in. If the call moves into another language "
            + "your Mac knows, the notes follow it."
        // Without a language it reads beside one it can't, the notes writer
        // has nothing to write from (`MeetingNotesSource`).
        if let unread = picked.first(where: { !CallNotesWriter.canRead($0) }),
           picked.allSatisfy({ !CallNotesWriter.canRead($0) }) {
            note += " Apple's notes writer can't read \(languageName(unread)) yet: add a second "
                + "language it reads, and the notes are written from that listening."
        }
        return note
    }

    /// "Catalan", without the region.
    private func languageName(_ identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return Locale.current.localizedString(forLanguageCode: code) ?? displayName(identifier)
    }

    static let chords: [GlobalHotkey.Binding] = [.optionSpace, .commandShiftSpace, .commandShiftK]

    static func chordName(_ chord: GlobalHotkey.Binding) -> String {
        switch chord {
        case .optionSpace: return "⌥Space"
        case .commandShiftSpace: return "⇧⌘Space"
        case .commandShiftK: return "⇧⌘K"
        default: return "\(chord)"
        }
    }

    /// Every picker on this page names languages through here. The Mac's
    /// own identifier can carry a region keyword (`en_US@rg=eszzzz`), which
    /// `localizedString(forIdentifier:)` cannot name: it read as that code.
    private func displayName(_ identifier: String) -> String {
        SpokenLanguages.name(identifier) ?? SpokenLanguages.plain(identifier)
    }
}

/// A longer explanation, set as small text inside "More options".
struct LookNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.chrome(11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the ask key's model is told before your question. Was an inline
/// editor under a disclosure; a sheet now, like the tidying instructions.
private struct AnswerInstructionsSheet: View {
    let assistant: AssistantModel
    var onDone: () -> Void

    var body: some View {
        @Bindable var assistant = assistant
        return VStack(alignment: .leading, spacing: 12) {
            Text("How to answer your questions")
                .font(.headline)
            Text("Given to Apple's model on this Mac before each question you ask.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $assistant.instructions)
                .font(.callout.monospaced())
                .frame(width: 380, height: 220)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }

            HStack {
                Button("Back to default") {
                    assistant.instructions = AssistantPrompt.defaultInstructions
                }
                .disabled(assistant.instructions == AssistantPrompt.defaultInstructions)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: 380)
        }
        .padding(20)
    }
}

/// What the model is told before it sees your transcript.
///
/// **Editing this changes what cleaning means. It does not change the check that
/// stops the model answering you** — `TranscriptCleanup.vetted` inspects what
/// comes back, and text that grew, or that is built from words you did not say,
/// is discarded in favour of the raw transcript. That guarantee is not editable,
/// and saying so is what makes it safe to let anybody rewrite the rest.
private struct CleanupInstructionsSheet: View {
    let dictation: DictationModel
    var onDone: () -> Void

    var body: some View {
        @Bindable var dictation = dictation
        return VStack(alignment: .leading, spacing: 12) {
            Text("How to tidy up what you said")
                .font(.headline)
            Text("Run on this Mac, on the transcript, before it reaches your document.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $dictation.cleanupInstructions)
                .font(.callout.monospaced())
                .frame(width: 380, height: 220)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }

            Text("Editing this changes what cleaning means. It does not change the check that stops the model answering you — text that grew, or that is built from words you didn't say, is thrown away in favour of the raw transcript either way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 380, alignment: .leading)

            HStack {
                Button("Back to default") {
                    dictation.cleanupInstructions = TranscriptCleanup.defaultInstructions
                }
                .disabled(dictation.cleanupInstructions == TranscriptCleanup.defaultInstructions)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: 380)
        }
        .padding(20)
    }
}
