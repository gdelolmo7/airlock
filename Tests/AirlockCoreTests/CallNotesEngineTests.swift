import XCTest
@testable import AirlockCore

/// A small call to check notes against: Ana asks for the budget, you agree,
/// a decision, an open question.
private enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_791_468_600)

    static func record(attendees: [String] = ["Ana García"]) -> MeetingRecord {
        MeetingRecord(
            bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
            segments: [
                MeetingSegment(speaker: .them, start: 5, end: 12,
                               text: "Can you send me the budget by Friday?"),          // S1
                MeetingSegment(speaker: .me, start: 14, end: 18,
                               text: "Sure, I'll send it on Thursday."),                // S2
                MeetingSegment(speaker: .them, start: 30, end: 40,
                               text: "Good. Then we launch on the twentieth."),         // S3
                MeetingSegment(speaker: .me, start: 42, end: 50,
                               text: "Agreed. Who pays for the venue, though?"),        // S4
                MeetingSegment(speaker: .them, start: 52, end: 60,
                               text: "No idea yet. Luis, can you book the room?"),      // S5
                MeetingSegment(speaker: .them, start: 70, end: 75,
                               text: "I'll do it tomorrow."),                           // S6
            ],
            event: MeetingEvent(title: "Budget", start: start, attendees: attendees))
    }
}

final class NumberedTranscriptTests: XCTestCase {
    func testTurnsAreNumberedWithTimeSpeakerAndMarks() {
        var record = Fixture.record()
        record.mark(at: 20)
        let transcript = NumberedTranscript(record)
        XCTAssertEqual(transcript.turns.count, 6)
        XCTAssertEqual(transcript.turns[0].line, "[S1 0:05 Ana García, marked] Can you send me the budget by Friday?")
        XCTAssertEqual(transcript.turns[1].line, "[S2 0:14 You, marked] Sure, I'll send it on Thursday.")
        XCTAssertEqual(transcript.turns[2].line, "[S3 0:30 Ana García] Good. Then we launch on the twentieth.")
        XCTAssertEqual(transcript.turn(6)?.start, 70)
        XCTAssertNil(transcript.turn(0))
        XCTAssertNil(transcript.turn(7))
    }

    func testOnAGroupCallTheOtherSideIsThem() {
        let transcript = NumberedTranscript(Fixture.record(attendees: ["Ana García", "Luis Pérez"]))
        XCTAssertEqual(transcript.turns[0].prefix, "[S1 0:05 Them]")
    }

    func testCitationsAreReadLeniently() {
        for cited in ["S41", "s41", "[S41]", "41", " S41, ", "S41 9:31", "[S41 9:31 Person 4]", "S41, 9:31"] {
            XCTAssertEqual(NumberedTranscript.id(from: cited), 41, cited)
        }
        for cited in ["F3", "S", "", "S0", "S-2", "line 4", "9:31", "S41b", "Sam"] {
            XCTAssertNil(NumberedTranscript.id(from: cited), cited)
        }
    }

    func testWordsAreCounted() {
        XCTAssertEqual(NumberedTranscript(Fixture.record()).wordCount, 41)
        XCTAssertEqual(NumberedTranscript.words(in: "¿Me oyes? Sí, perfectamente."), 4)
    }

    func testAShortCallIsOnePart() {
        let transcript = NumberedTranscript(Fixture.record())
        let chunks = transcript.chunks()
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].ids, Set(1...6))
        XCTAssertEqual(chunks[0].text, transcript.turns.map(\.line).joined(separator: "\n"))
        XCTAssertEqual(chunks[0].start, 5)
        XCTAssertEqual(chunks[0].end, 75)
    }

    private func longTranscript(_ count: Int) -> NumberedTranscript {
        NumberedTranscript(turns: (1...count).map {
            .init(id: $0, speaker: $0.isMultiple(of: 2) ? .me : .them, label: $0.isMultiple(of: 2) ? "You" : "Them",
                  start: Double($0) * 10, end: Double($0) * 10 + 8,
                  text: "Sentence number \($0) about the plan for the launch and the budget.")
        })
    }

    func testPartsStayWithinTheBudgetAndKeepEveryLineInOrder() {
        let transcript = longTranscript(200)
        let chunks = transcript.chunks(budget: 1_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 1_000 })
        XCTAssertEqual(chunks.map(\.text).joined(separator: "\n"),
                       transcript.turns.map(\.line).joined(separator: "\n"))
        XCTAssertEqual(chunks.map(\.ids).reduce(Set<Int>()) { $0.union($1) }, Set(1...200))
    }

    func testTheLastPartIsNotALeftoverTail() {
        // Filled to the budget, thirteen lines went twelve and one: a last
        // part too short to make sense of on its own.
        let chunks = longTranscript(13).chunks(budget: 1_000)
        XCTAssertEqual(chunks.map(\.lines.count), [7, 6])
    }

    func testPartsAreAboutTheSameSize() {
        for budget in [1_000, 1_400, 4_800] {
            let sizes = longTranscript(200).chunks(budget: budget).map(\.text.count)
            // Each ends within half a line of its share, so none is a
            // fraction of another.
            XCTAssertGreaterThan(sizes.min()! * 5, sizes.max()! * 4, "\(budget): \(sizes)")
        }
    }

    func testEvenPartsTakeAtMostOneMoreThanFillingEachToTheBudget() {
        let transcript = longTranscript(200)
        let total = transcript.turns.reduce(0) { $0 + $1.line.count + 1 }
        for budget in [1_000, 1_400, 4_800] {
            let fewest = (total + budget - 1) / budget
            XCTAssertLessThanOrEqual(transcript.chunks(budget: budget).count, fewest + 1, "\(budget)")
        }
    }

    func testTheDefaultBudgetLeavesRoomInTheModelsWindow() {
        // About 1,600 tokens of transcript at three characters a token, the
        // rate measured on the model (`CallNotesModelProbe`).
        XCTAssertEqual(NumberedTranscript.chunkBudget, 4_800)
    }

    func testAnOverlongTurnIsCutBetweenWordsAndEveryPieceKeepsItsNumber() {
        let words = Array(repeating: "word", count: 400).joined(separator: " ")
        let transcript = NumberedTranscript(turns: [
            .init(id: 1, speaker: .them, label: "Them", start: 0, end: 300, text: words),
        ])
        let chunks = transcript.chunks(budget: 400)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 400 })
        XCTAssertTrue(chunks.allSatisfy { $0.ids == [1] && $0.text.hasPrefix("[S1 0:00 Them] ") })
        XCTAssertEqual(chunks.flatMap(\.lines).map(\.body).joined(separator: " "), words)
    }

    func testHalvingSplitsBetweenTurnsNearTheMiddle() {
        let chunk = longTranscript(10).chunks()[0]
        let halves = chunk.halved()
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(halves.map(\.lines.count), [5, 5])
        XCTAssertEqual(halves[0].ids.union(halves[1].ids), Set(1...10))

        let one = TranscriptChunk(lines: Array(chunk.lines.prefix(2))).halved()
        XCTAssertEqual(one.map(\.lines.count), [1, 1])
    }

    func testHalvingASingleTurnCutsItBetweenWords() {
        let words = Array(repeating: "palabra", count: 200).joined(separator: " ")
        let chunk = NumberedTranscript(turns: [
            .init(id: 7, speaker: .me, label: "You", start: 60, end: 200, text: words),
        ]).chunks()[0]
        let halves = chunk.halved()
        XCTAssertGreaterThanOrEqual(halves.count, 2)
        XCTAssertTrue(halves.allSatisfy { $0.ids == [7] && $0.text.count < chunk.text.count })
    }
}

