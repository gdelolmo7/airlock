import SwiftUI
import AirlockCore

/// Dictation settings.
///
/// The language picker is not a nicety. `Locale.current` on the machine this was
/// built on reads `en_US@rg=eszzzz` — US language, Spain region — which resolves
/// to an English model and then transcribes spoken Spanish into English-sounding
/// nonsense. Nothing in a region subtag can say which language you intend to
/// *speak*, so it has to be asked.
struct DictationPane: View {
    @AppStorage(AdvancedSwitch.key) private var advanced = false
    @Environment(DictationModel.self) private var dictation
    @Environment(AssistantModel.self) private var assistant

    @State private var editingCleanup = false
    /// Whether the prompt has been asked for from here. The System Settings
    /// route appears only after it, because macOS shows the dialog once per app
    /// signature and offering both at once teaches people to skip the one that
    /// works.
    @State private var triedRequesting = false

    var body: some View {
        @Bindable var dictation = dictation
        @Bindable var assistant = assistant
        return Form {
            // BOTH holds in one section, which is the whole point of the
            // regroup: the two keys are chosen against each other, and the
            // clash between them is the one failure in this pane that reads as
            // a bug rather than a setting. Sections apart, the warning appeared
            // under a picker whose partner was off-screen.
            Section("Which keys do you hold?") {
                Toggle("Hold a key to dictate", isOn: $dictation.isEnabled)
                    .settingsAnchor(.holdToDictate)
                Picker("Hold to dictate", selection: $dictation.holdKey) {
                    ForEach(HoldKeyMonitor.Key.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .disabled(!dictation.isEnabled)

                Toggle("Hold a second key to ask a question", isOn: $assistant.isEnabled)
                    .settingsAnchor(.holdToAsk)
                Picker("Hold to ask", selection: $dictation.askKey) {
                    Text("Off").tag(HoldKeyMonitor.Key?.none)
                    ForEach(HoldKeyMonitor.Key.allCases) { key in
                        Text(key.displayName).tag(HoldKeyMonitor.Key?.some(key))
                    }
                }
                .disabled(!dictation.isEnabled || !assistant.isEnabled)

                // Directly under the pair that causes it.
                if dictation.askKey == dictation.holdKey {
                    ProblemCard(sentence: "Pick different keys for the two holds. On the same key, asking loses and every hold types instead.")
                }

                Text("A modifier on its own, never a letter combination. The key is only watched, "
                     + "never swallowed — so a key that types something would type it into your "
                     + "document alongside the dictation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Which microphone should it use?") {
                Picker("Input", selection: $dictation.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(dictation.availableInputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .settingsAnchor(.microphoneInput)
                .disabled(!dictation.isEnabled)

                if case .unavailable = dictation.inputResolution {
                    // The one failure worth interrupting for: a chosen device
                    // that has gone. Dictation still works on the default, but
                    // silently — and the symptom is a transcript that is quietly
                    // poor for no visible reason.
                    ProblemCard(sentence: "The microphone you picked isn't connected — using the system default.")
                }

                Button("Refresh") { dictation.refreshDevices() }
                Text("Worth setting if you have more than one. macOS may route to a device you "
                     + "didn't intend — this Mac offers an iPhone microphone over Continuity, and "
                     + "recording from a phone in another room is the kind of failure that looks "
                     + "like the feature being bad at its job.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Which language do you speak?") {
                Picker("Speak", selection: $dictation.localeIdentifier) {
                    Text("Follow the system").tag("")
                    ForEach(dictation.availableLocales.map(\.identifier).sorted(), id: \.self) { id in
                        Text(displayName(id)).tag(id)
                    }
                }
                .settingsAnchor(.language)
                .disabled(!dictation.isEnabled)
                Text(localeNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Also", selection: $dictation.secondaryLocaleIdentifier) {
                    Text("Nothing else").tag("")
                    ForEach(dictation.availableLocales.map(\.identifier).sorted(), id: \.self) { id in
                        Text(displayName(id)).tag(id)
                    }
                }
                .disabled(!dictation.isEnabled)
                Text("Recognises a second language over the same audio and keeps whichever "
                     + "one it heard more clearly — so you can switch languages mid-thought "
                     + "without touching a setting. Costs a little more work per dictation, "
                     + "and downloads the second language the first time you pick it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Should it tidy up what you said?") {
                Toggle("Tidy up what I said", isOn: $dictation.cleansTranscript)
                    .settingsAnchor(.cleanup)
                Text("Removes filler words, collapses self-corrections, fixes punctuation — "
                     + "using Apple's on-device model, so nothing is sent anywhere. Adds a beat "
                     + "before the text appears, and falls back to the raw transcript whenever "
                     + "the model is unavailable or returns something unexpected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let message = dictation.cleanupAvailability.message(feature: "cleanup") {
                    ProblemCard(sentence: message)
                }

                if dictation.cleansTranscript, dictation.cleanupAvailability.isReady {
                    // A sheet, not an inline editor. Ten lines of prompt text in
                    // a settings row makes every other row on the pane look
                    // small, and this is a thing people read once and edit
                    // rarely — it does not deserve the height it was taking.
                    LabeledContent("Instructions") {
                        HStack(spacing: 10) {
                            Text(dictation.cleanupInstructions == TranscriptCleanup.defaultInstructions
                                 ? "Default" : "Edited")
                                .foregroundStyle(.secondary)
                            Button("Edit…") { editingCleanup = true }
                        }
                    }
                    Text("Anything the model returns is checked before it is typed: text that grew, "
                         + "or that is built from words you didn't say, is discarded in favour of "
                         + "the raw transcript. Loosening these instructions cannot make it type "
                         + "an answer instead of your words.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("How do you ask a question?") { askSection }
            Section("Can it do things for you?") { actingSection }


            Section("What happens while you speak?") {
                Toggle("Pause music", isOn: $dictation.pausesMusic)
                    .settingsAnchor(.pauseMusic)
                Text("Worth it on speakers, where the music bleeds into the microphone and the "
                     + "recogniser has to compete with it. On headphones it helps with nothing, "
                     + "and for a two-second dictation the pause-and-resume can be more jarring "
                     + "than the music was. Off by default for that reason.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Microphone") { statusLabel(microphoneReady, microphoneText) }
                // A "no" is never asked again, so once it is turned off the
                // way back is the switch in System Settings, not Allow.
                if dictation.readiness.blocker == .microphoneDenied {
                    Button(PermissionPage.button) { PermissionPage.permission(.microphone).open() }
                        .buttonStyle(.borderedProminent)
                } else if !microphoneReady {
                    Button("Allow Microphone") { Task { await dictation.requestMicrophoneAccess() } }
                        .buttonStyle(.borderedProminent)
                }

                // TWO permissions, not one. This section said "Accessibility is
                // needed twice over: to watch the hold key, and to type the
                // result" — and the first half belongs to Input Monitoring, a
                // different service with a different pane. Anyone whose hold key
                // was dead came here, read that, found Airlock already ticked
                // under Accessibility, and had nowhere left to look.
                LabeledContent("Input Monitoring") {
                    statusLabel(dictation.readiness.canWatchHoldKey, holdKeyText)
                }
                switch dictation.holdKeyFault {
                case .none:
                    EmptyView()
                case .notGranted:
                    Button("Allow Input Monitoring") { requestInputMonitoring() }
                        .buttonStyle(.borderedProminent)
                    if triedRequesting {
                        Button(PermissionPage.button) { PermissionPage.permission(.inputMonitoring).open() }
                        Text("macOS asks only once per app. Switch Airlock on under Input Monitoring "
                             + "there, or add it with + — this page re-checks when you come back.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .grantIsNotWorking:
                    // The same Fix the Permissions page offers, here, rather
                    // than a sentence pointing at it (X16).
                    PermissionFixRow(kind: .inputMonitoring, knownOldApproval: true)
                }
                Text("Watching for the hold key needs Input Monitoring. Without it the key is "
                     + "simply dead: nothing records, and nothing appears to go wrong.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LabeledContent("Accessibility") { statusLabel(dictation.readiness.canType, accessibilityText) }
                if !dictation.readiness.canType {
                    Button(PermissionPage.button) { PermissionPage.permission(.accessibility).open() }
                }
                Text("Typing the result needs Accessibility. Without it dictation still listens and "
                     + "still transcribes — it just puts the words on your clipboard instead of "
                     + "inserting them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Not while the hold key has a fault: the rows above already
                // say it, with the button, and the status line would repeat it
                // pointing somewhere else.
                if let message = dictation.statusMessage, dictation.holdKeyFault == nil {
                    ProblemCard(sentence: message)
                }
            }

            // Kept for the permission case it was written for, shown only to
            // somebody looking for it: a box quoting the last thing you said
            // aloud is a strange thing to meet on the page where you set a key.
            if advanced, let last = dictation.lastTranscript {
                Section("Last dictation") {
                    Text(last)
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Text("Kept so a transcript is never lost to a permission problem.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            AdvancedSwitch()
        }
        .formStyle(.grouped)
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
        dictation.readiness.canType ? "Allowed" : "Needed to type the result"
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

    private func requestInputMonitoring() {
        triedRequesting = true
        dictation.requestInputMonitoring()
    }

    private func statusLabel(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var localeNote: String {
        guard dictation.localeIdentifier.isEmpty else {
            return "Dictation listens for \(displayName(dictation.localeIdentifier))."
        }
        // The language's name, never the raw code ("en_ES" meant nothing to
        // anyone who did not already know what it was).
        return "Your Mac is set to \(displayName(Locale.current.identifier)), so that is what "
            + "dictation listens for. If you speak another language, pick it here — the "
            + "region your Mac is set to says nothing about which language you talk in."
    }

    /// Split into computed views because the single `Section` grew past what
    /// SwiftUI's type-checker will accept — "unable to type-check this
    /// expression in reasonable time" is what a Form with thirty rows of
    /// interpolated strings buys you, and the fix is smaller expressions rather
    /// than fewer words.
    @ViewBuilder private var askSection: some View {
        @Bindable var dictation = dictation
        @Bindable var assistant = assistant
            // The switch and the key for this hold both live in "Which keys do you hold?"
            // now; what is left here is what asking DOES.
            Text("A different key, so the two are never confused: one puts words in your "
                 + "document, the other asks Apple's on-device model and shows the answer "
                 + "in the notch.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let message = assistant.availability.message(feature: "answering") {
                ProblemCard(sentence: message)
            }
    }

    @ViewBuilder private var actingSection: some View {
        @Bindable var assistant = assistant
            Toggle("Let it do things, not just answer", isOn: $assistant.actionsEnabled)
                .disabled(!dictation.isEnabled || !assistant.isEnabled)
            Text("Say \"put the sound on the AirPods\" and the notch shows you exactly "
                 + "what it would do, before it does it. Nothing happens until you "
                 + "approve it, and approving the same thing twice can write a rule so "
                 + "you stop being asked.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if assistant.actionsEnabled {
                // Says the unflattering thing, on purpose. Measured, Apple's
                // on-device model often reads "put the sound on the AirPods"
                // as a question and answers it — and someone who turned this
                // on and got an answer deserves to know that is the model,
                // not their microphone or their phrasing.
                Label("It knows three: \"put the sound on the AirPods\", \"copy that "
                      + "terminal command again\", \"tell Claude to run the tests\". "
                      + "Instructions are recognised by their shape rather than by asking "
                      + "a model, so it is instant, it never turns a question into an "
                      + "action, and anything it doesn't recognise is simply answered as "
                      + "before. Sending an instruction to an agent always asks, whatever "
                      + "rules you write.",
                      systemImage: "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // The phrases, editable in place. A button that revealed a text
            // file was the first version and was fairly called out: it is a
            // developer's answer to "how do I see what I can say".
            SiteAliasEditor()

            Toggle("Ask the model when it doesn't recognise a phrase",
                   isOn: $assistant.modelFallbackEnabled)
                .disabled(!assistant.actionsEnabled && !assistant.commandBarEnabled)
            Text("Recognised phrasings are instant and never involve a model. This adds a "
                 + "second attempt for the ones that aren't — at the cost of a pause "
                 + "before anything is answered, and with the same card before anything "
                 + "happens.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if assistant.modelFallbackEnabled {
                ProblemCard(sentence: "Apple's on-device model often gets this wrong: it can act "
                            + "on things you didn't mean as instructions, and turn questions into cards.")
            }

            // Its own switch rather than a sub-setting: enumerating the
            // library costs a subprocess, and this is the one action whose
            // vocabulary the user wrote rather than Airlock.
            Toggle("Let it run my Shortcuts", isOn: $assistant.shortcutsEnabled)
            Text("Say or type \"run my morning focus shortcut\". The word \"shortcut\" "
                 + "has to be in it — your Shortcuts are named whatever you called them, "
                 + "so without an anchor the word \"run\" would start claiming ordinary "
                 + "sentences.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if assistant.shortcutsEnabled {
                Label("A Shortcut always asks, and there is no Always button — not "
                      + "because it is powerful but because it is editable: a rule "
                      + "naming one would still allow it after its steps were rewritten. "
                      + "\(assistant.shortcutNames.count) found.",
                      systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Deliberately NOT nested under "Let it do things": that switch
            // is off by default because of an argument about the microphone,
            // and none of it survives being typed at. Not disabled by
            // `dictation.isEnabled` either — this is the way in for people
            // who want the commands and never want to talk to their Mac.
            Toggle("Type at the notch too", isOn: $assistant.commandBarEnabled)
                .settingsAnchor(.commandBar)
            Text("A one-line bar, anywhere. It knows the same instructions, shows the "
                 + "same card before doing anything, and answers what isn't one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if assistant.commandBarEnabled {
                // Three, not a recorder, for the reason the clipboard pane
                // gives: every one of these is a scarce global chord and a
                // free-form recorder mostly produces combinations that are
                // already taken. ⌥Space is Alfred's, ⌘⇧Space is 1Password's,
                // and ⌘⇧K is the one with no Space in it at all.
                Picker("Shortcut", selection: $assistant.commandBarHotkey) {
                    Text("⌥Space").tag(GlobalHotkey.Binding.optionSpace)
                    Text("⇧⌘Space").tag(GlobalHotkey.Binding.commandShiftSpace)
                    Text("⇧⌘K").tag(GlobalHotkey.Binding.commandShiftK)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if assistant.commandBarEnabled {
                Label("Typing can't write a rule: a rule says it was approved out loud, "
                      + "so the bar shows Do it and No but never Always. A rule you already "
                      + "have still applies.",
                      systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = assistant.commandBarHotkeyError {
                ProblemCard(sentence: error)
            }
            // A chord built on a hold key opens the microphone on the way
            // down — the app's own keys, not macOS's, and the reason the
            // first default had to be replaced. See `CommandBarChord`.
            if assistant.commandBarEnabled,
               let clash = CommandBarChord.collision(chord: assistant.commandBarHotkey,
                                                     holdKey: dictation.holdKey,
                                                     askKey: dictation.askKey) {
                ProblemCard(sentence: clash)
            }

            if assistant.isEnabled {
                // Said plainly rather than left to be discovered. The on-device
                // model is small, and a user who thinks it is Claude will read
                // every shallow answer as the app being broken instead of the
                // model being 3B-class.
                Text("Apple's model is small — good for quick facts, definitions and "
                     + "rewording, weak on current events, arithmetic and anything involving "
                     + "your code. Every answer has an \"Ask Claude Code\" button for "
                     + "exactly that reason.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Instructions") {
                    TextEditor(text: $assistant.instructions)
                        .font(.callout.monospaced())
                        .frame(minHeight: 150)
                        .padding(.vertical, 4)
                    Button("Reset to Default") {
                        assistant.instructions = AssistantPrompt.defaultInstructions
                    }
                    .disabled(assistant.instructions == AssistantPrompt.defaultInstructions)
                }
            }
    }

    private func displayName(_ identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        return Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
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
