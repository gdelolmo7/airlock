import Foundation

/// Microphone permission, without dragging AVFoundation into Core.
public enum MicrophoneAuthorization: Equatable, Sendable {
    case undetermined
    case denied
    case granted
}

/// Whether dictation can run, and if not, the one thing to say about it.
///
/// A single answer rather than a pile of booleans, because the settings pane and
/// the in-notch failure text both render from it and must never disagree. It
/// also forces a decision that is easy to fudge: when three things are wrong at
/// once, which do you tell the user about? The first one they can act on.
public struct DictationReadiness: Equatable, Sendable {
    public enum Blocker: Equatable, Sendable {
        case disabled
        case microphoneUndetermined
        case microphoneDenied
        /// No on-device speech model for this locale, and none obtainable.
        case noSpeechModel(locale: String)
        /// Not a real `.app`, so neither TCC prompt can appear at all.
        case notBundled

        public var message: String {
            switch self {
            case .disabled:
                return "Dictation is turned off."
            case .microphoneUndetermined:
                return "Dictation needs access to your microphone."
            case .microphoneDenied:
                return "Microphone access was denied — turn it on in System Settings › Privacy & Security › Microphone."
            case .noSpeechModel(let locale):
                return DictationHoldNotice.noSpeechModelSentence(locale: locale)
            case .notBundled:
                return DictationHoldNotice.notBundledSentence
            }
        }
    }

    /// Nil when dictation can record.
    public let blocker: Blocker?
    /// Whether the transcript can be typed into the focused app. **Accessibility.**
    ///
    /// Deliberately NOT a blocker. Without Accessibility we can still listen and
    /// still transcribe — so we do, and show the user their words with a button
    /// to grant it. Refusing to record would throw away something we are
    /// perfectly able to produce, and "nothing happened" is the one outcome
    /// nobody can debug.
    public let canType: Bool
    /// Whether the hold key is actually being watched. **Input Monitoring.**
    ///
    /// A separate permission from `canType`, separately granted, and for a long
    /// time not represented here at all — which is how the app came to insist
    /// every permission was in place while holding the key did nothing. There
    /// was no field for the failure, so there was nothing for any surface to
    /// draw.
    ///
    /// Also not a blocker, and for a sharper reason than `canType`: this is
    /// measured from `CGGetEventTapList`, so a wrong reading would take away a
    /// dictation that works. The measurement drives what the app *says*, never
    /// what it refuses to do.
    public let canWatchHoldKey: Bool

    public var canRecord: Bool { blocker == nil }

    public init(blocker: Blocker?, canType: Bool, canWatchHoldKey: Bool) {
        self.blocker = blocker
        self.canType = canType
        self.canWatchHoldKey = canWatchHoldKey
    }

    /// Precedence is fixed and ordered by what the user can do about it: the
    /// switch they own, then the permission that gates everything, then the
    /// model, then the thing that only degrades output.
    public static func evaluate(isEnabled: Bool,
                                isBundled: Bool,
                                microphone: MicrophoneAuthorization,
                                hasSpeechModel: Bool,
                                locale: String,
                                isTrustedToType: Bool,
                                isWatchingHoldKey: Bool) -> DictationReadiness {
        let blocker: Blocker?
        if !isEnabled {
            blocker = .disabled
        } else if !isBundled {
            // Checked before the microphone on purpose: an unbundled binary can
            // never be granted, so "allow the microphone" would be advice that
            // cannot be followed.
            blocker = .notBundled
        } else if microphone == .denied {
            blocker = .microphoneDenied
        } else if microphone == .undetermined {
            blocker = .microphoneUndetermined
        } else if !hasSpeechModel {
            blocker = .noSpeechModel(locale: locale)
        } else {
            blocker = nil
        }
        return DictationReadiness(blocker: blocker, canType: isTrustedToType,
                                  canWatchHoldKey: isWatchingHoldKey)
    }
}