final class MeetingPeopleTests: XCTestCase {
    private let people = MeetingPeople(others: ["Ana García", "Luis Pérez", "rooms@example.com", " "])

    func testOnlyRealNamesAreKept() {
        XCTAssertEqual(people.others, ["Ana García", "Luis Pérez"])
        XCTAssertNil(people.oneToOne)
        XCTAssertEqual(MeetingPeople(others: ["Ana García"]).oneToOne, "Ana García")
    }

    func testYouInEitherLanguage() {
        for said in ["You", "you", "Tú", "tu", "Usted", " you. "] {
            XCTAssertEqual(people.owner(said), "You", said)
        }
    }

    func testAnInvitedPersonByAnyOfTheirNames() {
        XCTAssertEqual(people.owner("Ana"), "Ana García")
        XCTAssertEqual(people.owner("ana garcia"), "Ana García")
        XCTAssertEqual(people.owner("García"), "Ana García")
        XCTAssertEqual(people.owner("Luis Pérez"), "Luis Pérez")
    }

    func testAnybodyElseIsNobody() {
        for said in ["", "  ", "Ana López", "Pedro", "Them", "unassigned", "Unassigned", "nobody", "None",
                     "N/A", "nadie", "Sin asignar", "the team", "everyone"] {
            XCTAssertNil(people.owner(said), said)
        }
    }

    func testTwoPeopleWithTheSameNameKeepItAsSaid() {
        let twoAnas = MeetingPeople(others: ["Ana García", "Ana Ruiz"])
        XCTAssertEqual(twoAnas.owner("Ana"), "Ana")
        XCTAssertEqual(twoAnas.owner("Ana Ruiz"), "Ana Ruiz")
    }

    func testThePromptNamesThePeople() {
        XCTAssertEqual(MeetingPeople(others: ["Ana García"]).promptLine,
                       "People on the call: You, and Ana García (the other side).")
        XCTAssertEqual(people.promptLine,
                       "People on the call: You, and Them (everyone else on the call). Invited: Ana García, Luis Pérez.")
        XCTAssertEqual(MeetingPeople(others: []).promptLine,
                       "People on the call: You, and Them (everyone else on the call).")
    }
}

final class MeetingLedgerTests: XCTestCase {
    private typealias Fact = MeetingDraft.Fact
    private typealias Todo = MeetingDraft.Todo
    private let all = Set(1...6)

    private func ledger(attendees: [String] = ["Ana García"]) -> MeetingLedger {
        MeetingLedger(record: Fixture.record(attendees: attendees))
    }

    func testALineMustCiteATurnItWasShown() {
        var ledger = ledger()
        let tally = ledger.add(MeetingDraft(decisions: [
            Fact(text: "Launch on the twentieth", sources: ["S3", "S99"]),
            Fact(text: "Move the office", sources: ["S42"]),
            Fact(text: "Hire Ana", sources: []),
            Fact(text: "Cut the price", sources: ["S1"]),
        ]), shown: [2, 3])
        XCTAssertEqual(tally, .init(kept: 1, dropped: 3))
        XCTAssertEqual(ledger.decisions, [.init(text: "Launch on the twentieth", sources: [3], at: 30)])
    }

    func testAnOwnerMustBeSomebodyOnTheCall() {
        var ledger = ledger()
        ledger.add(MeetingDraft(todos: [
            Todo(task: "Send the budget", owner: "You", sources: ["S2"]),
            Todo(task: "Review the numbers", owner: "Ana", sources: ["S1"]),
            Todo(task: "Call the bank", owner: "Pedro", sources: ["S2"]),
            Todo(task: "Order food", owner: "unassigned", sources: ["S3"]),
        ]), shown: all)
        XCTAssertEqual(ledger.todos.map(\.owner), ["You", "Ana García", nil, nil])
    }

