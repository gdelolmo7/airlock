import Foundation

/// What the notch says when a hold of the dictation or ask key cannot record,
/// or ends without the words landing where the person expected.
///
/// **Why the notch and not Settings.** A hold happens while you are looking at
/// another app, and the notch is the only part of Airlock you were watching.
/// These sentences used to live only in `DictationModel.statusMessage`, which
/// only Settings › Dictation draws — so a denied microphone, a missing speech
/// model or a two-minute cut-off looked exactly like the key doing nothing.
/// The notch opened (or did not) and closed again without a word.
///
/// The sentences live here rather than beside the view so they can be tested,
/// and so the notch and the gallery cannot word the same problem two ways.
/// Rules 3, 4 and 6 of `docs/how-airlock-talks.md`: plain words, one button
/// named after what it does, never a raw system message.
public enum DictationHoldNotice: Equatable, Sendable {
    /// macOS refused the microphone.
    case microphoneDenied
    /// No on-device speech model for this language, and none obtainable.
    /// Carries the identifier; the sentence says the language by name.
    case noSpeechModel(locale: String)
    /// A developer run from source: neither macOS prompt can appear.
    case notBundled
    /// The audio engine would not start — an unusual input, or one busy
    /// elsewhere. What went wrong is in the log; the person gets ours.
    case microphoneFailedToStart
    /// The first hold was spent on macOS's own microphone prompt, and it was
    /// allowed. `key` is the held key's name ("⌃ Control"); `asking` says
    /// which key it was, so the advice names the right one.
    case microphoneAllowed(key: String, asking: Bool)
    /// The hold ran and the recogniser found no words.
    case nothingCaught
    /// Nothing in front could take text, so the words went to the clipboard.
    case copiedNowhereToType
    /// The hold reached `HoldGesture.maximumHold` and was typed up to there.
    case reachedLimit
    /// Tidying up failed or was refused, so the words went in as spoken.
    case tidyingFailed
    /// Another app holds secure keyboard input — a password field, usually —
    /// which is why this hold took a second to open. `holder` is that app's
    /// name when it can be found.
    case secureInput(holder: String?)
    /// The trial is over (or the subscription ended), so the hold was refused
    /// before the microphone opened. It used to open the notch on a bare
    /// "Tidying up…" strip, or on nothing at all, and the only sentence about
    /// it was in Settings.
    case noSubscription

    /// The one thing the card's button does, when it has one.
    public enum Fix: Equatable, Sendable {
        /// Privacy & Security › Microphone in System Settings.
        case openMicrophoneSettings
        /// Settings › Dictation, at the input picker.
        case chooseInput
        /// The subscribe window, which also takes a key somebody already has.
        case subscribe

        public var button: String {
            switch self {
            case .openMicrophoneSettings: return "Open System Settings"
            case .chooseInput: return "Choose input…"
            case .subscribe: return "Subscribe"
            }
        }
    }

    /// How it reads at a glance. Only what stops dictation is drawn as a
    /// problem; the rest is news about a hold that worked, and colouring it as
    /// a fault is how a notice trains people to dismiss notices.
    ///
    /// Amber, never red, for the problems: nothing is lost, and the card is
    /// meant to be read calmly.
    public enum Tone: Equatable, Sendable {
        /// Dictation will not work until something is changed.
        case problem
        /// Something to know; nothing is broken.
        case note
    }

    public var sentence: String {
        switch self {
        case .microphoneDenied:
            return "Airlock can't use the microphone."
        case .noSpeechModel(let locale):
            return Self.noSpeechModelSentence(locale: locale)
        case .notBundled:
            return Self.notBundledSentence
        case .microphoneFailedToStart:
            return "The microphone couldn't start. Try again in a moment."
        case .microphoneAllowed(let key, let asking):
            return "Microphone allowed. Hold \(key) again to \(asking ? "ask" : "dictate")."
        case .nothingCaught:
            return "Didn't catch anything. Hold the key and try again."
        case .copiedNowhereToType:
            return "There was nowhere to type, so your words are on the clipboard."
        case .reachedLimit:
            return "Dictation stops at two minutes. Everything before that was typed."
        case .tidyingFailed:
            return Self.tidyingFailedSentence
        case .secureInput(let holder):
            return "\(holder ?? "Another app") is keeping your typing private, "
                + "so the notch waits a second before it opens."
        case .noSubscription:
            return Self.noSubscriptionSentence
        }
    }

