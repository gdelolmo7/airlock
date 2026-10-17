import Foundation

/// Where a call's notes will be written, said before they start: under
/// "Take notes" in the notch's offer, and under "Call notes" in Settings.
/// Both used to say "on this Mac" whatever the plan, and on a Mac that
/// can't write notes at all.
public enum NotesPlace: Equatable, Sendable {
    /// Online. `macFallback`: without internet the Mac writes them;
    /// otherwise they wait until it is back.
    case online(macFallback: Bool)
    /// On this Mac, with Apple's model.
    case mac
    /// Apple Intelligence is switched off: the transcript only, until it is on.
    case needsAppleIntelligence
    /// This Mac can't run Apple's model and nothing writes them online: the
    /// transcript only, and what would get notes.
    case transcriptOnly(Hint)

    public enum Hint: Equatable, Sendable {
        /// Nothing in this copy would.
        case none
        /// Plus writes them online.
        case upgrade
        /// The plan writes them online, but "Write notes online" is off.
        case switchOn
    }

    /// `online` is the service as this Mac sees it, `planWritesOnline` the
    /// plan's limit, `availability` Apple's model on this Mac. A month's
    /// online notes used up writes on the Mac, as the notes themselves do.
    public static func of(online: CallNotesOffers.Online, planWritesOnline: Bool,
                          availability: ModelAvailability) -> NotesPlace {
        if online.exists, online.settingOn, !online.blocked, planWritesOnline {
            return .online(macFallback: availability != .deviceNotEligible)
        }
        switch availability {
        case .needsAppleIntelligence:
            return .needsAppleIntelligence
        case .deviceNotEligible:
            guard online.exists else { return .transcriptOnly(.none) }
            if !planWritesOnline { return .transcriptOnly(.upgrade) }
            return .transcriptOnly(online.settingOn ? .none : .switchOn)
        case .ready, .modelNotReady, .unknown:
            // Still downloading, or a reason this copy doesn't know: the Mac
            // is the place, and the notes say so if it can't.
            return .mac
        }
    }

    /// Under "Take notes" in the notch.
    public var offerLine: String {
        switch self {
        case .online: "Words only, no audio kept. Notes are written online; nothing said is kept there."
        case .mac: "Words only, written on this Mac. No audio is kept."
        case .needsAppleIntelligence: "Words only, no audio kept. Turn on Apple Intelligence for notes and to-dos."
        case .transcriptOnly(.upgrade): "Words only, no audio kept. This Mac keeps the transcript; Plus also writes notes."
        case .transcriptOnly(.switchOn): "Words only, no audio kept. Switch on Write notes online in Settings for notes."
        case .transcriptOnly(.none): "Words only, no audio kept. This Mac keeps the transcript."
        }
    }

    /// The end of the "Call notes" row in Settings, after "Offers to take
    /// notes when a call starts."
    public var settingsLine: String {
        switch self {
        case .online(macFallback: true): "Written online, or on your Mac without internet"
        case .online(macFallback: false): "Written online, or once you're back online"
        case .mac: "Written on your Mac"
        case .needsAppleIntelligence: "Turn on Apple Intelligence for notes; until then, the transcript only"
        case .transcriptOnly(.upgrade): "This Mac keeps the transcript; Plus also writes notes"
        case .transcriptOnly(.switchOn): "This Mac keeps the transcript; switch on Write notes online for notes"
        case .transcriptOnly(.none): "This Mac keeps the transcript"
        }
    }
}