    /// On a group call the other side is "Them": a name is only believed
    /// when it is said in or next to the lines cited.
    func testANameIsOnlyBelievedWhereItIsHeard() {
        var ledger = ledger(attendees: ["Ana García", "Luis Pérez"])
        ledger.add(MeetingDraft(todos: [
            Todo(task: "Book the room", owner: "Luis", sources: ["S6"]),
            Todo(task: "Find a caterer", owner: "Ana", sources: ["S4"]),
        ]), shown: all)
        XCTAssertEqual(ledger.todos.map(\.owner), ["Luis Pérez", nil],
                       "Luis is asked in S5, right before S6; nobody says Ana near S4")
    }

    func testYouMustBeHeardNearTheLinesToo() {
        var ledger = ledger(attendees: ["Ana García", "Luis Pérez"])
        ledger.add(MeetingDraft(todos: [Todo(task: "Book the room", owner: "You", sources: ["S6"])]),
                   shown: all)
        XCTAssertEqual(ledger.todos.map(\.owner), [nil])
    }

    func testADueDateIsKeptOnlyInTheCallsWords() {
        var ledger = ledger()
        ledger.add(MeetingDraft(todos: [
            Todo(task: "Send the budget.", owner: "You", due: "by Friday", sources: ["S1", "S2"]),
            Todo(task: "Book the room", due: "October 10", sources: ["S6"]),
            Todo(task: "Pay the venue tomorrow", due: "tomorrow", sources: ["S6"]),
            Todo(task: "Check the venue", due: "none", sources: ["S4"]),
        ]), shown: all)
        XCTAssertEqual(ledger.todos.map(\.text),
                       ["Send the budget by Friday", "Book the room", "Pay the venue tomorrow", "Check the venue"])
    }

    /// A due in parts ("today; before the first of November") adds only the
    /// parts the task doesn't already say, never the whole due again.
    func testADueInPartsAddsOnlyWhatTheTaskLeavesOut() {
        let cases = [
            ("Send the budget on Thursday, by Friday at the latest", "on Thursday; by Friday",
             "Send the budget on Thursday, by Friday at the latest"),
            ("Send the budget by Friday.", "on Thursday; by Friday", "Send the budget by Friday on Thursday"),
            ("Send the budget", "on Thursday; by Friday", "Send the budget on Thursday; by Friday"),
        ]
        for (task, due, kept) in cases {
            var ledger = ledger()
            ledger.add(MeetingDraft(todos: [Todo(task: task, due: due, sources: ["S1", "S2"])]), shown: all)
            XCTAssertEqual(ledger.todos.map(\.text), [kept], task)
        }
    }

    func testADueDateMustNameATime() {
        let turns = [NumberedTranscript.Turn(
            id: 1, speaker: .them, label: "Person 1", start: 0, end: 5,
            text: "Normalmente lo miro el viernes, o mañana, y si no hay tiempo, ¿para el día 15?")]
        for due in ["el viernes", "mañana", "el 15", "antes del día 15"] {
            XCTAssertTrue(MeetingLedger.isSaid(due, in: turns), due)
        }
        for due in ["Normalmente", "si no hay tiempo", "¿para el día 15?"] {
            XCTAssertFalse(MeetingLedger.isSaid(due, in: turns), due)
        }
    }

    /// From a meeting in the room the model listed who explained what as
    /// to-dos. Somebody, then "explica", is the meeting itself; a task as
    /// to-dos are written, starting with what to do, stays, and so does
    /// one with a date that was said.
    func testWhoExplainedWhatInTheMeetingIsNoToDo() {
        let record = MeetingRecord(
            bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: Fixture.start,
            segments: [
                MeetingSegment(speaker: .them, start: 10, end: 20,
                               text: "No sé si os conviene que Lucía empiece a contaros cómo trabaja.",
                               person: 2),                                                         // S1
                MeetingSegment(speaker: .them, start: 27, end: 40,
                               text: "Yo lo que haría primero es que nos explique el proceso.",
                               person: 3),                                                         // S2
                MeetingSegment(speaker: .them, start: 47, end: 90,
                               text: "Bueno, lo que es la parte de compras. Todo entra en el CRM.",
                               person: 4),                                                         // S3
                MeetingSegment(speaker: .them, start: 95, end: 99,
                               text: "Ana presenta el presupuesto y las cifras el viernes.",
                               person: 1),                                                         // S4
            ],
            event: MeetingEvent(title: "", start: Fixture.start, attendees: ["Ana García"]))
        var ledger = MeetingLedger(record: record)
        let tally = ledger.add(MeetingDraft(todos: [
            Todo(task: "Lucía explica cómo trabaja", sources: ["S1"]),
            Todo(task: "Person 3 explica el proceso.", sources: ["S2"]),
            Todo(task: "Persona 4 presenta la parte de compras", sources: ["S3"]),
            Todo(task: "Ana presenta el presupuesto", sources: ["S4"]),
            Todo(task: "Ana presenta las cifras", due: "el viernes", sources: ["S4"]),
            Todo(task: "Explicar el proceso a Lucía", sources: ["S2"]),
            Todo(task: "El CRM presenta los pedidos por taller", sources: ["S3"]),
            Todo(task: "Mark explains the roadmap", sources: ["S3"]),
        ]), shown: Set(1...4))
        XCTAssertEqual(tally, .init(kept: 4, dropped: 4))
        XCTAssertEqual(ledger.todos.map(\.text), [
            "Ana presenta las cifras el viernes", "Explicar el proceso a Lucía",
            "El CRM presenta los pedidos por taller", "Mark explains the roadmap",
        ], "a thing is nobody, and so is a name never said")
    }