    public var fix: Fix? {
        switch self {
        case .microphoneDenied: return .openMicrophoneSettings
        case .microphoneFailedToStart: return .chooseInput
        case .noSubscription: return .subscribe
        default: return nil
        }
    }

    public var tone: Tone {
        switch self {
        case .microphoneDenied, .noSpeechModel, .notBundled, .microphoneFailedToStart,
             .noSubscription:
            return .problem
        case .microphoneAllowed, .nothingCaught, .copiedNowhereToType, .reachedLimit,
             .tidyingFailed, .secureInput:
            return .note
        }
    }

    /// An SF Symbol name. Kept with the sentence so the gallery and the notch
    /// draw the same card from the same value.
    public var icon: String {
        switch self {
        case .microphoneDenied: return "mic.slash"
        case .noSpeechModel: return "globe"
        case .notBundled: return "shippingbox"
        case .microphoneFailedToStart: return "mic.badge.xmark"
        case .microphoneAllowed: return "mic"
        case .nothingCaught: return "ear"
        case .copiedNowhereToType: return "doc.on.clipboard"
        case .reachedLimit: return "timer"
        case .tidyingFailed: return "wand.and.stars"
        case .secureInput: return "lock"
        case .noSubscription: return "clock.badge.xmark"
        }
    }

    /// How long the notch keeps it before closing on its own. Nil for the one
    /// that belongs to a hold still in progress: it goes when the hold does.
    ///
    /// A card with a button stays longer, because reading it and deciding is
    /// slower than reading it — but not for ever: with only one button there is
    /// no other way to close it, and a notch stuck open over your work is a
    /// worse problem than the one it reports.
    public var closesAfter: TimeInterval? {
        if case .secureInput = self { return nil }
        return fix == nil ? 4 : 10
    }

    /// What a readiness blocker says in the notch. Nil for the two a hold never
    /// reports there: a switched-off feature watches no key, and an
    /// unanswered microphone is asked about instead.
    public init?(_ blocker: DictationReadiness.Blocker) {
        switch blocker {
        case .disabled, .microphoneUndetermined: return nil
        case .microphoneDenied: self = .microphoneDenied
        case .noSpeechModel(let locale): self = .noSpeechModel(locale: locale)
        case .notBundled: self = .notBundled
        }
    }

    /// What to say once a transcript has been delivered, if anything.
    ///
    /// One at a time, so where the words went comes first: a sentence that
    /// was not typed matters more than one typed at two minutes or typed
    /// untidied, and saying "everything before that was typed" over words
    /// that went to the clipboard would be false.
    public static func afterDelivery(copied: Bool, reachedLimit: Bool,
                                     tidyingFailed: Bool) -> DictationHoldNotice? {
        if copied { return .copiedNowhereToType }
        if reachedLimit { return .reachedLimit }
        if tidyingFailed { return .tidyingFailed }
        return nil
    }

    // MARK: - Sentences shared with Settings

    /// Shared with `DictationModel.statusMessage`, which Settings › Voice
    /// shows. Says what stopped, not whose fault it is — true for a trial that
    /// ran out and for a subscription that ended.
    public static let noSubscriptionSentence = "Dictation and asking need a subscription."

    /// Shared with `DictationReadiness.Blocker.message`, so the notch and
    /// Settings never word it two ways.
    static let notBundledSentence = "Dictation only works in the installed Airlock app."

    /// Shared with `CleanupService`, which puts the same words in Settings.
    public static let tidyingFailedSentence =
        "Tidying up didn't work, so your words were typed as you said them."

    /// The language by name, never the identifier: `en_US` is how the speech
    /// framework spells it, not how anyone does.
    ///
    /// Named in `displayLocale`, which is the person's own — so a Spanish Mac
    /// reads "inglés (Estados Unidos)" — and a parameter so the test can pin it.
    static func noSpeechModelSentence(locale: String, displayLocale: Locale = .current) -> String {
        "Dictation isn't available in \(languageName(locale, displayLocale: displayLocale)) on this Mac yet."
    }

    /// "English (United States)" for `en_US`; "your language" when there is no
    /// identifier or nothing can name it — an empty string or a code in the
    /// middle of a sentence is worse than the vaguer phrase.
    public static func languageName(_ identifier: String, displayLocale: Locale = .current) -> String {
        guard !identifier.isEmpty,
              let name = displayLocale.localizedString(forIdentifier: identifier),
              !name.isEmpty, name != identifier else { return "your language" }
        return name
    }
}
