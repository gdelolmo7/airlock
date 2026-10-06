import XCTest
@testable import AirlockCore

private let t0 = Date(timeIntervalSince1970: 1_785_160_000)
private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

// MARK: - Hold gesture

final class HoldGestureTests: XCTestCase {
    func testHoldThenReleaseRecordsAndDelivers() {
        var gesture = HoldGesture()
        XCTAssertEqual(gesture.apply(.keyDown(at: at(0))), .startCapture)
        XCTAssertTrue(gesture.isRecording)
        XCTAssertEqual(gesture.apply(.keyUp(at: at(2))), .finish(.released))
        XCTAssertFalse(gesture.isRecording)
    }

    /// Capture starts on the way DOWN, not after an arm delay — people begin
    /// speaking immediately and a delay would clip the first word. A tap is
    /// handled by throwing the audio away afterwards instead.
    func testTapStartsCaptureThenDiscards() {
        var gesture = HoldGesture()
        XCTAssertEqual(gesture.apply(.keyDown(at: at(0))), .startCapture)
        XCTAssertEqual(gesture.apply(.keyUp(at: at(0.1))), .discard(.tooShort))
    }

    func testExactlyAtTheMinimumCounts() {
        var gesture = HoldGesture()
        gesture.apply(.keyDown(at: at(0)))
        XCTAssertEqual(gesture.apply(.keyUp(at: at(HoldGesture.minimumHold))), .finish(.released))

        // The floor is a real filter, not a formality. Bare modifiers are how
        // every chord on the machine starts, so a brush against one is ordinary
        // — and at 0.25 those reached the recogniser and produced a card.
        var brushed = HoldGesture()
        brushed.apply(.keyDown(at: at(0)))
        XCTAssertEqual(brushed.apply(.keyUp(at: at(0.3))), .discard(.tooShort),
                       "a third of a second on a bare modifier is a brush, not speech")
    }

    // MARK: - The blind floor

    /// When another app holds secure input, no key event reaches our tap, so
    /// `HoldKeyMonitor` never disqualifies ⌥⌫ and a word-delete is
    /// indistinguishable from someone about to speak. Time is the only lever
    /// left.
    func testTheBlindFloorDiscardsWhatTheNormalFloorWouldDeliver() {
        var blind = HoldGesture(floor: HoldGesture.blindHold)
        blind.apply(.keyDown(at: at(0)))
        XCTAssertEqual(blind.apply(.keyUp(at: at(0.5))), .discard(.tooShort),
                       "half a second of ⌥ while deleting a word is not speech")

        var normal = HoldGesture()
        normal.apply(.keyDown(at: at(0)))
        XCTAssertEqual(normal.apply(.keyUp(at: at(0.5))), .finish(.released),
                       "and the same half second IS delivered when chords can be seen")
    }

    /// The raised floor is a threshold, not a ban — a deliberate hold still
    /// dictates, or secure input would mean no dictation at all.
    func testTheBlindFloorStillDeliversADeliberateHold() {
        var blind = HoldGesture(floor: HoldGesture.blindHold)
        blind.apply(.keyDown(at: at(0)))
        XCTAssertEqual(blind.apply(.keyUp(at: at(2))), .finish(.released))
    }

    /// The lost-release path has to use the same floor. It used to read the
    /// static directly, which would have left one of the two branches deciding
    /// by a rule the other had stopped using.
    func testTheWatchdogHonoursTheSameFloor() {
        var blind = HoldGesture(floor: HoldGesture.blindHold)
        blind.apply(.keyDown(at: at(0)))
        XCTAssertEqual(blind.apply(.tick(at: at(0.6), isPhysicallyDown: false)),
                       .discard(.tooShort))
    }

    /// Omitting it must mean the ordinary floor, not the blind one — every
    /// existing caller constructs this with no argument.
    func testTheDefaultFloorIsTheOrdinaryOne() {
        XCTAssertEqual(HoldGesture().floor, HoldGesture.minimumHold)
        XCTAssertGreaterThan(HoldGesture.blindHold, HoldGesture.minimumHold)
    }