    func testANameIsSaidWithACapitalWhereNoSentenceStarts() {
        func lines(_ text: String) -> [NumberedTranscript.Turn] {
            [NumberedTranscript.Turn(id: 1, speaker: .them, label: "Person 1", start: 0, end: 5, text: text)]
        }
        let said = lines("Enviar esto ya. Que lo mire Pablo, o quien sea.")
        XCTAssertTrue(MeetingLedger.isNameSaid("Pablo", in: said))
        XCTAssertFalse(MeetingLedger.isNameSaid("Enviar", in: said), "a turn starts with it")
        XCTAssertFalse(MeetingLedger.isNameSaid("Que", in: said), "a sentence starts with it")
        XCTAssertFalse(MeetingLedger.isNameSaid("pablo", in: said), "a name has a capital")
    }

    func testRepeatsAcrossPartsAreKeptOnce() {
        var ledger = ledger()
        ledger.add(MeetingDraft(todos: [Todo(task: "Send the budget", sources: ["S1"])]), shown: [1, 2, 3])
        let tally = ledger.add(MeetingDraft(
            decisions: [Fact(text: "Send the budget.", sources: ["S5"])],
            todos: [Todo(task: "send the budget!", owner: "You", sources: ["S2"])],
            topics: [Fact(text: "Venue", sources: ["S4"]), Fact(text: "venue", sources: ["S5"])]
        ), shown: [2, 4, 5])
        XCTAssertEqual(tally, .init(kept: 1, dropped: 3))
        XCTAssertEqual(ledger.todos, [.init(text: "Send the budget", owner: "You", sources: [1], at: 5)])
        XCTAssertTrue(ledger.decisions.isEmpty, "a decision that repeats a to-do is dropped")
        XCTAssertEqual(ledger.topics.map(\.text), ["Venue"])
    }

    /// Seen on a long call: one list repeated the same two lines until the
    /// answer ran out of room. However many times a line comes back, and in
    /// whatever case, it is kept once.
    func testALoopingListKeepsEachLineOnce() {
        var ledger = ledger()
        let loop = (0..<40).map { index in
            Fact(text: index % 2 == 0 ? "The launch date" : "THE VENUE.", sources: [index % 2 == 0 ? "S3" : "S4"])
        }
        let tally = ledger.add(MeetingDraft(topics: loop), shown: all)
        XCTAssertEqual(tally, .init(kept: 2, dropped: 38))
        XCTAssertEqual(ledger.topics.map(\.text), ["The launch date", "THE VENUE"])
    }

    func testADecisionLaterFiledAsAToDoIsKeptOnlyAsTheToDo() {
        var ledger = ledger()
        ledger.add(MeetingDraft(decisions: [Fact(text: "Book the room", sources: ["S5"])]), shown: all)
        ledger.add(MeetingDraft(todos: [Todo(task: "Book the room", sources: ["S6"])]), shown: all)
        let notes = ledger.notes()
        XCTAssertEqual(notes.todos.map(\.text), ["Book the room"])
        XCTAssertTrue(notes.decisions.isEmpty)
    }

    func testAnOpenQuestionMustBeAQuestion() {
        var ledger = ledger()
        let tally = ledger.add(MeetingDraft(questions: [
            Fact(text: "Who pays for the venue?", sources: ["S4"]),
            Fact(text: "¿Quién paga el catering", sources: ["S4"]),
            Fact(text: "Somebody needs to book the room", sources: ["S5"]),
        ]), shown: all)
        XCTAssertEqual(tally, .init(kept: 2, dropped: 1))
        XCTAssertEqual(ledger.questions.map(\.text), ["Who pays for the venue?", "¿Quién paga el catering"])
        XCTAssertTrue(MeetingText.isQuestion("会場は誰が払いますか？"))
        XCTAssertFalse(MeetingText.isQuestion("Book the room"))
    }

    func testAnOpenQuestionIsCutAtItsQuestionMarkAndIsMoreThanAWordOrTwo() {
        XCTAssertEqual(MeetingText.openQuestion("Who pays for the venue? Ana didn't know."), "Who pays for the venue?")
        XCTAssertEqual(MeetingText.openQuestion("¿Quién paga? ¿Y cuándo llega?"), "¿Quién paga? ¿Y cuándo llega?")
        XCTAssertEqual(MeetingText.openQuestion("¿Quién paga el catering"), "¿Quién paga el catering")
        XCTAssertEqual(MeetingText.openQuestion("会場は誰が払いますか？"), "会場は誰が払いますか？")
        for text in ["¿En qué?", "¿Qué pasa? Porque yo así puedo sacar un listado", "Why?", "Book the room"] {
            XCTAssertNil(MeetingText.openQuestion(text), text)
        }
    }

    /// Questions that were real in the room and mean nothing on the page
    /// a week later, next to ones that say what they are about.
    func testAnOpenQuestionMustSayWhatItIsAbout() {
        for text in ["How long do you wait?", "What happens if it doesn't all arrive?", "Anything else before we go?",
                     "¿Y eso cuándo llega?", "¿Qué pasa si no llegan a tiempo?", "¿Cómo lo hacemos entonces?"] {
            XCTAssertNil(MeetingText.openQuestion(text), text)
        }
        for text in ["When is the launch?", "Who books the room?", "¿Qué es un CRM?", "Can we do 3 a week?",
                     "¿Cuánto cuesta el plan anual?", "Does Marta know yet?", "Qui paie la salle ?"] {
            XCTAssertEqual(MeetingText.openQuestion(text), text)
        }
    }

