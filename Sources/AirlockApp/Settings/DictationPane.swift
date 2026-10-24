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
    /// On unless turned off. On Plus and Pro the voice model downloads by
    /// itself while it is on (`CallVoiceDownload`).
    @AppStorage(CallVoiceModel.enabledKey) private var callVoicesOn = true
    /// Notes online: on unless the hidden switch says false. Their row shows
    /// only then, and only for a subscriber.
    @AppStorage(CloudNotesService.enabledKey) private var cloudNotesOn = CloudNotesService.onByDefault
    /// "Write notes online", three ways: nil until touched, which counts
    /// as on (`CloudNotesSetting.isOn`).
    @AppStorage(CloudNotesService.settingKey) private var notesOnline: Bool?
    @Environment(DictationModel.self) private var dictation
    /// Optional so the state gallery can draw the page without the window.
    @Environment(SettingsModel.self) private var settings: SettingsModel?
    /// Optional for the same reason.
    @Environment(LicenseModel.self) private var license: LicenseModel?

    @State private var editingCleanup = false
    @State private var moreOptions: Bool
    /// Whether Allow has been pressed here for Input Monitoring, and for
    /// Accessibility. Allow opens the list in System Settings
    /// (`PermissionSwitch`), so after it the row says what to do there.
    @State private var triedRequesting = false
    @State private var triedAccessibility = false
    /// Every language a call can be heard in, dictation's own among them
    /// (`CallListeners`): asked when the page opens, unless given.
    @State private var callListeners: CallListeners
    private let asksCallListeners: Bool

    /// Rows that live behind "More options": a link to one opens them first,
    /// or it would scroll to a row that is not there.
    static let anchorsInMoreOptions: Set<SettingsAnchor> = [.microphoneInput]

    /// `callListeners`, when set, stands in for asking the Mac: the state
    /// gallery's pictures do not wait on it.
    /// Stands in for the words typed under "Words to know", for the state
    /// gallery's pictures.
    private let knownWords: [String]?
    /// Stands in for the voice model's download, for the state gallery's
    /// pictures, which never start one.
    private let voiceDownload: CallVoiceDownload.State?

    init(moreOptions: Bool = false, callListeners: CallListeners? = nil, knownWords: [String]? = nil,
         voiceDownload: CallVoiceDownload.State? = nil) {
        _moreOptions = State(initialValue: moreOptions)
        _callListeners = State(initialValue: callListeners ?? .none)
        asksCallListeners = callListeners == nil
        self.knownWords = knownWords
        self.voiceDownload = voiceDownload
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
                LookPageHeader(title: String(localized: "Voice"), subtitle: String(localized: "Hold a key, talk, and your words are typed."),
                               learnMore: SettingsPane.voice.learnMore)
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
                    callVoicesRows
                }
                tidyRow
                LookToggleRow("Pause music while I talk", isOn: Bindable(dictation).pausesMusic)
                    .settingsAnchor(.pauseMusic)
                // Off, nothing is measured (the hold key isn't watched), so
                // "All set" would be a guess; switching it on brings the rows.
                if dictation.isEnabled { permissionRows }
                LookMoreButton(isOpen: $moreOptions)
                    .padding(.top, 6)
                if moreOptions {
                    VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
                        microphoneOptions
                        languageOptions
                        tidyOptions
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
    }

    private func openForReveal() {
        guard let anchor = settings?.revealRequest?.anchor,
              Self.anchorsInMoreOptions.contains(anchor) else { return }
        moreOptions = true
    }

    // MARK: - The six rows

    @ViewBuilder private var keyRows: some View {
        LookRow("Hold to dictate") {
            LookMenu(dictation.isEnabled ? dictation.holdKey.displayName : String(localized: "Off")) {
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
        LookRow("Language on calls", subtitle: String(localized: "What call notes listen for")) {
            LookMenu(callLocale.isEmpty ? String(localized: "Same as dictation") : displayName(callLocale)) {
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
                      subtitle: String(localized: "Offers to take notes when a call starts. ") + notesPlace.settingsLine,
                      isOn: $callNotesOn)
            .settingsAnchor(.callNotes)
    }

    /// A subscriber's: "Write notes online" shows.
    private var offersNotesOnline: Bool { cloudNotesOn && license?.entitlement.limits.writesNotesOnline == true }

    /// Where the notes are written, for the line under "Call notes": as
    /// the plan and this Mac would write them, not this month's allowance.
    private var notesPlace: NotesPlace {
        NotesPlace.of(online: .init(exists: cloudNotesOn, settingOn: CloudNotesSetting.isOn(notesOnline), blocked: false),
                      planWritesOnline: license?.entitlement.limits.writesNotesOnline == true,
                      availability: dictation.cleanupAvailability)
    }

    /// The way back to calls already over. Here because this is where call
    /// notes are set up, and the island only offers a call as it ends.
    private var pastCallsRow: some View {
        LookRow("Past calls", subtitle: String(localized: "Every call's notes and transcript, on this Mac")) {
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
                       subtitle: dictation.cleanupAvailability == .deviceNotEligible
                           ? String(localized: "The whole call, with notes written online by a better model. On Free: words and transcript for the first \(minutes) minutes, on your Mac.")
                           : String(localized: "The whole call, with notes written online by a better model. On Free: words, transcript and notes for the first \(minutes) minutes, on your Mac.")) {
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

    /// "Tell voices apart": on Free, the row with a Plus tag, so what Plus
    /// adds is seen where it would be set. On Plus and Pro, the switch, with
    /// the model's download in its place while it comes.
    @ViewBuilder private var callVoicesRows: some View {
        Group {
            if license.map({ !$0.entitlement.limits.tellsVoicesApart }) ?? false {
                callVoicesTagRow
            } else {
                switch voiceDownload ?? CallVoiceDownload.shared.state {
                case let .downloading(fraction) where callVoicesOn:
                    callVoicesDownloadingRow(fraction)
                case .failed where callVoicesOn:
                    callVoicesFailedRow
                default:
                    callVoicesRow
                }
            }
        }
        .settingsAnchor(.tellVoicesApart)
        .onChange(of: callVoicesOn) { _, on in
            if on { startVoiceDownload() }
        }
        .task { startVoiceDownload() }
    }

    /// Opening the page, or turning the switch on, starts a download that
    /// is due, rather than waiting for the next look.
    private func startVoiceDownload() {
        guard voiceDownload == nil else { return }
        CallVoiceDownload.shared.startIfWanted()
    }

    private var callVoicesLine: String {
        guard !(CallVoiceModel.isInstalled || voiceDownload == .ready) else {
            return String(localized: "Numbers the other side Person 1, Person 2\u{2026} by sound, on your Mac. Never names anyone, and remembers no voice after the call")
        }
        let megabytes = CallVoiceDownload.megabytes
        return String(localized: "Numbers the other side Person 1, Person 2\u{2026} by sound, on your Mac. Never names anyone, and remembers no voice after the call. Its model, about \(megabytes) MB, downloads by itself once")
    }

    private var callVoicesRow: some View {
        LookToggleRow("Tell voices apart",
                      subtitle: callVoicesLine,
                      isOn: $callVoicesOn)
    }

    private func callVoicesDownloadingRow(_ fraction: Double) -> some View {
        LookRow("Tell voices apart",
                subtitle: String(localized: "Getting the voice model ready: \(Int(fraction * 100))% of about \(CallVoiceDownload.megabytes) MB, downloaded once from useairlock.app")) {
            RecordingProgressBar(fraction: fraction)
                .frame(width: 90)
        }
    }

    private var callVoicesFailedRow: some View {
        LookRow("Tell voices apart",
                subtitle: String(localized: "The voice model didn't download. Airlock tries again by itself within the hour")) {
            LookButton("Try again") {
                guard voiceDownload == nil else { return }
                CallVoiceDownload.shared.startIfWanted(asked: true)
            }
        }
    }

    private var callVoicesTagRow: some View {
        LookRow("Tell voices apart",
                subtitle: String(localized: "Numbers the other side of a call Person 1, Person 2\u{2026} by sound, on your Mac. On Free, everyone on the other side is \u{201C}Them\u{201D}.")) {
            PlanTagButton(.plus) { settings?.reveal(.plans) }
        }
    }

    @ViewBuilder private var tidyRow: some View {
        LookToggleRow("Tidy up what I said",
                      subtitle: String(localized: "Removes \u{201C}um\u{201D}s and fixes punctuation, on your Mac"),
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
                       text: missing == 0 ? String(localized: "All set") : (missing == 1 ? String(localized: "1 needs you") : String(localized: "\(missing) need you")))
        }

        if !microphoneReady {
            LookRow("Microphone", subtitle: String(localized: "So it can hear you")) {
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
            LookRow("Accessibility", subtitle: String(localized: "So it can type. Until then your words go to the clipboard")) {
                LookButton("Allow", prominent: true) {
                    triedAccessibility = true
                    PermissionSwitch.allowAccessibility()
                }
            }
            if triedAccessibility { LookNote(PermissionsPage.switchItOn) }
        }

        // Not while the hold key has a fault: the rows above already say it,
        // with the button, and this would repeat it pointing somewhere else.
        if let message = dictation.statusMessage, dictation.holdKeyFault == nil {
            ProblemCard(sentence: message)
        }
    }

    @ViewBuilder private var inputMonitoringRow: some View {
        LookRow("Input Monitoring", subtitle: String(localized: "So it notices the key. Without it, holding it does nothing")) {
            LookButton("Allow", prominent: true) { requestInputMonitoring() }
        }
        if triedRequesting { LookNote(PermissionsPage.switchItOn) }
    }

    /// The page's one list of permissions: the line above says how many
    /// still need you, and each missing one gets its own row with the button.
    /// More options used to list all three again with their status.
    ///
    /// Input Monitoring counts what was MEASURED, not what macOS has on file:
    /// a record pinned to a certificate the app no longer carries reads as
    /// granted while every tap comes back disabled.
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
            ProblemCard(sentence: String(localized: "The microphone you picked isn't connected — using the system default."))
        }
        LookNote("Worth setting if you have more than one. Your Mac may pick one you didn't mean, like an iPhone in another room over Continuity.")
    }

    @ViewBuilder private var languageOptions: some View {
        LookGroupLabel("Language")
        LookRow("Also listen for") {
            LookMenu(dictation.secondaryLocaleIdentifier.isEmpty
                     ? String(localized: "Nothing else") : displayName(dictation.secondaryLocaleIdentifier)) {
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
        LookNote("For when you switch between two languages as you speak. Airlock listens for both and types whichever it understood better. Dictation takes a moment longer, and your Mac downloads the language the first time you pick it.")
        if callNotesOn { callLanguageOptions }
    }

    /// The call's second language, only once calls have a language of their
    /// own: "Same as dictation" brings dictation's second along.
    @ViewBuilder private var callLanguageOptions: some View {
        if !callLocale.isEmpty {
            LookRow("Also listen for on calls") {
                LookMenu(callSecondaryLocale.isEmpty ? String(localized: "Nothing else") : displayName(callSecondaryLocale)) {
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
                        ? String(localized: "Standard") : String(localized: "Changed by you")) {
                LookButton("Edit…") { editingCleanup = true }
            }
        }
        LookNote("Removes filler words, collapses self-corrections and fixes punctuation with Apple's model on this Mac, so nothing is sent anywhere. It adds a beat before the text appears, and types what you said as-is whenever the model is unavailable or returns something it shouldn't.")
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

    private var microphoneName: String {
        guard !dictation.inputDeviceUID.isEmpty else { return String(localized: "System default") }
        return dictation.availableInputs.first { $0.uid == dictation.inputDeviceUID }?.name ?? String(localized: "System default")
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
        let name = displayName(identifier)
        return downloads ? String(localized: "\(name) · one-time download") : name
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
        PermissionSwitch.allowInputMonitoring(dictation)
    }

    private var localeNote: String {
        guard dictation.localeIdentifier.isEmpty else {
            return String(localized: "Dictation listens for \(displayName(dictation.localeIdentifier)).")
        }
        // The language's name, never the raw code ("en_ES" meant nothing to
        // anyone who did not already know what it was).
        return String(localized: "Your Mac is set to \(displayName(Locale.current.identifier)), so that is what dictation listens for. If you speak another language, pick it above: the region your Mac is set to says nothing about which language you talk in.")
    }

    private var callLanguageNote: String {
        guard !callLocale.isEmpty else {
            return String(localized: "Call notes listen for the same languages as dictation. If your calls are in another language, pick it under Language on calls.")
        }
        let picked = [callLocale, callSecondaryLocale].filter { !$0.isEmpty }
        let names = picked.map(displayName)
        var note = names.count == 2
            ? String(localized: "Call notes listen for \(names[0]) and \(names[1]), and the notes are written in the language the call was in. If the call moves into another language your Mac knows, the notes follow it.")
            : String(localized: "Call notes listen for \(names[0]), and the notes are written in the language the call was in. If the call moves into another language your Mac knows, the notes follow it.")
        // Without a language it reads beside one it can't, the notes writer
        // has nothing to write from (`MeetingNotesSource`).
        if let unread = picked.first(where: { !CallNotesWriter.canRead($0) }),
           picked.allSatisfy({ !CallNotesWriter.canRead($0) }) {
            note += " " + String(localized: "Apple's notes writer can't read \(languageName(unread)) yet: add a second language it reads, and the notes are written from that listening.")
        }
        return note
    }

    /// "Catalan", without the region.
    private func languageName(_ identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return Locale.current.localizedString(forLanguageCode: code) ?? displayName(identifier)
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
    let text: Text

    init(_ text: LocalizedStringKey) { self.text = Text(text) }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) { self.text = Text(text) }

    var body: some View {
        text
            .font(Theme.chrome(11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
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