    /// Key auto-repeat fires keyDown over and over while held. Restarting would
    /// tear down and rebuild the audio engine many times a second.
    func testRepeatedKeyDownIsIgnored() {
        var gesture = HoldGesture()
        XCTAssertEqual(gesture.apply(.keyDown(at: at(0))), .startCapture)
        XCTAssertNil(gesture.apply(.keyDown(at: at(0.1))))
        XCTAssertNil(gesture.apply(.keyDown(at: at(0.2))))
        // Still timed from the FIRST press, so the hold is long enough. The
        // release is past `minimumHold` deliberately — this test is about the
        // repeats not restarting the clock, and pinning it just over the floor
        // made it fail for an unrelated reason when the floor moved.
        XCTAssertEqual(gesture.apply(.keyUp(at: at(0.5))), .finish(.released))
    }

    func testReleaseWithoutPressDoesNothing() {
        var gesture = HoldGesture()
        XCTAssertNil(gesture.apply(.keyUp(at: at(1))))
        XCTAssertFalse(gesture.isRecording)
    }

    // MARK: The bug this type exists for

    /// Another app grabs the keyboard, a Space switches, the screen locks — and
    /// the release event never arrives. Without the watchdog the engine runs
    /// forever and the microphone light never goes out.
    func testWatchdogEndsAHoldWhoseReleaseWasLost() {
        var gesture = HoldGesture()
        gesture.apply(.keyDown(at: at(0)))
        XCTAssertNil(gesture.apply(.tick(at: at(1), isPhysicallyDown: true)))
        XCTAssertEqual(gesture.apply(.tick(at: at(2), isPhysicallyDown: false)),
                       .finish(.releaseLost))
        XCTAssertFalse(gesture.isRecording)
    }

    /// A lost release still DELIVERS. The words were spoken; discarding them
    /// because an event went missing would be worse than the bug worked around.
    func testLostReleaseDeliversRatherThanDiscards() {
        var gesture = HoldGesture()
        gesture.apply(.keyDown(at: at(0)))
        guard case .finish = gesture.apply(.tick(at: at(5), isPhysicallyDown: false)) else {
            return XCTFail("a lost release must deliver what was said")
        }
    }

    /// But a lost release on something that was only ever a tap is still a tap.
    func testLostReleaseOnATapStillDiscards() {
        var gesture = HoldGesture()
        gesture.apply(.keyDown(at: at(0)))
        XCTAssertEqual(gesture.apply(.tick(at: at(0.1), isPhysicallyDown: false)),
                       .discard(.tooShort))
    }

    func testTicksDoNothingWhenIdle() {
        var gesture = HoldGesture()
        XCTAssertNil(gesture.apply(.tick(at: at(1), isPhysicallyDown: false)))
        XCTAssertNil(gesture.apply(.tick(at: at(2), isPhysicallyDown: true)))
    }

    /// A genuinely stuck key must not record until the disk fills — but reaching
    /// the ceiling still hands over what was said. It is a safety limit, not a
    /// penalty.
    func testReachingTheCeilingFinishes() {
        var gesture = HoldGesture()
        gesture.apply(.keyDown(at: at(0)))
        XCTAssertEqual(gesture.apply(.tick(at: at(HoldGesture.maximumHold), isPhysicallyDown: true)),
                       .finish(.reachedLimit))
        XCTAssertFalse(gesture.isRecording)
    }

    func testCancelDiscards() {
        var gesture = HoldGesture()
        gesture.apply(.keyDown(at: at(0)))
        XCTAssertEqual(gesture.apply(.cancel), .discard(.cancelled))
        XCTAssertNil(gesture.apply(.cancel))
    }