    /// "I'll book the room" filed as a decision next to the to-do it is,
    /// as the model did on a Spanish test call.
    func testADecisionThatOnlyRestatesAToDoFromTheSameMomentGoes() {
        var ledger = ledger()
        let tally = ledger.add(MeetingDraft(
            decisions: [Fact(text: "Luis will book the room", sources: ["S6"]),
                        Fact(text: "Book the room for the launch party", sources: ["S3"])],
            todos: [Todo(task: "Book the room tomorrow", sources: ["S5", "S6"])]
        ), shown: all)
        XCTAssertEqual(tally, .init(kept: 2, dropped: 1))
        XCTAssertEqual(ledger.decisions.map(\.text), ["Book the room for the launch party"],
                       "same words, but from another moment of the call: kept")

        var later = self.ledger()
        later.add(MeetingDraft(decisions: [Fact(text: "Yo me encargo de reservar la sala", sources: ["S6"])]),
                  shown: all)
        later.add(MeetingDraft(todos: [Todo(task: "Reservar la sala", sources: ["S6"])]), shown: all)
        XCTAssertEqual(later.decisions.count, 1)
        XCTAssertTrue(later.notes().decisions.isEmpty, "found as a to-do in a later part: the decision goes")
    }

    func testAQuestionAskedAgainFromTheSameLineIsKeptOnce() {
        var ledger = ledger()
        let tally = ledger.add(MeetingDraft(questions: [
            Fact(text: "¿Cuántos proveedores tienes?", sources: ["S4"]),
            Fact(text: "¿Con cuántos proveedores tienes?", sources: ["S4"]),
            Fact(text: "¿Cuántos proveedores tienes?", sources: ["S5"]),
            Fact(text: "¿Quién paga eso?", sources: ["S4"]),
            Fact(text: "¿Quién paga eso de la sala?", sources: ["S5"]),
        ]), shown: all)
        XCTAssertEqual(tally, .init(kept: 3, dropped: 2))
        XCTAssertEqual(ledger.questions.map(\.text),
                       ["¿Cuántos proveedores tienes?", "¿Quién paga eso?", "¿Quién paga eso de la sala?"],
                       "a longer question from another line is another question")
    }

    func testSameThingNeedsMostOfTheMeaningfulWords() {
        XCTAssertTrue(MeetingText.sameThing("Yo me encargo de reservar la sala", "Reservar la sala antes del viernes"))
        XCTAssertFalse(MeetingText.sameThing("Launch without the blog and add it in November",
                                             "Write the blog posts for the launch"))
        XCTAssertFalse(MeetingText.sameThing("Yes", "Book the room"))
    }

    func testALaterPartSayingTheSameThingInOtherWordsIsNotKeptAgain() {
        var ledger = ledger()
        ledger.add(MeetingDraft(todos: [Todo(task: "Send the budget to the client", sources: ["S2"])],
                                topics: [Fact(text: "The venue for the launch", sources: ["S4"])]),
                   shown: all)
        let later = ledger.add(MeetingDraft(todos: [Todo(task: "Budget: send it to the client", owner: "Ana García",
                                                         sources: ["S5"])],
                                            topics: [Fact(text: "Where the launch venue will be", sources: ["S6"])]),
                               shown: all)
        XCTAssertEqual(later.dropped, 2)
        XCTAssertEqual(ledger.todos.map(\.text), ["Send the budget to the client"])
        XCTAssertEqual(ledger.topics.map(\.text), ["The venue for the launch"])
    }

    func testTwoLikeLinesFromOnePartAreBothKept() {
        var ledger = ledger()
        let tally = ledger.add(MeetingDraft(todos: [Todo(task: "Send the budget to Ana", sources: ["S2"]),
                                                    Todo(task: "Send the budget to Luis", sources: ["S2"])]),
                               shown: all)
        XCTAssertEqual(tally.kept, 2)
    }

    /// One task written twice from the same moment, the second time with
    /// more said, is one to-do in the words that say more. Two that each
    /// say something the other doesn't stay two.
    func testOneTaskWrittenTwiceFromTheSameMomentIsOneToDo() {
        var ledger = ledger()
        let tally = ledger.add(MeetingDraft(todos: [
            Todo(task: "Book the room", sources: ["S5"]),
            Todo(task: "Book the big room upstairs", sources: ["S5", "S6"]),
            Todo(task: "Send the report to finance", sources: ["S1"]),
            Todo(task: "Send the report to legal", sources: ["S1"]),
            Todo(task: "Order chairs for one table", sources: ["S3"]),
            Todo(task: "Order chairs for another table", sources: ["S3"]),
            Todo(task: "Revisar el contrato", sources: ["S4"]),
            Todo(task: "Revisar el contrato con el abogado", sources: ["S4"]),
        ]), shown: all)
        XCTAssertEqual(tally, .init(kept: 5, dropped: 3))
        XCTAssertEqual(ledger.todos.map(\.text), ["Book the big room upstairs", "Send the report to finance",
                                                  "Send the report to legal", "Order chairs for one table",
                                                  "Revisar el contrato con el abogado"])
        XCTAssertEqual(ledger.todos[0].sources, [5, 6])
        XCTAssertEqual(ledger.todos[0].at, 52)
    }

    /// The same words from different moments of one part are two to-dos:
    /// a task can come up twice.
    func testOneTaskInsideAnotherIsOnlyMergedFromTheSameMoment() {
        var ledger = ledger()
        ledger.add(MeetingDraft(todos: [Todo(task: "Book the room", sources: ["S1"]),
                                        Todo(task: "Book the big room upstairs", sources: ["S5"])]), shown: all)
        XCTAssertEqual(ledger.todos.count, 2)
    }

