import Foundation

/// The macOS permissions Airlock uses, with what each is for and how to clear
/// a record that refuses Airlock while System Settings shows it switched on
/// (card "Settings 1").
///
/// **Why a Fix exists at all.** macOS stores each grant against the signature
/// of the build that was granted. A record left by an older or differently
/// signed copy can stay switched on in System Settings and still refuse
/// Airlock, and turning the switch off and on does not change the stored
/// signature. Only removing Airlock's record does. That used to be a Terminal
/// command for one permission and nothing for the others.
///
/// **Detecting it is not possible from inside the app** for most of them: the
/// refusal looks exactly like "not allowed". So the Fix is offered beside a
/// row that reads not allowed, worded for someone who has already switched it
/// on, and does nothing until they press it and say yes. Microphone and
/// Calendar are the other case: a "no" said once is never asked again, and
/// clearing the record is what lets the Allow button ask.
///
/// Pure: the names, the sentences and the command are here and under test,
/// because the command's two words — the service and the app — are each one
/// word long, and the wrong one resets a grant that was working.
public enum PermissionKind: String, CaseIterable, Sendable {
    case screenRecording
    case accessibility
    case inputMonitoring
    case microphone
    case calendar

    /// What macOS calls it, as System Settings shows it.
    public var systemName: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone"
        case .calendar: "Calendars"
        }
    }

    /// `tccutil`'s name for the service.
    public var service: String {
        switch self {
        case .screenRecording: "ScreenCapture"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "ListenEvent"
        case .microphone: "Microphone"
        case .calendar: "Calendar"
        }
    }

    /// The anchor of its page under Privacy & Security.
    public var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        case .calendar: "Privacy_Calendars"
        }
    }

    public var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }

    /// Kept in the Mac-wide record rather than the user's, so clearing it
    /// needs an administrator: macOS asks for the Mac's password. The
    /// Input Monitoring reset has worked without one (`InputMonitoring`).
    public var needsAdministrator: Bool {
        switch self {
        case .screenRecording, .accessibility: true
        case .inputMonitoring, .microphone, .calendar: false
        }
    }

    /// Screen Recording takes effect only after Airlock reopens; macOS
    /// offers "Quit & Reopen" itself when it is switched on.
    public var needsReopen: Bool { self == .screenRecording }

    /// The command that clears Airlock's record of this permission, and
    /// nothing else's.
    public func resetCommand(bundleIdentifier: String) -> String {
        "tccutil reset \(service) \(bundleIdentifier)"
    }

    /// macOS shows a dialog for it, so after a reset the app asks again
    /// rather than sending anyone to System Settings.
    public var asksWithADialog: Bool { self == .microphone || self == .calendar }

    /// The question the Fix answers, asked before it is offered: a row that
    /// reads not allowed is usually just not allowed yet, and the Fix is for
    /// the other case — switched on, and still refused (X33).
    public var fixQuestion: String {
        "Already switched on for Airlock in System Settings, and still not allowed here?"
    }

    /// The sentence beside the Fix button: what it does, before it does it.
    public var fixExplanation: String {
        var text = "macOS may be holding an old approval from an earlier version of Airlock. "
            + "Fix clears Airlock's record only, and nothing else's."
        if needsAdministrator { text += " macOS asks for your Mac's password." }
        return text
    }

    /// After the reset: the one thing left to do, in plain words. "Allow" is
    /// the one name for asking across Settings (X36).
    public var afterFix: String {
        if asksWithADialog { return "Done. Press Allow and macOS asks you once more." }
        let base = "Done. In the list that opened, switch Airlock on again, or add it with + if it is gone."
        return needsReopen ? base + " Then choose Quit & Reopen." : base
    }

    /// When the old approval is known rather than suspected — Input Monitoring
    /// reads as granted while the key it should watch stays dead — the
    /// problem in plain words, with no "maybe".
    public var oldApprovalSentence: String {
        "macOS still has the old approval from an earlier version of Airlock, "
            + "so \(systemName) looks on but doesn't work."
    }

    /// What to do about it, beside the one button that does most of it.
    ///
    /// The fallback is the by-hand route for when the record cannot be
    /// cleared: take Airlock out of the list and put it back. No Terminal
    /// command — a customer is never sent to one (X34).
    public var oldApprovalSteps: String {
        "Fix removes it and opens \(systemName) in System Settings: switch Airlock on there, "
            + "or add it with + if it isn't listed, then quit and reopen Airlock. "
            + "If that doesn't take, select Airlock in the list, remove it with –, and add it back with +."
    }
}