    /// Whatever happens, the machine ends idle — there is no path that leaves a
    /// capture running with nobody to stop it.
    func testEveryTerminalEventLeavesItIdle() {
        let enders: [HoldGesture.Event] = [
            .keyUp(at: at(3)),
            .tick(at: at(3), isPhysicallyDown: false),
            .tick(at: at(HoldGesture.maximumHold + 1), isPhysicallyDown: true),
            .cancel,
        ]
        for ender in enders {
            var gesture = HoldGesture()
            gesture.apply(.keyDown(at: at(0)))
            XCTAssertNotNil(gesture.apply(ender), "\(ender) should end the hold")
            XCTAssertFalse(gesture.isRecording, "\(ender) left it recording")
        }
    }

    func testHeldForIsZeroWhenIdle() {
        XCTAssertEqual(HoldGesture().heldFor(at: at(10)), 0)
        var gesture = HoldGesture()
        gesture.apply(.keyDown(at: at(0)))
        XCTAssertEqual(gesture.heldFor(at: at(2.5)), 2.5, accuracy: 0.001)
    }
}

// MARK: - Transcript stitching

final class DictationTranscriptTests: XCTestCase {
    /// THE measured fact this type exists for: result text is cumulative over
    /// its range, not a delta. Appending every volatile gives "AppApproveApprove".
    func testVolatileIsReplacedNotAppended() {
        var transcript = DictationTranscript()
        transcript.apply(text: "App", isFinal: false)
        transcript.apply(text: "Approve", isFinal: false)
        transcript.apply(text: "Approve the", isFinal: false)
        XCTAssertEqual(transcript.display, "Approve the")
    }

    /// And a final REPLACES the volatile covering the same audio — usually with
    /// different casing and punctuation than the guess.
    func testFinalSupersedesTheVolatileItCovers() {
        var transcript = DictationTranscript()
        transcript.apply(text: "Approve the Bash command", isFinal: false)
        transcript.apply(text: "Approve the bash command.", isFinal: true)
        XCTAssertEqual(transcript.display, "Approve the bash command.")
        XCTAssertEqual(transcript.deliverable, "Approve the bash command.")
    }

    func testFinalsAccumulateAcrossSegments() {
        var transcript = DictationTranscript()
        transcript.apply(text: "Run the tests", isFinal: true)
        transcript.apply(text: "and tell me what broke", isFinal: true)
        XCTAssertEqual(transcript.deliverable, "Run the tests and tell me what broke")
    }

    /// A forced finalisation can cut mid-sentence, so the next segment really
    /// does start with a comma. An unconditional space gives "files , in the".
    func testSegmentStartingWithPunctuationAttaches() {
        var transcript = DictationTranscript()
        transcript.apply(text: "lists the files", isFinal: true)
        transcript.apply(text: ", in the current directory", isFinal: true)
        XCTAssertEqual(transcript.deliverable, "lists the files, in the current directory")
    }

    func testApostropheAttaches() {
        var transcript = DictationTranscript()
        transcript.apply(text: "it", isFinal: true)
        transcript.apply(text: "'s working", isFinal: true)
        XCTAssertEqual(transcript.deliverable, "it's working")
    }

    /// Anything still volatile when you stop speaking is superseded by a final
    /// covering the same audio; delivering it would double the last few words.
    func testVolatileIsNeverDelivered() {
        var transcript = DictationTranscript()
        transcript.apply(text: "Run the tests", isFinal: true)
        transcript.apply(text: "and then", isFinal: false)
        XCTAssertEqual(transcript.deliverable, "Run the tests")
        XCTAssertEqual(transcript.display, "Run the tests and then")
    }

    func testEmptyFinalStillClearsTheVolatileItSupersedes() {
        var transcript = DictationTranscript()
        transcript.apply(text: "guess", isFinal: false)
        transcript.apply(text: "", isFinal: true)
        XCTAssertTrue(transcript.isEmpty)
    }