    func testTheFinalStepReadsNumberedFactsAgreedThingsFirst() {
        var ledger = ledger()
        ledger.add(MeetingDraft(decisions: [Fact(text: "Launch on the twentieth", sources: ["S3"])],
                                todos: [Todo(task: "Send the budget", owner: "You", sources: ["S2"])],
                                questions: [Fact(text: "Who pays for the venue?", sources: ["S4"])],
                                topics: [Fact(text: "The venue", sources: ["S4", "S5"])]),
                   shown: all)
        let list = ledger.factList()
        XCTAssertEqual(list.text, """
            F1 [decision] Launch on the twentieth
            F2 [to-do, You] Send the budget
            F3 [open question] Who pays for the venue?
            F4 [topic] The venue
            """)
        XCTAssertEqual(list.item("F2")?.text, "Send the budget")
        XCTAssertEqual(list.item("f4")?.text, "The venue")
        XCTAssertEqual(list.item("3")?.text, "Who pays for the venue?")
        XCTAssertNil(list.item("F9"))
        XCTAssertNil(list.item("S2"))
        XCTAssertEqual(list.topics, [4])

        let short = ledger.factList(limit: 120)
        XCTAssertEqual(short.items.map(\.text),
                       ["Launch on the twentieth", "Send the budget", "Who pays for the venue?"],
                       "the topic is what goes when the list is cut")
    }

    func testKeyPointsMustCiteTheFactsTheyComeFrom() {
        var ledger = ledger()
        ledger.add(MeetingDraft(decisions: [Fact(text: "Launch on the twentieth", sources: ["S3"])],
                                topics: [Fact(text: "The venue", sources: ["S4", "S5"])]),
                   shown: all)
        let list = ledger.factList()
        let points = ledger.keyPoints([
            Fact(text: "The venue is still open", sources: ["F2"]),
            Fact(text: "Launch is fixed and the venue is open", sources: ["F1", "F2"]),
            Fact(text: "Made up", sources: ["F7"]),
            Fact(text: "Cites the transcript instead", sources: ["S3"]),
            Fact(text: "Decided to launch on the twentieth", sources: ["F1"]),
        ], from: list)
        XCTAssertEqual(points, [
            .init(text: "The venue is still open", sources: [4, 5], at: 42),
            .init(text: "Launch is fixed and the venue is open", sources: [3, 4, 5], at: 30),
        ])
    }

    func testAKeyPointThatIsALineAboveAgainIsLeftOut() {
        var ledger = ledger()
        ledger.add(MeetingDraft(decisions: [Fact(text: "Se va a integrar la caja con el almacén", sources: ["S3"])],
                                todos: [Todo(task: "Preparar el pedido para la tienda", sources: ["S2"])],
                                questions: [Fact(text: "Who pays for the venue?", sources: ["S4"])],
                                topics: [Fact(text: "La caja y el almacén", sources: ["S1"])]),
                   shown: all)
        let list = ledger.factList()
        XCTAssertEqual(list.topics, [4])
        let points = ledger.keyPoints([
            Fact(text: "Se decidió integrar la caja con el almacén", sources: ["F1", "F4"]),
            Fact(text: "Se decidió preparar el pedido para la tienda", sources: ["F2", "F4"]),
            Fact(text: "The venue", sources: ["F3", "F4"]),
            Fact(text: "Se integra la caja con el almacén para no perder ventas", sources: ["F1", "F4"]),
        ], from: list)
        XCTAssertEqual(points.map(\.text), ["Se integra la caja con el almacén para no perder ventas"])
    }

    func testALineSaidAgainHasAtMostOneWordMore() {
        XCTAssertTrue(MeetingLedger.saysAgain("It was decided to launch on the twentieth", "Launch on the twentieth"))
        XCTAssertTrue(MeetingLedger.saysAgain("The budget", "Send the budget to Ana"))
        XCTAssertFalse(MeetingLedger.saysAgain("Launch is fixed and the venue is open", "Launch on the twentieth"))
        XCTAssertFalse(MeetingLedger.saysAgain("Launch on the twentieth, after the beta",
                                               "Launch on the twentieth"))
        XCTAssertFalse(MeetingLedger.saysAgain("Decided to send", "Send the budget to Ana and Luis"),
                       "one word more and half the line is a different line")
        XCTAssertFalse(MeetingLedger.saysAgain("Sí", "Launch on the twentieth"))
    }

    /// A key point that is a to-do with the verb made a noun says nothing new.
    func testALineSaidAgainInAnotherFormOfTheSameWordsIsSaidAgain() {
        XCTAssertTrue(MeetingLedger.saysAgain("Preparación de pedidos", "Preparar los pedidos para la tienda"))
        XCTAssertTrue(MeetingLedger.saysAgain("Invoice preparation", "Prepare the invoices for the shop"))
        XCTAssertFalse(MeetingLedger.saysAgain("Reunión mensual", "Preparar la reunión semanal"))
    }

    func testListLinesLoseTheirClosingFullStopOnly() {
        XCTAssertEqual(MeetingText.line("- Send the budget. "), "Send the budget")
        XCTAssertEqual(MeetingText.line("Who pays?"), "Who pays?")
        XCTAssertEqual(MeetingText.line("Wait for legal..."), "Wait for legal...")
        XCTAssertEqual(MeetingText.line("¡Hecho!"), "¡Hecho!")
        var ledger = ledger()
        ledger.add(MeetingDraft(decisions: [Fact(text: "Launch on the twentieth.", sources: ["S3"])]), shown: all)
        XCTAssertEqual(ledger.decisions.map(\.text), ["Launch on the twentieth"])
    }

    func testAtMostFiveTopicsStandInOneFromEachStretchOfTheMeeting() {
        func topic(_ text: String, _ at: TimeInterval) -> MeetingNotes.Item { .init(text: text, sources: [1], at: at) }
        let topics = [
            topic("Lighting for the dining room and the hall", 320),
            topic("Kitchen layout and where the oven goes", 10),
            topic("The budget", 60),
            topic("¿Qué es un PDF?", 100),
            topic("Lighting", 300),
            topic("Paint colours", 700),
            topic("Who delivers the tiles?", 900),
            topic("Tiles", 1_000),
            topic("Tiles from the old supplier, delivered late", 1_010),
            topic("Floor heating", 1_500),
            topic("Send the quote to Ana", 1_600),
            topic("Moving date", 2_000),
        ]
        let listed = [MeetingNotes.Item(text: "Send the quote to Ana", sources: [2], at: 1_600)]
        XCTAssertEqual(MeetingLedger.standIns(topics, besides: listed).map(\.text), [
            "Kitchen layout and where the oven goes", "Paint colours",
            "Tiles from the old supplier, delivered late", "Floor heating", "Moving date",
        ])
    }

