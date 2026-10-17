import XCTest
@testable import AirlockCore

final class CallLiveTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(endedAfter minutes: Double? = nil, dropped: Bool = false) -> MeetingRecord {
        MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                      endedAt: minutes.map { start.addingTimeInterval($0 * 60) },
                      segments: [MeetingSegment(speaker: .me, start: 2, end: 6, text: "Hello there."),
                                 MeetingSegment(speaker: .them, start: 7, end: 12, text: "Hi, can you hear me?")],
                      droppedAt: dropped ? start.addingTimeInterval(30) : nil)
    }

    func testStageFollowsTheCallThroughToItsNotes() {
        XCTAssertEqual(CallLive.stage(of: record(), paused: false, outcome: nil), .listening)
        XCTAssertEqual(CallLive.stage(of: record(), paused: true, outcome: nil), .paused)
        let over = record(endedAfter: 13)
        XCTAssertEqual(CallLive.stage(of: over, paused: false, outcome: nil), .writing)
        XCTAssertEqual(CallLive.stage(of: over, paused: false, outcome: .saved(.notes, todos: 2)), .ready(todos: 2))
        XCTAssertEqual(CallLive.stage(of: over, paused: false, outcome: .saved(.tooLittleSaid, todos: 0)),
                       .tooLittleSaid)
        XCTAssertEqual(CallLive.stage(of: over, paused: false, outcome: .failed("Couldn't save the notes.")),
                       .failed("Couldn't save the notes."))
        XCTAssertEqual(CallLive.stage(of: over, paused: false, outcome: .saved(.later, todos: 0)), .later)
    }

    /// A Mac that can't write notes, waiting to write them online, says the
    /// call is saved and its notes come later, never that they are ready.
    func testACallWhoseNotesComeLaterIsNotReady() {
        let over = record(endedAfter: 13)
        let waiting = MeetingNotesWriter.noNotes(.failed, at: start, notBefore: start.addingTimeInterval(3_600))
        XCTAssertEqual(CallNotesPanel.ready(of: over, notes: nil, writer: waiting), .later)
        XCTAssertEqual(CallNotesPanel.ready(of: over, notes: nil, writer: .mac(at: start, waitsForOnline: true)),
                       CallNotesPanel.ready(of: over, notes: nil), "the Mac's own notes are ready as before")
        XCTAssertEqual(CallNotesPanel.ready(of: over, notes: nil, writer: CloudNotesRedo.stopped(waiting)),
                       CallNotesPanel.ready(of: over, notes: nil), "and so is a page that stopped waiting")
        XCTAssertNil(CallNotesPanel.readyNotice(of: over, ready: .later, todos: 0),
                     "no \"Call notes ready\" until they are")
        XCTAssertEqual(CallNotesPanel.notesLater, "Call saved, notes later")
    }

    func testAnOutcomeNeverSpeaksForACallStillOn() {
        // A call that came back carries on: whatever its notes were, it is live.
        XCTAssertEqual(CallLive.stage(of: record(), paused: false, outcome: .saved(.notes, todos: 3)), .listening)
    }

    func testNotesThatStopMidCallSaySoAtOnce() {
        XCTAssertEqual(CallLive.stage(of: record(), paused: false, outcome: .failed("No speech model.")),
                       .failed("No speech model."))
    }

    func testACallTooShortToKeepSaysSoWhateverElse() {
        let short = record(endedAfter: 0.5, dropped: true)
        XCTAssertEqual(CallLive.stage(of: short, paused: false, outcome: nil), .tooShort)
        XCTAssertEqual(CallLive.stage(of: short, paused: true, outcome: .saved(.notes, todos: 1)), .tooShort)
    }

    func testOnlyTheListeningStagesAreLive() {
        XCTAssertTrue(CallLive.Stage.listening.isLive)
        XCTAssertTrue(CallLive.Stage.paused.isLive)
        XCTAssertFalse(CallLive.Stage.writing.isLive)
        XCTAssertFalse(CallLive.Stage.ready(todos: 0).isLive)
        XCTAssertFalse(CallLive.Stage.tooShort.isLive)
    }

    func testTheClockReadsLikeTheTimeOfALine() {
        let call = record()
        XCTAssertEqual(CallLive.clock(call, now: start.addingTimeInterval(761)), "12:41")
        XCTAssertEqual(CallLive.clock(call, now: start.addingTimeInterval(3_725)), "1:02:05")
        // A clock a moment behind the start never reads negative.
        XCTAssertEqual(CallLive.clock(call, now: start.addingTimeInterval(-2)), "0:00")
    }

    func testHowLongSoFarAndOnceEnded() {
        XCTAssertEqual(CallLive.soFar(record(), now: start.addingTimeInterval(13 * 60 + 10)), "13 min so far")
        XCTAssertEqual(CallLive.soFar(record(), now: start.addingTimeInterval(5)), "1 min so far")
        XCTAssertEqual(CallLive.endedLine(record(endedAfter: 13)), "Call ended · 13 min")
        XCTAssertNil(CallLive.endedLine(record()))
    }

    func testNewLinesCountsInWords() {
        XCTAssertEqual(CallLive.newLines(1), "1 new line")
        XCTAssertEqual(CallLive.newLines(3), "3 new lines")
    }

    func testReadyDetailSpellsSmallCounts() {
        XCTAssertEqual(CallLive.readyDetail(todos: 0), "A summary of what was said.")
        XCTAssertEqual(CallLive.readyDetail(todos: 1), "A summary and one to-do from this call.")
        XCTAssertEqual(CallLive.readyDetail(todos: 2), "A summary and two to-dos from this call.")
        XCTAssertEqual(CallLive.readyDetail(todos: 10), "A summary and ten to-dos from this call.")
        XCTAssertEqual(CallLive.readyDetail(todos: 14), "A summary and 14 to-dos from this call.")
    }

    func testJustSaidIsTheLastFewSecondsAfterALineEnds() {
        let call = record()
        let turn = call.segments[1]
        let ended = start.addingTimeInterval(turn.end)
        XCTAssertTrue(CallLive.isJustSaid(turn, in: call, now: ended.addingTimeInterval(3)))
        XCTAssertTrue(CallLive.isJustSaid(turn, in: call, now: ended.addingTimeInterval(CallLive.justNow - 1)))
        XCTAssertFalse(CallLive.isJustSaid(turn, in: call, now: ended.addingTimeInterval(CallLive.justNow + 1)))
    }

    func testOnlySpeechCountsAsALine() {
        var call = record()
        call.jot("Ask about pricing", at: 8)
        call.pause(at: 20)
        call.resume(at: 40)
        let entries = MeetingTimeline.entries(of: call)
        XCTAssertGreaterThan(entries.count, 2)
        XCTAssertEqual(CallLive.spokenCount(entries), 2)
    }

    func testTheEndOfAScrollAllowsAFewPointsShort() {
        XCTAssertTrue(CallLive.isAtEnd(offset: 600, visible: 400, content: 1_000))
        XCTAssertTrue(CallLive.isAtEnd(offset: 580, visible: 400, content: 1_000))
        XCTAssertFalse(CallLive.isAtEnd(offset: 500, visible: 400, content: 1_000))
        // Content shorter than the view is always at its end.
        XCTAssertTrue(CallLive.isAtEnd(offset: 0, visible: 400, content: 200))
    }

    // MARK: Words being heard

    func testYouAreDrawnFirstAndASideSayingNothingIsLeftOut() {
        let now = Date()
        let heard = CallLive.speaking([.them: .init(speaker: .them, text: "so the plan is", since: now),
                                       .me: .init(speaker: .me, text: "right", since: now)])
        XCTAssertEqual(heard.map(\.speaker), [.me, .them])
        XCTAssertEqual(CallLive.speaking([.me: .init(speaker: .me, text: "", since: now),
                                          .them: .init(speaker: .them, text: "and then", since: now)])
                        .map(\.speaker), [.them])
        XCTAssertTrue(CallLive.speaking([:]).isEmpty)
    }

    func testNothingIsShownBeingHeardWhilePaused() {
        let heard = CallLive.Hearing(speaker: .me, text: "this is off the record", since: Date())
        XCTAssertTrue(CallLive.speaking([.me: heard], paused: true).isEmpty)
    }

    func testWordsCarryOnTheirSidesLastTurnUntilALongSilence() {
        let start = Date(timeIntervalSince1970: 1_000)
        let turn = MeetingSegment(speaker: .me, start: 10, end: 20, text: "Okay, so this is the test.")
        let entries: [MeetingTimeline.Entry] = [.speech(turn, marked: false)]
        func hearing(_ speaker: MeetingSpeaker, at second: TimeInterval) -> CallLive.Hearing {
            .init(speaker: speaker, text: "and now", since: start.addingTimeInterval(second))
        }
        // A moment later, the same side: the end of that paragraph.
        XCTAssertTrue(CallLive.continues(hearing(.me, at: 23), after: entries, startedAt: start))
        // After a silence long enough to start a new turn: its own row.
        XCTAssertFalse(CallLive.continues(hearing(.me, at: 29), after: entries, startedAt: start))
        // The other side: its own row.
        XCTAssertFalse(CallLive.continues(hearing(.them, at: 21), after: entries, startedAt: start))
        // A note typed since: its own row, under the note.
        let jot = MeetingJot(at: 21, text: "Ask about the budget")
        XCTAssertFalse(CallLive.continues(hearing(.me, at: 22), after: entries + [.jot(jot)], startedAt: start))
        XCTAssertFalse(CallLive.continues(hearing(.me, at: 1), after: [], startedAt: start))
    }

    func testOnlyTheFirstOfAPersonsLinesInARowHasTheirFaceAndName() {
        let start = Date(timeIntervalSince1970: 1_000)
        func turn(_ speaker: MeetingSpeaker, _ from: TimeInterval, _ to: TimeInterval) -> MeetingTimeline.Entry {
            .speech(MeetingSegment(speaker: speaker, start: from, end: to, text: "Words."), marked: false)
        }
        let call = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start)
        let entries = [turn(.me, 0, 5), turn(.me, 20, 25), turn(.them, 30, 35), turn(.them, 50, 55),
                       .jot(MeetingJot(at: 56, text: "Budget")), turn(.them, 60, 65),
                       turn(.them, 65 + CallLive.regroup + 1, 400 + CallLive.regroup)]
        XCTAssertEqual(CallLive.headed(entries, in: call).entries, [true, false, true, false, true, true, true])

        // Words being said: under the last line when the same person is
        // saying them, after one another when both sides are.
        let after = entries.prefix(4).map { $0 }
        let them = CallLive.Hearing(speaker: .them, text: "and", since: start.addingTimeInterval(70))
        let me = CallLive.Hearing(speaker: .me, text: "so", since: start.addingTimeInterval(71))
        XCTAssertEqual(CallLive.headed(after, hearing: [them, me], in: call).hearing, [false, true])
        XCTAssertEqual(CallLive.headed(after, hearing: [me, them], in: call).hearing, [true, true])
        XCTAssertEqual(CallLive.headed([], hearing: [me], in: call).hearing, [true])

        // In a room both sides are "Someone": one face for the run, again
        // every few minutes so the lines still say when.
        let room = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: start)
        XCTAssertEqual(CallLive.headed([turn(.me, 0, 5), turn(.them, 6, 9)], in: room).entries, [true, false])
        let talk = stride(from: 0.0, through: 400, by: 100).map { turn(.them, $0, $0 + 90) }
        XCTAssertEqual(CallLive.headed(talk, in: room).entries, [true, false, false, false, true])
    }

    func testHeldLinesShowWhereTheyWereSaidAmongTheOtherSidesTurns() {
        // A back-and-forth where "you" say little, so your language is
        // still being decided: your lines are held. Shown as one block
        // under everything, their three lines ran into one turn.
        let them = [MeetingSegment(speaker: .them, start: 1, end: 4, text: "Hola, ¿qué tal el contrato?"),
                    MeetingSegment(speaker: .them, start: 9, end: 12, text: "Vale, lo miro mañana."),
                    MeetingSegment(speaker: .them, start: 17, end: 20, text: "Perfecto, hablamos.")]
        let call = MeetingRecord(bundleID: "com.google.Chrome", appName: "Google Chrome", startedAt: start,
                                 segments: them)
        let held = [MeetingSegment(speaker: .me, start: 5, end: 8, text: "Bien, te lo mando hoy."),
                    MeetingSegment(speaker: .me, start: 13, end: 16, text: "Genial, gracias.")]

        func speakers(_ record: MeetingRecord) -> [MeetingSpeaker] {
            MeetingTimeline.entries(of: record).compactMap { entry in
                guard case .speech(let turn, _) = entry else { return nil }
                return turn.speaker
            }
        }
        XCTAssertEqual(speakers(call), [.them])
        let shown = CallLive.withHeld(held, in: call)
        XCTAssertEqual(speakers(shown), [.them, .me, .them, .me, .them])
        XCTAssertEqual(shown.segments.map(\.start), [1, 5, 9, 13, 17])
        // Only shown: the call itself is unchanged, and none held is none added.
        XCTAssertEqual(call.segments, them)
        XCTAssertEqual(CallLive.withHeld([], in: call), call)
    }

    func testInProgressReadsTheHeldLinesThenTheGuess() {
        // Deciding the language, each recogniser holds its finished lines:
        // the take the screen follows is chosen on them and its guess.
        XCTAssertEqual(CallLive.inProgress(held: ["Okay, so this is the test.", "It works."], guess: "and now"),
                       "Okay, so this is the test. It works. and now")
        XCTAssertEqual(CallLive.inProgress(held: [], guess: "  every  word\nappears "), "every word appears")
        XCTAssertEqual(CallLive.inProgress(held: ["Done."], guess: ""), "Done.")
        XCTAssertEqual(CallLive.inProgress(held: [], guess: " "), "")
    }

    private func timed(_ words: String, from start: TimeInterval, every step: TimeInterval = 0.3)
        -> [CallLanguageFollow.Timed] {
        // As the recogniser gives them: a leading space on all but the first.
        words.split(separator: " ").enumerated().map { index, word in
            let begin = start + Double(index) * step
            return CallLanguageFollow.Timed(text: (index == 0 ? "" : " ") + word, start: begin, end: begin + step)
        }
    }

    func testTheFastWordsShowUntilTheNotesHaveThem() {
        // Nothing finished for the notes yet: every fast word, then the guess.
        let said = timed("Hola, ¿qué tal?", from: 10)
        XCTAssertEqual(CallLive.unfinished(said: said, guess: "Oye, quería", guessStart: 10.9,
                                           finished: [], through: -.infinity),
                       "Hola, ¿qué tal? Oye, quería")
        // The notes' line for the first two words arrives: they leave the
        // screen, a word placed a little apart included.
        let notes = timed("Hola, qué", from: 10.04)
        XCTAssertEqual(CallLive.unfinished(said: said, guess: "Oye, quería", guessStart: 10.9,
                                           finished: notes, through: 10.64),
                       "tal? Oye, quería")
        // All of it: only the guess is left.
        XCTAssertEqual(CallLive.unfinished(said: said, guess: "Oye, quería", guessStart: 10.9,
                                           finished: notes, through: 10.9),
                       "Oye, quería")
        // Everything said is a line: nothing is shown.
        XCTAssertEqual(CallLive.unfinished(said: said, guess: "", guessStart: nil, finished: notes, through: 11),
                       "")
        // A full stop that came on its own sits on the word before it.
        let stop = [CallLanguageFollow.Timed(text: " nosotros", start: 24.0, end: 24.6),
                    CallLanguageFollow.Timed(text: ".", start: 24.66, end: 25.02)]
        XCTAssertEqual(CallLive.unfinished(said: stop, guess: "", guessStart: nil, finished: [], through: 20),
                       "nosotros.")
    }

    func testAFastWordAcrossTheLinesEndIsFinishedOnlyIfTheLineHasIt() {
        func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> CallLanguageFollow.Timed {
            CallLanguageFollow.Timed(text: text, start: start, end: end)
        }
        let notes = [word(" next", 3.60, 3.90), word(" week.", 3.90, 4.14)]
        // Inside the line: finished.
        XCTAssertTrue(CallLive.isFinished(word(" next", 3.62, 3.88), by: notes, through: 4.14))
        // The sentence's last word stretched into the pause: still the
        // line's own word, so not shown twice.
        XCTAssertTrue(CallLive.isFinished(word(" week.", 3.90, 4.86), by: notes, through: 4.14))
        // Timed a little later than the notes' twin, without touching it.
        XCTAssertTrue(CallLive.isFinished(word(" next", 4.0, 4.2), by: notes, through: 4.14))
        // The next sentence's first word, begun early, even with most of it
        // before the line's end: not in the line, so it stays on screen.
        let spanish = [word(" tren", 17.0, 17.52), word(" mañana.", 17.52, 19.92)]
        XCTAssertFalse(CallLive.isFinished(word(" Vale,", 19.26, 20.40), by: spanish, through: 19.92))
        XCTAssertFalse(CallLive.isFinished(word(" Okay,", 15.12, 15.80), by: notes, through: 15.48))
        // Wholly after the line: not finished, whatever it says.
        XCTAssertFalse(CallLive.isFinished(word(" week.", 4.20, 4.50), by: notes, through: 4.14))
        // No times: never taken for finished.
        XCTAssertFalse(CallLive.isFinished(CallLanguageFollow.Timed(text: " week.", start: nil, end: nil),
                                           by: notes, through: 10))
    }

    func testTheGuessLosesTheWordsTheNotesFinishedFirst() {
        // The notes' recogniser finished past where the guess starts: the
        // guess's first words are those, and only the rest is shown.
        let notes = timed("Yo pensaba salir", from: 6.0)
        XCTAssertEqual(CallLive.unfinished(said: [], guess: "Yo pensaba salir el jueves", guessStart: 6.0,
                                           finished: notes, through: 6.9),
                       "el jueves")
        // A line wholly before the guess takes nothing from it.
        XCTAssertEqual(CallLive.unfinished(said: [], guess: "el jueves", guessStart: 7.0,
                                           finished: notes, through: 6.9),
                       "el jueves")
        // The guess has fewer words than the line covers: nothing left.
        XCTAssertEqual(CallLive.unfinished(said: [], guess: "Yo pensaba", guessStart: 6.0,
                                           finished: notes, through: 6.9),
                       "")
    }

    func testTheGuessIsCutWhereTheFinishedWordsEndNotJustByCount() {
        // Same count, same words: cut after them.
        XCTAssertEqual(CallLive.covered(["sí", "claro", "yo", "pensaba"], by: ["Sí,", "claro."]), 2)
        // The guess has a word the notes left out: cut where the last
        // finished word is, one further on.
        XCTAssertEqual(CallLive.covered(["vamos", "a", "dónde", "quieras", "mañana"], by: ["vamos", "dónde"]), 3)
        // The notes heard a word the guess missed: one sooner.
        XCTAssertEqual(CallLive.covered(["el", "fin", "de", "semana", "vale"], by: ["pues", "el", "fin", "de", "semana"]), 4)
        // No match nearby: by count, never past the guess.
        XCTAssertEqual(CallLive.covered(["uno", "dos", "tres"], by: ["a", "b"]), 2)
        XCTAssertEqual(CallLive.covered(["uno"], by: ["a", "b", "c"]), 1)
        XCTAssertEqual(CallLive.covered([], by: ["a"]), 0)
        XCTAssertEqual(CallLive.covered(["a"], by: []), 0)
        // A repeated word: the place nearest the count wins.
        XCTAssertEqual(CallLive.covered(["no", "no", "no", "no", "sé"], by: ["no", "no"]), 2)
    }

    func testASmallSpaceShowsTheNewestWordsFromAWordsStart() {
        XCTAssertEqual(CallLive.newest("short enough", limit: 40), "short enough")
        XCTAssertEqual(CallLive.newest("the quick brown fox jumps", limit: 12), "…fox jumps")
        // Cut right on a word's start: that word is kept whole.
        XCTAssertEqual(CallLive.newest("the quick brown fox", limit: 9), "…brown fox")
        // One long word: cut where it must be.
        XCTAssertEqual(CallLive.newest("supercalifragilistic", limit: 6), "…listic")
    }
}
