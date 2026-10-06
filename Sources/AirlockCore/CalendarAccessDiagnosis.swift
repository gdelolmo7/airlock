import Foundation

/// What actually happened when the app asked macOS for calendar access.
///
/// The status left behind is not enough to say, and the difference matters
/// because the two denials need opposite advice. macOS credits a permission
/// request to the *responsible* process — for an app spawned by a shell that is
/// the terminal, or the coding agent driving one — and under the hardened
/// runtime the responsible process must itself carry the entitlement. A
/// terminal carries no calendar entitlement, so tccd declines to put the dialog
/// on screen and answers denied. Nothing is written down, nothing appears in
/// System Settings, and the app it happened to did nothing wrong.
///
/// Telling that apart from a real "Don't Allow" is what this exists for: the
/// old message blamed a stale permission record and pointed at System Settings,
/// which in the suppressed case is a pane with no Airlock row in it — the most
/// confusing possible answer to "why did nothing happen?".
public enum CalendarAccessOutcome: Equatable, Sendable {
    /// Granted. Nothing to say.
    case granted
    /// The dialog never reached the screen. Relaunching so the app is
    /// responsible for itself is the fix; System Settings is not.
    case promptSuppressed
    /// The dialog was shown and the answer was no. System Settings is the way
    /// back, and the only one.
    case declined
    /// Denied before we asked — an earlier decision, or the stale record a
    /// rebuilt ad-hoc app leaves behind. Also System Settings.
    case standingDenial
    /// Neither access nor a denial. Rare, and a thrown error is all there is.
    case inconclusive

    /// Whether the Privacy pane has anything in it to change. Offering that
    /// route when it doesn't is worse than offering nothing.
    public var isFixableInSystemSettings: Bool {
        switch self {
        case .declined, .standingDenial: return true
        case .granted, .promptSuppressed, .inconclusive: return false
        }
    }
}

/// EventKit's status, restated so this decision can be reasoned about and
/// tested without EventKit — the same boundary `CalendarEvent` draws to keep
/// `EKEvent` out of the views.
public enum CalendarAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case fullAccess
    /// "Add Only" in System Settings: events can be written, none read. Its
    /// own case because the card has its own sentence for it.
    case writeOnly
    /// Anything a later macOS adds.
    case other
}

public enum CalendarAccessDiagnosis {
    /// Under this, no dialog was ever on screen.
    ///
    /// The measured refusal came back in 16ms; a human reading a permission
    /// dialog and clicking takes the better part of a second at the very least.
    /// Three orders of magnitude apart, so the threshold does not need to be
    /// clever — only to sit in the empty space between them.
    public static let dialogFloor: TimeInterval = 0.5

    public static func outcome(before: CalendarAuthorization,
                               after: CalendarAuthorization,
                               elapsed: TimeInterval) -> CalendarAccessOutcome {
        if after == .fullAccess { return .granted }
        // Restricted is an administrator's decision and never involved a
        // dialog. How we asked changes nothing about it.
        if after == .restricted { return .standingDenial }
        guard after == .denied else { return .inconclusive }
        // Already refused before we asked, so the record on file is the thing
        // to change no matter how fast this attempt came back.
        guard before == .notDetermined else { return .standingDenial }
        return elapsed < dialogFloor ? .promptSuppressed : .declined
    }
}