    func testAFewTopicsStandInWithoutQuestionsOrRepeats() {
        let listed = [MeetingNotes.Item(text: "Send the quote to Ana", sources: [2], at: 20)]
        let topics = [MeetingNotes.Item(text: "Who pays?", sources: [1], at: 10),
                      MeetingNotes.Item(text: "The quote", sources: [2], at: 20),
                      MeetingNotes.Item(text: "The venue", sources: [3], at: 30)]
        XCTAssertEqual(MeetingLedger.standIns(topics, besides: listed).map(\.text), ["The venue"])
        XCTAssertEqual(MeetingLedger.standIns(Array(topics.prefix(2)), besides: listed).map(\.text),
                       ["Who pays?", "The quote"], "with nothing else left, they stay")
    }

    func testWithoutAFinalStepTheTopicsStandInAsKeyPoints() {
        var ledger = ledger()
        ledger.add(MeetingDraft(decisions: [Fact(text: "Launch on the twentieth", sources: ["S3"])],
                                topics: [Fact(text: "Room booking", sources: ["S5"]),
                                         Fact(text: "The budget", sources: ["S1"])]),
                   shown: all)
        let notes = ledger.notes()
        XCTAssertEqual(notes.summary, "")
        XCTAssertEqual(notes.keyPoints.map(\.text), ["The budget", "Room booking"], "in the order they were said")
        XCTAssertEqual(notes.decisions.map(\.at), [30])
    }

    func testTheSummaryIsAtMostThreeSentences() {
        let notes = ledger().notes(summary: "One. Two is here. Three! Four? Five.", keyPoints: [])
        XCTAssertEqual(notes.summary, "One. Two is here. Three!")
    }
}

final class CallNotesPromptsTests: XCTestCase {
    private func chunk(_ id: Int, from start: TimeInterval, to end: TimeInterval) -> TranscriptChunk {
        TranscriptChunk(lines: [.init(id: id, start: start, end: end, prefix: "[S\(id) 0:00 You]", body: "Hi")])
    }

    func testThePartPromptCarriesEverythingTheModelNeeds() {
        let chunks = NumberedTranscript(Fixture.record()).chunks()
        let prompt = CallNotesPrompts.facts(
            for: chunks[0], part: 2, of: 3, language: "Spanish",
            people: MeetingPeople(others: ["Ana García"]),
            jots: [MeetingJot(at: 12, text: "budget\nby Friday")])
        XCTAssertTrue(prompt.hasPrefix("Take notes from part 2 of 3 of this call. Write them in Spanish.\n"))
        XCTAssertTrue(prompt.contains("People on the call: You, and Ana García (the other side)."))
        XCTAssertTrue(prompt.contains(
            "The person wrote these during this part; they matter, make sure they are covered:\n- 0:12 budget by Friday"))
        XCTAssertTrue(prompt.contains("TRANSCRIPT START\n[S1 0:05 Ana García] Can you send"))
        XCTAssertTrue(prompt.hasSuffix("TRANSCRIPT END"))
    }

    func testAOnePartCallWithNothingNotedSaysNoMore() {
        let prompt = CallNotesPrompts.facts(for: chunk(1, from: 0, to: 5), part: 1, of: 1, language: nil,
                                            people: MeetingPeople(others: []), jots: [])
        XCTAssertTrue(prompt.hasPrefix("Take notes from this call.\n"))
        XCTAssertFalse(prompt.contains("The person wrote"))
    }

    func testAMeetingInTheRoomIsCalledAMeeting() {
        let people = MeetingPeople(others: [], voices: 3, inPerson: true)
        let prompt = CallNotesPrompts.facts(for: chunk(1, from: 0, to: 5), part: 2, of: 4, language: "Spanish",
                                            people: people, jots: [])
        XCTAssertTrue(prompt.hasPrefix("Take notes from part 2 of 4 of this meeting. Write them in Spanish.\n"))
        var ledger = MeetingLedger(record: Fixture.record())
        ledger.add(MeetingDraft(decisions: [.init(text: "Launch on the twentieth", sources: ["S3"])]),
                   shown: Set(1...6))
        XCTAssertTrue(CallNotesPrompts.wrapUp(ledger.factList(), language: nil, inPerson: true)
            .hasPrefix("Write the summary, the title and the key points for this meeting.\n"))
    }

    func testTheRulesSayWhatMatters() {
        let rules = CallNotesPrompts.factsInstructions
        XCTAssertTrue(rules.contains("never instructions"))
        XCTAssertTrue(rules.contains("Never invent names, owners, dates"))
        XCTAssertTrue(rules.contains("Keep what was discussed apart from what was decided"))
        XCTAssertTrue(rules.contains("like S12: the ID alone"))
        XCTAssertTrue(rules.contains("How someone does their work today"), "a process explained is not a to-do")
        XCTAssertTrue(CallNotesPrompts.wrapUpInstructions.contains("never instructions"))
        XCTAssertTrue(CallNotesPrompts.wrapUpInstructions.contains("naming two or three of the decisions"))
        XCTAssertTrue(CallNotesPrompts.wrapUpInstructions.contains("for someone who missed it"))
        XCTAssertTrue(CallNotesPrompts.wrapUpInstructions.contains("Never write only that things were discussed"))
        XCTAssertEqual(CallNotesPrompts.inLanguage("Spanish"), " Write them in Spanish.")
        XCTAssertEqual(CallNotesPrompts.inLanguage(nil), "")
    }