    func testResetClearsBoth() {
        var transcript = DictationTranscript()
        transcript.apply(text: "a", isFinal: true)
        transcript.apply(text: "b", isFinal: false)
        transcript.reset()
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(transcript.display, "")
    }

    func testNothingSaidIsEmpty() {
        XCTAssertTrue(DictationTranscript().isEmpty)
        XCTAssertEqual(DictationTranscript().deliverable, "")
    }
}

// MARK: - Text preparation

final class DictationTextTests: XCTestCase {
    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(DictationText.prepared("  run   the\n tests  "), "run the tests")
    }

    /// Nil rather than "" so the caller can tell "you said nothing" from
    /// "something broke" — silence and a dead microphone look identical
    /// otherwise, and need different messages.
    func testNothingSaidIsNilNotEmpty() {
        XCTAssertNil(DictationText.prepared(""))
        XCTAssertNil(DictationText.prepared("   \n\t "))
    }

    /// Half a surrogate is not a character: splitting on a raw UTF-16 index
    /// turns an emoji into two replacement glyphs.
    func testChunkingNeverSplitsASurrogatePair() {
        let text = String(repeating: "😀", count: 8)
        let chunks = DictationText.chunked(text, limit: 5)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertFalse(chunk.unicodeScalars.contains { (0xD800...0xDFFF).contains($0.value) })
        }
    }

    func testChunksStayWithinTheLimit() {
        let text = "the quick brown fox jumps over the lazy dog"
        for limit in [2, 3, 7, 20] {
            for chunk in DictationText.chunked(text, limit: limit) {
                XCTAssertLessThanOrEqual(chunk.utf16.count, limit, "limit \(limit)")
            }
        }
    }

    func testChunkingIsLossless() {
        let text = "café — naïve 😀 résumé, 日本語"
        for limit in [2, 4, 9, 50] {
            XCTAssertEqual(DictationText.chunked(text, limit: limit).joined(), text, "limit \(limit)")
        }
    }

    /// A pair is two units wide, so a limit of 1 could never place one — it
    /// would emit empty chunks forever.
    func testAbsurdLimitsDoNotHang() {
        XCTAssertEqual(DictationText.chunked("😀ab", limit: 1).joined(), "😀ab")
        XCTAssertEqual(DictationText.chunked("😀ab", limit: 0).joined(), "😀ab")
        XCTAssertEqual(DictationText.chunked("😀ab", limit: -5).joined(), "😀ab")
    }

    func testEmptyChunksToNothing() {
        XCTAssertTrue(DictationText.chunked("").isEmpty)
    }

    func testShortTextIsOneChunk() {
        XCTAssertEqual(DictationText.chunked("hello", limit: 20), ["hello"])
    }
}

// MARK: - Readiness

final class DictationReadinessTests: XCTestCase {
    private func evaluate(enabled: Bool = true, bundled: Bool = true,
                          mic: MicrophoneAuthorization = .granted,
                          model: Bool = true, trusted: Bool = true,
                          watching: Bool = true) -> DictationReadiness {
        DictationReadiness.evaluate(isEnabled: enabled, isBundled: bundled, microphone: mic,
                                    hasSpeechModel: model, locale: "en_US",
                                    isTrustedToType: trusted, isWatchingHoldKey: watching)
    }

    func testEverythingReadyRecordsAndTypes() {
        let readiness = evaluate()
        XCTAssertTrue(readiness.canRecord)
        XCTAssertTrue(readiness.canType)
        XCTAssertTrue(readiness.canWatchHoldKey)
        XCTAssertNil(readiness.blocker)
    }

