import AVFAudio
import AirlockCore

/// Asking macOS for what an add-on needs, at the moment it is added, and the
/// way back when the answer was no.
///
/// The same requests the Permissions page makes (`PermissionSweep`,
/// `PermissionSwitch`), narrowed to one add-on. Nothing here can grant
/// anything; it raises macOS's questions one at a time and opens the right
/// list in System Settings for the ones no question can switch on.
@MainActor
enum AddOnAccess {
    /// Where each permission stands now, read the way the Permissions page
    /// reads it. Every read is a preflight: none of them asks.
    static func state(_ facts: PermissionFacts) -> (MacAccess) -> MacAccessState {
        { access in
            switch access {
            case .microphone: return Self.state(facts.microphone)
            case .inputMonitoring: return Self.state(facts.inputMonitoring)
            case .accessibility: return Self.state(facts.accessibility)
            case .systemAudio:
                switch facts.otherSide {
                case .worked: return .allowed
                case .refused: return .notAllowed
                case nil: return .asksOnFirstUse
                }
            }
        }
    }

    private static func state(_ state: DiagnosticsReport.PermissionState) -> MacAccessState {
        switch state {
        case .allowed: return .allowed
        case .notAllowed: return .notAllowed
        case .notAsked: return .notAsked
        case .restricted: return .restricted
        case .asksOnFirstUse: return .asksOnFirstUse
        case .notWorking: return .notWorking
        }
    }

    /// Ask for everything `addOn` needs that isn't allowed, in its order,
    /// one at a time. Called once it has been added: a no keeps it added,
    /// and its row then says what is missing.
    static func askOnAdd(_ addOn: AddOn, dictation: DictationModel, calendar: CalendarWidgetModel) async {
        for access in addOn.needs where access.canBeAskedAhead {
            let now = state(PermissionFacts.read(dictation: dictation, calendar: calendar))(access)
            guard now == .notAsked || now == .notAllowed else { continue }
            switch access {
            case .microphone: await dictation.requestMicrophoneAccess()
            case .inputMonitoring: _ = dictation.requestInputMonitoring()
            case .accessibility: PasteService.requestTrust()
            case .systemAudio: continue
            }
            // A beat between asks, so two of macOS's questions never land on
            // screen together. The last two return before they are answered.
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// The row's button, for the first thing missing. Returns once macOS has
    /// answered where it can wait for one (the microphone), so the caller
    /// reads the page again with the answer in it.
    static func fix(_ check: AddOnAccessCheck, dictation: DictationModel) async {
        guard let first = check.missing.first else { return }
        switch (check.remedy, first) {
        case (.none, _): return
        case (.askAgain, .microphone): await dictation.requestMicrophoneAccess()
        case (.askAgain, .inputMonitoring): PermissionSwitch.allowInputMonitoring(dictation)
        case (.askAgain, .accessibility): PermissionSwitch.allowAccessibility()
        case (_, let access): PermissionPage.permission(kind(access)).open()
        }
    }

    private static func kind(_ access: MacAccess) -> PermissionKind {
        switch access {
        case .microphone: return .microphone
        case .inputMonitoring: return .inputMonitoring
        case .accessibility: return .accessibility
        case .systemAudio: return .screenRecording
        }
    }
}