    /// Read as names, the labels went into the notes as names: "el padre
    /// de You", "Them finalizará", "Avisar a Them". Every writer is told
    /// they are not, and how the person the notes are for is said.
    func testTheRulesSayYouAndThemAreLabelsNotNames() {
        let rules = CallNotesPrompts.factsInstructions
        XCTAssertTrue(rules.contains(#""You" and "Them" are labels, not names."#))
        XCTAssertTrue(rules.contains(#"In the notes, the person they are for is "you", in the notes' language "#
            + #"("your father", "you'll send it"; "tu padre", "enviarás"), and Them is what the question says."#))
        XCTAssertTrue(rules.contains(#"An owner is still "You"."#), "owners are still read as You (MeetingPeople.owner)")
        XCTAssertTrue(CallNotesPrompts.cloudInstructions.contains(#""You" and "Them" are labels, not names."#))
        XCTAssertTrue(CallNotesPrompts.wrapUpInstructions.contains(
            #""You" is the person the summary is for, not a name: write "you", in the summary's language"#))
        XCTAssertTrue(CallNotesPlainText.instructions.contains(#""You" and "Them" are labels, not names."#))
    }

    /// "Them" is given its words in the notes' language, so the notes read
    /// as the language does and a name given later can find them.
    func testThePromptSaysWhatToCallThem() {
        let alone = MeetingPeople(others: [])
        XCTAssertEqual(CallNotesPrompts.them(alone, language: "Spanish"), #"In the notes, Them is "la otra persona"."#)
        XCTAssertEqual(CallNotesPrompts.them(alone, language: "English"), #"In the notes, Them is "the other person"."#)
        XCTAssertEqual(CallNotesPrompts.them(alone, language: "Catalan"), #"In the notes, Them is "l'altra persona"."#)
        XCTAssertEqual(CallNotesPrompts.them(alone, language: nil),
                       #"In the notes, Them is "the other person", in the notes' language."#)
        XCTAssertEqual(CallNotesPrompts.them(alone, language: "Japanese"),
                       #"In the notes, Them is "the other person", in the notes' language."#)
        // Several on the invite, heard as one voice.
        XCTAssertEqual(CallNotesPrompts.them(MeetingPeople(others: ["Ana García", "Luis Pérez"]), language: "Spanish"),
                       #"In the notes, Them is "los demás"."#)

        // No "Them" in the transcript: the calendar's one name, voices told
        // apart, the room.
        XCTAssertNil(CallNotesPrompts.them(MeetingPeople(others: ["Ana García"]), language: "Spanish"))
        XCTAssertNil(CallNotesPrompts.them(MeetingPeople(others: [], voices: 2), language: "Spanish"))
        XCTAssertNil(CallNotesPrompts.them(MeetingPeople(others: [], inPerson: true), language: "Spanish"))
        XCTAssertNil(CallNotesPrompts.them(MeetingPeople(others: [], voices: 3, inPerson: true), language: "Spanish"))

        let prompt = CallNotesPrompts.facts(for: chunk(1, from: 0, to: 5), part: 1, of: 1, language: "Spanish",
                                            people: alone, jots: [])
        XCTAssertTrue(prompt.hasPrefix("""
            Take notes from this call. Write them in Spanish.
            People on the call: You, and Them (everyone else on the call).
            In the notes, Them is "la otra persona".

            TRANSCRIPT START
            """), prompt)
        let named = CallNotesPrompts.facts(for: chunk(1, from: 0, to: 5), part: 1, of: 1, language: "Spanish",
                                           people: MeetingPeople(others: ["Ana García"]), jots: [])
        XCTAssertFalse(named.contains("In the notes, Them"))
    }

    func testTheFinalPromptListsTheFacts() {
        var ledger = MeetingLedger(record: Fixture.record())
        ledger.add(MeetingDraft(decisions: [.init(text: "Launch on the twentieth", sources: ["S3"])]),
                   shown: Set(1...6))
        XCTAssertEqual(CallNotesPrompts.wrapUp(ledger.factList(), language: "English"), """
            Write the summary, the title and the key points for this call. Write them in English.

            NOTES START
            F1 [decision] Launch on the twentieth
            NOTES END
            """)
    }

    func testTheFinalPromptSaysWhoWasInvited() {
        var ledger = MeetingLedger(record: Fixture.record(attendees: ["Ana García", "Luis Pérez"]))
        ledger.add(MeetingDraft(decisions: [.init(text: "Launch on the twentieth", sources: ["S3"])]),
                   shown: Set(1...6))
        XCTAssertEqual(CallNotesPrompts.wrapUp(ledger.factList(), language: nil, invited: ledger.people.others), """
            Write the summary, the title and the key points for this call.
            Invited: Ana García, Luis Pérez.

            NOTES START
            F1 [decision] Launch on the twentieth
            NOTES END
            """)
    }

    func testTypedNotesGoWithThePartsTheyWereWrittenIn() {
        let chunks = [chunk(1, from: 0, to: 100), chunk(2, from: 130, to: 300), chunk(3, from: 900, to: 1_000)]
        let jots = [MeetingJot(at: 50, text: "in the first"),
                    MeetingJot(at: 120, text: "between the first two"),
                    MeetingJot(at: 600, text: "in a long silence"),
                    MeetingJot(at: 2_000, text: "after the end")]
        let shared = CallNotesPrompts.jots(jots, for: chunks).map { $0.map(\.text) }
        XCTAssertEqual(shared, [["in the first", "between the first two"],
                                ["between the first two", "in a long silence"],
                                ["after the end"]])
        XCTAssertEqual(CallNotesPrompts.jots(jots, for: []).count, 0)
    }
}
