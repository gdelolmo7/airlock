import SwiftUI
import AirlockCore

/// Dictation's rows (T) of the inventory.
///
/// **No `DictationModel` is ever built here.** Its init builds the audio
/// engine, the hold-key taps and the speech session, which is the microphone
/// path the gallery must not touch. What the island draws is reachable without
/// it: `ListeningStrip`, the two cards and `HoldNoticeCard` take plain values.
/// What is left is Settings › Dictation, which needs the live model — those
/// rows say so instead of being faked.
@MainActor
enum GalleryDictation {
    static let area = "Dictation"

    static var states: [GalleryState] {
        [
            strip("T1", "Listening, no words yet", words: ""),
            strip("T2", "Listening with words", words: words),
            strip("T3", "No text field (\"Release to copy it\")", words: words, route: .copy),
            strip("T4", "Asking (purple)", words: "What's on my calendar tomorrow morning", asking: true),
            strip("T5", "Key released, still finishing (identical to T2 — that is the finding)", words: words),
            strip("T6", "Tidying up", words: words, listening: false),
            strip("T6a", "Tidying up before any words showed (no grey \"…\" above it)", words: "", listening: false),
            GalleryState("T7", area, "Heard nothing (input fault)") {
                HeardNothingCard(silent: .init(device: "MacBook Pro Microphone", cause: .inputProducedNothing),
                                 chooseInput: {}, dismiss: {})
            },
            GalleryState("T8", area, "Too short") {
                HeardNothingCard(silent: .init(device: "AirPods Pro", cause: .tooShort),
                                 chooseInput: {}, dismiss: {})
            },
            GalleryState("T9", area, "Sounded like dictation") {
                HeardDictationCard(card: .init(text: "Just review the open pull request and come up with a plan for the failing tests",
                                               app: "Terminal", certain: true),
                                   keyHint: DictationModel.askKeyHint(askKey: .option, holdKey: .control),
                                   canAsk: true, type: {}, ask: {}, guide: {}, dismiss: {})
            },
            .notYet("T10", area, "Can't type (no Accessibility)",
                    why: "A notification plus a line in Settings › Dictation. " + needsModel),
            .notYet("T11", area, "Input Monitoring missing / stale",
                    why: "A notification plus the Permissions rows in Settings. " + needsModel),
            notice("T12", "Microphone allowed after macOS's prompt (the hold before was spent on it)",
                   .microphoneAllowed(key: HoldKeyMonitor.Key.control.displayName, asking: false)),
            notice("T13", "Nothing caught", .nothingCaught),
            notice("T14", "Nothing to type into", .copiedNowhereToType),
            notice("T15", "Microphone denied", .microphoneDenied),
            notice("T16", "No speech model", .noSpeechModel(locale: "en_US")),
            notice("T17", "No subscription", .noSubscription),
            notice("T18", "Microphone failed to start", .microphoneFailedToStart),
            notice("T19", "Two-minute limit", .reachedLimit),
            notice("T20", "Clean-up failed / unavailable", .tidyingFailed),
            GalleryState("T21", area, "Secure input on (above the hold it slowed down)") {
                VStack(alignment: .leading, spacing: 8) {
                    HoldNoticeCard(notice: .secureInput(holder: "1Password"))
                    listeningStrip(words: "", route: .type, asking: false, listening: true)
                }
            },
        ]
    }

    private static let needsModel = "That page needs the live dictation model, which starts the audio engine."

    /// A hold's notice, as the notch draws it in place of the strip.
    private static func notice(_ id: String, _ name: String, _ notice: DictationHoldNotice) -> GalleryState {
        GalleryState(id, area, name) { HoldNoticeCard(notice: notice) }
    }

    private static let words = "Can we move Thursday's call to four o'clock and send everyone the new link"

    /// The hold itself, as the open notch draws it. Levels are made-up peaks —
    /// a quiet room, or a mid-sentence wave — scaled the way the live meter is.
    private static func strip(_ id: String, _ name: String, words: String, route: DictationRoute = .type,
                              asking: Bool = false, listening: Bool = true) -> GalleryState {
        GalleryState(id, area, name) {
            listeningStrip(words: words, route: route, asking: asking, listening: listening)
        }
    }

    private static func listeningStrip(words: String, route: DictationRoute, asking: Bool,
                                       listening: Bool) -> ListeningStrip {
        ListeningStrip(isListening: listening, isSorting: false, isAsking: asking, askRoute: nil,
                       route: route, destinationName: route == .copy ? "Finder" : "Notes",
                       liveText: words,
                       inputLevels: (words.isEmpty || !listening
                           ? [Float(0.002), 0.003, 0.002]
                           : [Float(0.05), 0.12, 0.08]).map(MicLevel.scale))
    }
}
