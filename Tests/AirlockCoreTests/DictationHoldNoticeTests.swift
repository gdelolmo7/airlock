import XCTest
@testable import AirlockCore

/// What the notch says when a hold cannot record, or ends somewhere other
/// than where the words were expected (card B4).
final class DictationHoldNoticeTests: XCTestCase {
    private static let every: [DictationHoldNotice] = [
        .microphoneDenied, .noSpeechModel(locale: "en_US"), .notBundled, .microphoneFailedToStart,
        .microphoneAllowed(key: "⌃ Control", asking: false), .nothingCaught, .copiedNowhereToType,
        .reachedLimit, .tidyingFailed, .secureInput(holder: "1Password"), .secureInput(holder: nil),
        .noSubscription,
    ]

    func testTheSentencesTheNotchShows() {
        XCTAssertEqual(DictationHoldNotice.microphoneDenied.sentence, "Airlock can't use the microphone.")
        XCTAssertEqual(DictationHoldNotice.microphoneFailedToStart.sentence,
                       "The microphone couldn't start. Try again in a moment.")
        XCTAssertEqual(DictationHoldNotice.notBundled.sentence,
                       "Dictation only works in the installed Airlock app.")
        XCTAssertEqual(DictationHoldNotice.microphoneAllowed(key: "⌃ Control", asking: false).sentence,
                       "Microphone allowed. Hold ⌃ Control again to dictate.")
        XCTAssertEqual(DictationHoldNotice.microphoneAllowed(key: "⌥ Option", asking: true).sentence,
                       "Microphone allowed. Hold ⌥ Option again to ask.")
        XCTAssertEqual(DictationHoldNotice.secureInput(holder: nil).sentence,
                       "Another app is keeping your typing private, so the notch waits a second before it opens.")
    }

    /// Rules 1 and 3 of `docs/how-airlock-talks.md`: a sentence or two, and
    /// none of the words a person should never meet.
    func testEverySentenceIsShortAndPlain() {
        for notice in Self.every {
            let sentence = notice.sentence
            XCTAssertTrue(sentence.hasSuffix("."), "\(notice) should read as a sentence")
            let sentences = sentence.split(whereSeparator: { $0 == "." }).count
            XCTAssertLessThanOrEqual(sentences, 2, "\(notice): \(sentence)")
            for word in ["error", "failed to", "package-app", "`", "_US", "localizedDescription", "OK"] {
                XCTAssertFalse(sentence.contains(word), "\(notice) says \"\(word)\": \(sentence)")
            }
        }
    }

    /// Rule 4: one button, named after what it does — and only where there is
    /// something to do.
    func testButtonsAreNamedAfterWhatTheyDo() {
        XCTAssertEqual(DictationHoldNotice.microphoneDenied.fix, .openMicrophoneSettings)
        XCTAssertEqual(DictationHoldNotice.microphoneDenied.fix?.button, "Open System Settings")
        XCTAssertEqual(DictationHoldNotice.microphoneFailedToStart.fix, .chooseInput)
        XCTAssertEqual(DictationHoldNotice.microphoneFailedToStart.fix?.button, "Choose input…")
        XCTAssertEqual(DictationHoldNotice.noSubscription.fix, .subscribe)
        XCTAssertEqual(DictationHoldNotice.noSubscription.fix?.button, "Subscribe")
        for notice in Self.every where notice != .microphoneDenied && notice != .microphoneFailedToStart
            && notice != .noSubscription {
            XCTAssertNil(notice.fix, "\(notice)")
        }
    }

    /// Only what stops dictation is drawn as a problem.
    func testOnlyWhatStopsDictationIsAProblem() {
        let problems = Self.every.filter { $0.tone == .problem }
        XCTAssertEqual(problems, [.microphoneDenied, .noSpeechModel(locale: "en_US"), .notBundled,
                                  .microphoneFailedToStart, .noSubscription])
    }

    /// Without a button it closes itself quickly; with one, later but still on
    /// its own — the button is the only other way to close it. The one about a
    /// hold still running goes with the hold.
    func testHowLongEachStays() {
        XCTAssertEqual(DictationHoldNotice.nothingCaught.closesAfter, 4)
        XCTAssertEqual(DictationHoldNotice.microphoneDenied.closesAfter, 10)
        XCTAssertNil(DictationHoldNotice.secureInput(holder: nil).closesAfter)
        for notice in Self.every {
            if let seconds = notice.closesAfter { XCTAssertGreaterThan(seconds, 2, "\(notice)") }
        }
    }

    func testTheLanguageIsNamedNotCoded() {
        let english = Locale(identifier: "en_GB")
        XCTAssertEqual(DictationHoldNotice.languageName("en_US", displayLocale: english), "English (United States)")
        XCTAssertEqual(DictationHoldNotice.noSpeechModelSentence(locale: "de_DE", displayLocale: english),
                       "Dictation isn't available in German (Germany) on this Mac yet.")
        // Nothing to name: a vaguer phrase rather than an empty gap.
        XCTAssertEqual(DictationHoldNotice.languageName("", displayLocale: english), "your language")
    }

    func testBlockersMapToNotices() {
        XCTAssertEqual(DictationHoldNotice(.microphoneDenied), .microphoneDenied)
        XCTAssertEqual(DictationHoldNotice(.noSpeechModel(locale: "fr_FR")), .noSpeechModel(locale: "fr_FR"))
        XCTAssertEqual(DictationHoldNotice(.notBundled), .notBundled)
        // A switched-off feature watches no key; an unanswered microphone is
        // asked about instead of reported.
        XCTAssertNil(DictationHoldNotice(.disabled))
        XCTAssertNil(DictationHoldNotice(.microphoneUndetermined))
    }

    /// Where the words went comes first: "everything before that was typed"
    /// over words that went to the clipboard would be false.
    func testAfterDeliveryPrecedence() {
        XCTAssertNil(DictationHoldNotice.afterDelivery(copied: false, reachedLimit: false, tidyingFailed: false))
        XCTAssertEqual(DictationHoldNotice.afterDelivery(copied: true, reachedLimit: true, tidyingFailed: true),
                       .copiedNowhereToType)
        XCTAssertEqual(DictationHoldNotice.afterDelivery(copied: false, reachedLimit: true, tidyingFailed: true),
                       .reachedLimit)
        XCTAssertEqual(DictationHoldNotice.afterDelivery(copied: false, reachedLimit: false, tidyingFailed: true),
                       .tidyingFailed)
    }

    /// The reason is the framework's own enum case — it reads as code.
    func testUnknownModelAvailabilityHidesTheReason() {
        let message = ModelAvailability.unknown("unavailable(reason: Foo.bar)").message(feature: "cleanup")
        XCTAssertEqual(message, "Cleanup isn't available on this Mac right now.")
    }
}