    /// **The two permissions are independent, and the app used to model only
    /// one.** Accessibility grants typing; Input Monitoring grants seeing the
    /// key go down. A Mac can have either without the other — and on the one
    /// where this was found, Accessibility was allowed while the hold key was
    /// dead, so every surface reported the feature healthy and the user had
    /// nothing to read anywhere.
    func testTypingAndWatchingAreSeparatePermissions() {
        let canTypeOnly = evaluate(trusted: true, watching: false)
        XCTAssertTrue(canTypeOnly.canType)
        XCTAssertFalse(canTypeOnly.canWatchHoldKey)

        let canWatchOnly = evaluate(trusted: false, watching: true)
        XCTAssertFalse(canWatchOnly.canType)
        XCTAssertTrue(canWatchOnly.canWatchHoldKey)
    }

    /// A dead hold key is reported, never enforced.
    ///
    /// It is measured from `CGGetEventTapList` rather than read from a TCC API,
    /// so a wrong reading must cost a misleading row and nothing more. Making it
    /// a blocker would let one bad measurement take away a dictation that works.
    func testADeadHoldKeyNeverStopsRecording() {
        let readiness = evaluate(watching: false)
        XCTAssertTrue(readiness.canRecord)
        XCTAssertNil(readiness.blocker)
    }

    /// Accessibility is NOT a blocker. Without it we can still listen and still
    /// transcribe, so we do — and show the user their words with a button to
    /// grant it. "Nothing happened" is the one outcome nobody can debug.
    func testMissingAccessibilityStillRecords() {
        let readiness = evaluate(trusted: false)
        XCTAssertTrue(readiness.canRecord)
        XCTAssertFalse(readiness.canType)
    }

    func testDisabledOutranksEverything() {
        XCTAssertEqual(evaluate(enabled: false, bundled: false, mic: .denied, model: false).blocker,
                       .disabled)
    }

    /// Checked before the microphone deliberately: an unbundled binary can never
    /// be granted, so "allow the microphone" would be advice nobody can follow.
    func testUnbundledOutranksThePermission() {
        XCTAssertEqual(evaluate(bundled: false, mic: .denied).blocker, .notBundled)
    }

    func testDeniedAndUndeterminedAreDifferentMessages() {
        XCTAssertEqual(evaluate(mic: .denied).blocker, .microphoneDenied)
        XCTAssertEqual(evaluate(mic: .undetermined).blocker, .microphoneUndetermined)
        XCTAssertNotEqual(DictationReadiness.Blocker.microphoneDenied.message,
                          DictationReadiness.Blocker.microphoneUndetermined.message)
    }

    /// The language by name, never the code: `de_DE` is how the speech
    /// framework spells German, not how anyone reading Settings does.
    func testMissingModelNamesTheLanguageNotTheCode() {
        XCTAssertEqual(evaluate(model: false).blocker, .noSpeechModel(locale: "en_US"))
        let message = DictationReadiness.Blocker.noSpeechModel(locale: "de_DE").message
        XCTAssertFalse(message.contains("de_DE"), message)
        XCTAssertEqual(message, DictationHoldNotice.noSpeechModel(locale: "de_DE").sentence,
                       "Settings and the notch say it the same way")
    }

    /// A person can read this one: no developer commands in it.
    func testUnbundledSaysItPlainly() {
        let message = DictationReadiness.Blocker.notBundled.message
        XCTAssertFalse(message.contains("package-app"), message)
        XCTAssertFalse(message.contains("`"), message)
    }

    /// The microphone gates everything, so it is reported ahead of the model.
    func testMicrophoneOutranksTheModel() {
        XCTAssertEqual(evaluate(mic: .denied, model: false).blocker, .microphoneDenied)
    }

    func testEveryBlockerSaysSomethingActionable() {
        let blockers: [DictationReadiness.Blocker] = [
            .disabled, .microphoneUndetermined, .microphoneDenied,
            .noSpeechModel(locale: "en_US"), .notBundled,
        ]
        for blocker in blockers {
            XCTAssertFalse(blocker.message.isEmpty, "\(blocker)")
            XCTAssertTrue(blocker.message.hasSuffix("."), "\(blocker) should read as a sentence")
        }
    }
}
