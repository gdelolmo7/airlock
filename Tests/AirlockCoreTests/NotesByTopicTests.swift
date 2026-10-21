import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// A small, made-up call by topic: a price heard as "Napa" once, the
/// launch date, three things to do and a question nobody answered.
private enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_791_468_600)
    static let utc = TimeZone(identifier: "UTC")!

    static func record() -> MeetingRecord {
        MeetingRecord(
            bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start, endedAt: start.addingTimeInterval(120),
            segments: [
                MeetingSegment(speaker: .me, start: 5, end: 10,
                               text: "Let's start with the price of Mapa."),                    // S1
                MeetingSegment(speaker: .them, start: 12, end: 20,
                               text: "Napa costs forty euros a month to begin with."),          // S2
                MeetingSegment(speaker: .me, start: 22, end: 30,
                               text: "Fine, we keep forty euros then."),                        // S3
                MeetingSegment(speaker: .them, start: 40, end: 50,
                               text: "Next, the launch. We launch on the twentieth."),          // S4
                MeetingSegment(speaker: .me, start: 52, end: 58,
                               text: "I'll send the budget and you check the venue, Marta."),   // S5
                MeetingSegment(speaker: .them, start: 60, end: 66,
                               text: "Sure. And we all read the contract before Monday."),      // S6
                MeetingSegment(speaker: .me, start: 70, end: 76,
                               text: "Who pays for the hall is still open."),                   // S7
            ],
            event: MeetingEvent(title: "Launch", start: start, attendees: ["Marta Vidal"]))
    }

    /// The model's answer, with something wrong in each part.
    static let answer = #"""
        {"wordsToCheck": [{"heard": ["Napa", "Mapa", "Zapa"], "best": "Mapa", "sources": ["S2"]},
                          {"heard": ["Ghost"], "best": "Host", "sources": ["S2"]},
                          {"heard": ["Napa"], "best": "Napa Valley", "sources": ["S99"]}],
         "todos": [{"task": "Check the venue", "owners": ["Marta Vidal"], "due": "", "sources": ["S5"]},
                   {"task": "Read the contract", "owners": ["todos"], "due": "before Monday", "sources": ["S6"]},
                   {"task": "Send the budget", "owners": "Marta Vidal, You", "due": "", "sources": ["[S5 0:52 You]"]},
                   {"task": "Call the bank", "owners": ["Pedro"], "sources": ["S5"]}],
         "topics": [{"title": "Launch date", "gist": "The launch is on the twentieth.",
                     "points": [{"text": "Date: the twentieth", "decision": true, "sources": ["S4"]},
                                {"text": "Hire a band", "sources": ["S42"]}]},
                    {"title": "Price", "gist": "Forty euros a month.",
                     "points": [{"text": "Price: 40 € a month to begin with", "sources": ["S2"]},
                                {"text": "Kept at 40 €", "decision": true, "sources": ["S3"]},
                                {"text": "Price: 40 € a month to begin with", "sources": ["S2"]}]},
                    {"title": "Office move", "points": [{"text": "Move the office", "sources": ["S99"]}]}],
         "questions": [{"text": "Who pays for the hall?", "context": "Nobody has offered yet", "sources": ["S7"]}],
         "summary": "A call on the price and the launch. The price stays at 40 €.",
         "title": "Price and launch"}
        """#
}

// MARK: - The prompt

final class NotesByTopicPromptTests: XCTestCase {
    func testTheRulesFitTheServerAndAskForTheShapeTheAppReads() throws {
        let rules = CallNotesPrompts.cloudTopicsInstructions
        XCTAssertLessThanOrEqual(CloudNotes.size(rules), CloudNotes.instructionsLimit)
        XCTAssertTrue(rules.hasPrefix("You take notes from the transcript of a meeting"))
        XCTAssertTrue(rules.contains(#""You" and "Them" are labels, not names."#))
        XCTAssertTrue(rules.contains("At most \(CloudNotes.topicLimit) topics, \(CloudNotes.pointLimit) points a "
                                     + "topic, \(CloudNotes.topicTodoLimit) to-dos and \(CloudNotes.questionLimit) "
                                     + "open questions."))
        XCTAssertTrue(rules.contains("At most \(CloudNotes.wordLimit);"))
        // Written in the order the server's schema asks for them: the
        // to-dos before the topics, the summary after them.
        let keys = ["\"wordsToCheck\"", "\"todos\"", "\"topics\"", "\"questions\"", "\"summary\"", "\"title\""]
        let shape = String(rules[rules.range(of: "Answer with JSON only")!.lowerBound...])
        // Each after the one before: a topic has a "title" of its own.
        var from = shape.startIndex
        for key in keys {
            let found = try XCTUnwrap(shape[from...].range(of: key), "\(key) after the keys before it")
            from = found.upperBound
        }
    }

    /// One topic for every five to ten minutes, worked out here so the
    /// model does not decide a long meeting had three.
    func testHowManyTopicsFollowsHowLongItWas() {
        func line(_ minutes: Double, _ whole: String = "call") -> String {
            let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: Fixture.start, segments: [
                MeetingSegment(speaker: .me, start: 0, end: minutes * 60, text: "Hello"),
            ])
            return CallNotesPrompts.length(of: record, whole)
        }
        XCTAssertEqual(line(0.2), "The call lasted 1 minute: about 1 topic.")
        XCTAssertEqual(line(7), "The call lasted 7 minutes: about 1 topic.")
        XCTAssertEqual(line(12), "The call lasted 12 minutes: about 1 to 2 topics.")
        XCTAssertEqual(line(30, "meeting"), "The meeting lasted 30 minutes: about 3 to 6 topics.")
        XCTAssertEqual(line(63, "meeting"), "The meeting lasted 63 minutes: about 6 to 10 topics.")
        XCTAssertEqual(line(200), "The call lasted 200 minutes: about 10 topics.")
    }
}

// MARK: - Reading the answer

final class NotesByTopicParseTests: XCTestCase {
    func testAnAnswerByTopicIsReadIntoADraft() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(Fixture.answer))
        XCTAssertTrue(draft.byTopic)
        XCTAssertEqual(draft.title, "Price and launch")
        XCTAssertEqual(draft.words.first, .init(heard: ["Napa", "Mapa", "Zapa"], best: "Mapa", sources: ["S2"]))
        XCTAssertEqual(draft.lines.todos.map(\.owners), [["Marta Vidal"], ["todos"], ["Marta Vidal", "You"], ["Pedro"]],
                       "a list, or one string with the names in it")
        XCTAssertEqual(draft.topics.map(\.title), ["Launch date", "Price", "Office move"])
        XCTAssertEqual(draft.topics[0].points, [.init(text: "Date: the twentieth", decision: true, sources: ["S4"]),
                                                .init(text: "Hire a band", sources: ["S42"])])
        XCTAssertEqual(draft.lines.questions, [.init(text: "Who pays for the hall?", sources: ["S7"],
                                                     context: "Nobody has offered yet")])
        XCTAssertEqual(draft.lines.decisions, [])
    }

    func testPointsAsBareTextAndOtherSpellingsAreTolerated() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(#"""
            {"topics": [{"title": "Price", "points": ["Forty euros"]}],
             "words_to_check": [{"heard": "Napa", "best": "Mapa", "sources": "S2"}]}
            """#))
        XCTAssertTrue(draft.byTopic)
        XCTAssertEqual(draft.topics, [.init(title: "Price", points: [.init(text: "Forty euros", sources: [])])])
        XCTAssertEqual(draft.words, [.init(heard: ["Napa"], best: "Mapa", sources: ["S2"])])
    }

    /// A server from before topics answers in the old shape, and that is
    /// still read the old way.
    func testAnAnswerInTheOldShapeIsNotByTopic() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(#"""
            {"summary": "Short.", "decisions": [{"text": "Launch on the twentieth", "sources": ["S4"]}],
             "todos": [{"task": "Send the budget", "owner": "You", "sources": ["S5"]}]}
            """#))
        XCTAssertFalse(draft.byTopic)
        XCTAssertEqual(draft.lines.todos, [.init(task: "Send the budget", owner: "You", sources: ["S5"])])
        let notes = CloudNotes.notes(from: draft, record: Fixture.record()).notes
        XCTAssertEqual(notes.decisions.map(\.text), ["Launch on the twentieth"])
        XCTAssertEqual(notes.todos.map(\.owner), ["You"])
        XCTAssertEqual(notes.topics, [])
        XCTAssertEqual(notes.words, [])
    }
}

// MARK: - Checking it

final class NotesByTopicCheckTests: XCTestCase {
    private func notes() throws -> (notes: MeetingNotes, tally: MeetingLedger.Tally) {
        CloudNotes.notes(from: try XCTUnwrap(CloudNotes.parse(Fixture.answer)), record: Fixture.record())
    }

    /// Each point is checked as any line is: one citing a line that isn't
    /// there goes, the same point twice is kept once, and a topic left
    /// with nothing goes too. Topics come in the order they came up.
    func testEveryPointCitesALineAndTopicsGoInTheOrderTheyCameUp() throws {
        let (notes, tally) = try notes()
        XCTAssertEqual(notes.topics, [
            .init(title: "Price", gist: "Forty euros a month.", points: [
                .init(text: "Price: 40 € a month to begin with", sources: [2], at: 12),
                .init(text: "Kept at 40 €", decided: true, sources: [3], at: 22),
            ]),
            .init(title: "Launch date", gist: "The launch is on the twentieth.", points: [
                .init(text: "Date: the twentieth", decided: true, sources: [4], at: 40),
            ]),
        ])
        XCTAssertEqual(notes.topics.map(\.at), [12, 40], "a topic's time is its first point's")
        XCTAssertEqual(notes.decisions, [], "a decision is a point marked as one")
        XCTAssertEqual(notes.keyPoints, [], "the topics say what was talked about")
        XCTAssertEqual(tally, .init(kept: 8, dropped: 3))
        XCTAssertEqual(notes.title, "Price and launch")
    }

    /// Owners are checked one by one, as a lone owner is; "Everyone" in
    /// any language names nobody to check. The list goes person by person:
    /// you, then each person, then everyone, then nobody's.
    func testToDosHaveTheirOwnersCheckedAndGoPersonByPerson() throws {
        let todos = try notes().notes.todos
        XCTAssertEqual(todos.map(\.text), ["Send the budget", "Check the venue", "Read the contract before Monday",
                                           "Call the bank"])
        XCTAssertEqual(todos.map(\.owner), ["You, Marta Vidal", "Marta Vidal", MeetingPeople.everyone, nil],
                       "you first; nobody called Pedro was on the call")
    }

    func testAWordToCheckKeepsOnlyTheFormsTheTranscriptHas() throws {
        XCTAssertEqual(try notes().notes.words, [.init(best: "Mapa", heard: ["Napa"], sources: [2], at: 12)],
                       "“Mapa” is the guess itself, “Zapa” was never said, “Ghost” neither, and S99 isn't there")
    }

    func testAnOpenQuestionKeepsItsContext() throws {
        let questions = try notes().notes.questions
        XCTAssertEqual(questions.map(\.text), ["Who pays for the hall?"])
        XCTAssertEqual(questions.map(\.context), ["Nobody has offered yet"])
    }

    func testNoMoreIsKeptThanTheModelWasToldToWrite() {
        let points = (1...9).map { CloudNotes.Draft.Point(text: "Point number \($0)", sources: ["S\(1 + $0 % 7)"]) }
        let topics = (1...12).map { CloudNotes.Draft.Topic(title: "Topic \($0)", points: points) }
        let draft = CloudNotes.Draft(byTopic: true, topics: topics)
        let (notes, tally) = CloudNotes.notes(from: draft, record: Fixture.record())
        XCTAssertEqual(notes.topics.count, CloudNotes.topicLimit)
        XCTAssertEqual(Set(notes.topics.map(\.points.count)), [CloudNotes.pointLimit])
        XCTAssertEqual(tally, .init(kept: CloudNotes.topicLimit * CloudNotes.pointLimit,
                                    dropped: 12 * 9 - CloudNotes.topicLimit * CloudNotes.pointLimit))
    }

    func testOnlyWordsIsNoNotes() {
        let draft = CloudNotes.Draft(byTopic: true, words: [.init(heard: ["Napa"], best: "Mapa", sources: ["S2"])])
        let notes = CloudNotes.notes(from: draft, record: Fixture.record()).notes
        XCTAssertEqual(notes.words.count, 1)
        XCTAssertTrue(notes.isEmpty)
    }
}

// MARK: - The page

final class NotesByTopicPageTests: XCTestCase {
    private func page() throws -> (page: String, record: MeetingRecord) {
        let record = Fixture.record()
        let notes = CloudNotes.notes(from: try XCTUnwrap(CloudNotes.parse(Fixture.answer)), record: record).notes
        return (MeetingFiles.notesPage(for: record, notes: notes, timeZone: Fixture.utc), record)
    }

    func testThePageIsWrittenWordsToDosTopicsThenQuestions() throws {
        let page = try page().page
        XCTAssertTrue(MeetingFiles.hasNotes(page))
        let start = try XCTUnwrap(page.range(of: "## Check these words"))
        let end = try XCTUnwrap(page.range(of: "\n---"))
        XCTAssertEqual(String(page[start.lowerBound..<end.lowerBound]), """
            ## Check these words

            - **Mapa** — heard as “Napa” · 0:12

            ## To-dos

            - [ ] Send the budget — You, Marta Vidal · 0:52
            - [ ] Check the venue — Marta Vidal · 0:52
            - [ ] Read the contract before Monday — Everyone · 1:00
            - [ ] Call the bank · 0:52

            ## Topics

            ### 1. Price · 0:12

            Forty euros a month.

            - **Price:** 40 € a month to begin with · 0:12
            - ✓ Kept at 40 € · 0:22

            ### 2. Launch date · 0:40

            The launch is on the twentieth.

            - ✓ **Date:** the twentieth · 0:40

            ## Open questions

            - Who pays for the hall? — _Nobody has offered yet_ · 1:10

            """)
    }

    /// What the window draws, read back from the page: the topics as one
    /// card, each topic, point, word and question in its parts.
    func testThePageReadsBackAsCardsAndParts() throws {
        let (page, record) = try page()
        let placed = MeetingPage.placed(MeetingPage.body(of: page, header: MeetingFiles.header(of: record,
                                                                                               timeZone: Fixture.utc)))
        let cards = MeetingPage.cards(MeetingPage.sections(placed).sections)
        guard cards.count == 5, case .topics(let head, let topics) = cards[3] else {
            return XCTFail("summary, words, to-dos, topics, questions: \(cards)")
        }
        let heads = cards.map { card -> String? in
            switch card {
            case .section(let section): section.heading
            case .topics(let head, _): head.heading
            }
        }
        XCTAssertEqual(heads, ["Summary", "Check these words", "To-dos", "Topics", "Open questions"])
        XCTAssertEqual(head.level, 2)
        XCTAssertEqual(topics.map(\.level), [3, 3])
        XCTAssertEqual(try topics.map { try XCTUnwrap(MeetingPage.topic($0.heading ?? "")).title }, ["Price", "Launch date"])
        XCTAssertEqual(MeetingPage.topic(topics[0].heading ?? "")?.at, 12)

        let points = topics[0].lines.compactMap { line -> String? in
            if case .item(let text, _, _, _) = line.block { return text }
            return nil
        }
        XCTAssertEqual(points.map { MeetingPage.point($0).decided }, [false, true])
        XCTAssertEqual(points.map { MeetingPage.point($0).lead }, ["Price", nil])
        XCTAssertEqual(points.map { MeetingPage.point($0).rest }, ["40 € a month to begin with", "Kept at 40 €"])

        guard case .section(let words) = cards[1], case .item(let word, _, _, let at)? = words.lines.first?.block,
              case .section(let questions) = cards[4], case .item(let question, _, _, _)? = questions.lines.first?.block,
              case .section(let todos) = cards[2], case .item(_, _, let owner, _)? = todos.lines.first?.block
        else { return XCTFail("a line under each heading") }
        XCTAssertEqual(MeetingPage.word(word)?.best, "Mapa")
        XCTAssertEqual(MeetingPage.word(word)?.heard, ["Napa"])
        XCTAssertEqual(at, 12)
        XCTAssertEqual(MeetingPage.question(question).text, "Who pays for the hall?")
        XCTAssertEqual(MeetingPage.question(question).context, "Nobody has offered yet")
        XCTAssertEqual(owner, "You, Marta Vidal")
        XCTAssertEqual(MeetingOwners.split(owner), ["You", "Marta Vidal"])
    }

    func testAPointLeadsInBoldOnlyWithAFewWordsAndAColon() {
        XCTAssertEqual(MeetingPage.bolded("Precio: 40 € al mes"), "**Precio:** 40 € al mes")
        XCTAssertEqual(MeetingPage.bolded("Next step for the team: call"), "**Next step for the team:** call")
        XCTAssertEqual(MeetingPage.bolded("One two three four five six: too long"), "One two three four five six: too long")
        XCTAssertEqual(MeetingPage.bolded("**Price:** already"), "**Price:** already")
        XCTAssertEqual(MeetingPage.bolded("No colon here"), "No colon here")
        XCTAssertEqual(MeetingPage.bolded("See https://example.com"), "See https://example.com")
        XCTAssertEqual(MeetingPage.bolded("Ends with a colon:"), "Ends with a colon:")
    }

    func testOnlyANumberedHeadingIsATopic() {
        XCTAssertEqual(MeetingPage.topic("1. Price and plans · 4:05")?.number, 1)
        XCTAssertEqual(MeetingPage.topic("1. Price and plans · 4:05")?.title, "Price and plans")
        XCTAssertEqual(MeetingPage.topic("1. Price and plans · 4:05")?.at, 245)
        XCTAssertEqual(MeetingPage.topic("12. Plans")?.title, "Plans")
        XCTAssertNil(MeetingPage.topic("12. Plans")?.at)
        XCTAssertEqual(MeetingPage.topic("2. Plans · later")?.title, "Plans · later", "only a clock is a time")
        for heading in ["Price", "0. Price", "1.Price", "1. ", "One. Price"] {
            XCTAssertNil(MeetingPage.topic(heading), heading)
        }
    }

    func testAWordAndAQuestionReadBackOnlyInTheirOwnShape() {
        XCTAssertEqual(MeetingPage.word("**Mapa** — heard as “napa”, “mapá”")?.heard, ["napa", "mapá"])
        XCTAssertNil(MeetingPage.word("**Mapa** — heard as nothing"))
        XCTAssertNil(MeetingPage.word("Mapa — heard as “napa”"))
        XCTAssertEqual(MeetingPage.question("Why? — _Because_").context, "Because")
        XCTAssertNil(MeetingPage.question("Why – not now?").context)
        XCTAssertNil(MeetingPage.question("Why? — _ _").context)
        XCTAssertEqual(MeetingPage.question("Why? — _ _").text, "Why? — _ _")
    }

    /// A "### " heading outside the topics is still a card of its own, and
    /// the topics end at the next heading that is not a topic's.
    func testTopicsAreGatheredOnlyUnderTheTopicsHeading() {
        func section(_ heading: String, _ level: Int) -> MeetingPage.Section {
            MeetingPage.Section(heading: heading, lines: [], level: level)
        }
        let sections = [section("Summary", 2), section("1. Not a topic here", 3), section("Topics", 2),
                        section("1. Price", 3), section("Aside", 3), section("2. Plans", 3), section("Open questions", 2)]
        XCTAssertEqual(MeetingPage.cards(sections), [
            .section(sections[0]), .section(sections[1]),
            .topics(heading: sections[2], topics: [sections[3]]),
            .section(sections[4]), .section(sections[5]), .section(sections[6]),
        ])
        XCTAssertEqual(MeetingPage.Section(heading: nil, lines: []).level, 0)
        XCTAssertEqual(MeetingPage.Section(heading: "To-dos", lines: []).level, 2)
    }

    func testTopicsAreTidiedLikeEveryOtherLine() {
        let notes = MeetingNotes(topics: [
            .init(title: "  Price ", points: [.init(text: "Forty", at: 30), .init(text: "forty", at: 10),
                                              .init(text: "Kept", at: 20)]),
            .init(title: "Empty", points: [.init(text: "  ")]),
            .init(title: " ", points: [.init(text: "Orphan")]),
        ], words: [.init(best: "Mapa", heard: [" "]), .init(best: "Mapa", heard: ["Napa"])])
        XCTAssertEqual(notes.topics.map(\.title), ["Price"])
        XCTAssertEqual(notes.topics[0].points.map(\.text), ["Forty", "Kept"], "the same point twice is kept once")
        XCTAssertEqual(notes.topics[0].at, 20, "the earliest point kept")
        XCTAssertEqual(notes.words.map(\.heard), [["Napa"]])
        XCTAssertFalse(notes.isEmpty)
    }
}

// MARK: - Who does what

final class MeetingOwnersTests: XCTestCase {
    func testOwnersAreReadFromTheirLine() {
        XCTAssertEqual(MeetingOwners.split("You, Ana García"), ["You", "Ana García"])
        XCTAssertEqual(MeetingOwners.split(" , "), [])
        XCTAssertEqual(MeetingOwners.split(nil), [])
        XCTAssertEqual(MeetingOwners.lead("Ana, You"), "You")
        XCTAssertEqual(MeetingOwners.lead("Ana, Marc"), "Ana")
        XCTAssertNil(MeetingOwners.lead(""))
        XCTAssertEqual(MeetingOwners.others("Ana, You, Marc"), ["Ana", "Marc"])
        XCTAssertEqual(MeetingOwners.others("Ana"), [])
    }

    func testToDosAreGroupedYouThenEachPersonThenEveryoneThenNobody() {
        let owners: [String?] = [nil, "Marc", "Everyone", "Ana, You", "Marc, Ana", "Ana", "You"]
        let grouped = MeetingOwners.grouped(Array(owners.indices)) { owners[$0] }
        XCTAssertEqual(grouped.map { $0.owner }, ["You", "Marc", "Ana", "Everyone", nil],
                       "each person in the order they first have something to do")
        XCTAssertEqual(grouped.map { $0.items }, [[3, 6], [1, 4], [5], [2], [0]])
        XCTAssertEqual(MeetingOwners.ordered(Array(owners.indices)) { owners[$0] }, [3, 6, 1, 4, 5, 2, 0])
    }
}

// MARK: - Naming

final class NotesByTopicNamingTests: XCTestCase {
    /// A voice named as you, in a list of owners, is "You" as any owner
    /// is; in an open question's context it is a word in a sentence.
    func testYouInAListOfOwnersKeepsItsCapital() {
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person",
                                   startedAt: Fixture.start, endedAt: Fixture.start.addingTimeInterval(600))
        for person in [1, 2] {
            record.add(MeetingSegment(speaker: .them, start: TimeInterval(person * 10), end: TimeInterval(person * 10 + 5),
                                      text: "Line from person \(person).", person: person))
        }
        record.name(2, as: nil, isYou: true)
        let page = """
            - [ ] Send it — Person 1, Person 2 · 0:40
            - [ ] Call them — Person 2, Person 1 · 0:50
            - Who pays? — _Ask Person 1, Person 2_ · 1:00
            """
        XCTAssertEqual(MeetingNaming.apply(record, to: page), """
            - [ ] Send it — Person 1, You · 0:40
            - [ ] Call them — You, Person 1 · 0:50
            - Who pays? — _Ask Person 1, you_ · 1:00
            """)
    }
}

// MARK: - Check these words

final class MeetingWordCheckTests: XCTestCase {
    func testOnlyWholeWordsAreReplacedWhateverTheirCaseOrAccents() {
        XCTAssertEqual(MeetingWordCheck.replace(["napa"], with: "Mapa", in: "Napa, napá and NAPA; napalm."),
                       "Mapa, Mapa and Mapa; napalm.")
        XCTAssertEqual(MeetingWordCheck.replace(["mapa", "mapa empresarial"], with: "Mapa Empresarial",
                                                in: "El mapa empresarial y el mapa."),
                       "El Mapa Empresarial y el Mapa Empresarial.", "the longest first")
        XCTAssertEqual(MeetingWordCheck.replace(["Mapa", " "], with: "Mapa", in: "mapa"), "mapa",
                       "the guess itself is never looked for")
        XCTAssertEqual(MeetingWordCheck.replace(["tres euros"], with: "3.000 €", in: "Cuesta tres euros."),
                       "Cuesta 3.000 €.")
        XCTAssertEqual(MeetingWordCheck.replace(["Mapa"], with: "Mapa Empresarial", in: "Mapa Empresarial y mapa."),
                       "Mapa Empresarial y Mapa Empresarial.", "where the guess is written already it stays")
        XCTAssertEqual(MeetingWordCheck.replace(["mapa"], with: "Mapa", in: "mapa y MAPA"), "Mapa y Mapa")
        XCTAssertEqual(MeetingWordCheck.replace(["napa"], with: "Mapa", in: "napanapa napa"), "napanapa Mapa")
    }

    private let page = """
        # Launch

        ## Summary

        Napa costs forty euros.

        ## Your notes

        - napa? · 0:05

        ## Check these words

        - **Mapa** — heard as “Napa” · 0:12
        - **Marta** — heard as “Marga” · 0:52

        ## Topics

        ### 1. Napa price · 0:12

        - **Price:** Napa costs 40 € · 0:12

        ---

        Napa footer.
        """

    func testUseTakesTheLineOffAndPutsTheWordInEverywhereButYourNotes() {
        let answered = MeetingWordCheck.answer(page, best: "Mapa", heard: ["Napa"], use: true)
        XCTAssertFalse(answered.contains("**Mapa** — heard as"))
        XCTAssertTrue(answered.contains("## Check these words\n\n- **Marta** — heard as “Marga” · 0:52"))
        XCTAssertTrue(answered.contains("Mapa costs forty euros."))
        XCTAssertTrue(answered.contains("- napa? · 0:05"), "the person's own notes stay as they typed them")
        XCTAssertTrue(answered.contains("### 1. Mapa price · 0:12"))
        XCTAssertTrue(answered.contains("- **Price:** Mapa costs 40 € · 0:12"))
        XCTAssertTrue(answered.contains("Mapa footer."))
    }

    func testLeaveItOnlyTakesTheLineOffAndTheHeadingWithTheLast() {
        let once = MeetingWordCheck.answer(page, best: "mapa", heard: ["Napa"], use: false)
        XCTAssertEqual(once, page.replacingOccurrences(of: "- **Mapa** — heard as “Napa” · 0:12\n", with: ""))
        let twice = MeetingWordCheck.answer(once, best: "Marta", heard: ["Marga"], use: false)
        XCTAssertFalse(twice.contains(MeetingFiles.wordsHeading))
        XCTAssertTrue(twice.contains("- napa? · 0:05\n\n## Topics"))
        XCTAssertEqual(MeetingWordCheck.answer(twice, best: "Marta", heard: ["Marga"], use: false), twice)
    }

    func testUseChangesWhatWasSaidButNotWhatWasTyped() {
        var record = Fixture.record()
        record.jot("Napa?", at: 12)
        XCTAssertEqual(MeetingWordCheck.use("Mapa", for: ["Napa"], in: &record), 1)
        XCTAssertEqual(record.segments[1].text, "Mapa costs forty euros a month to begin with.")
        XCTAssertEqual(record.jots.map(\.text), ["Napa?"])
        XCTAssertEqual(MeetingWordCheck.use("Mapa", for: ["Napa"], in: &record), 0)
    }

    func testOnlyANameGoesIntoTheWordsInSettings() {
        XCTAssertTrue(MeetingWordCheck.belongsInKnownWords("Mapa"))
        XCTAssertTrue(MeetingWordCheck.belongsInKnownWords("Mapa Empresarial"))
        XCTAssertFalse(MeetingWordCheck.belongsInKnownWords("3.000 €"))
        XCTAssertFalse(MeetingWordCheck.belongsInKnownWords("2027"))
        XCTAssertFalse(MeetingWordCheck.belongsInKnownWords(" "))
    }

    func testTheStoreAnswersInBothPagesAndTheTranscript() throws {
        let scratch = TestScratch("words")
        let store = MeetingStore(root: scratch.root)
        let record = Fixture.record()
        let folder = try store.makeFolder(for: record, timeZone: Fixture.utc)
        try store.saveTranscript(record, in: folder, timeZone: Fixture.utc)
        let notes = CloudNotes.notes(from: try XCTUnwrap(CloudNotes.parse(Fixture.answer)), record: record).notes
        try store.saveNotes(MeetingFiles.notesPage(for: record, notes: notes, timeZone: Fixture.utc), in: folder)
        let read = { (name: String) in try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }

        try store.checkWord("Mapa", heard: ["Napa"], use: false, in: folder, timeZone: Fixture.utc)
        XCTAssertEqual(store.loadRecord(in: folder)?.segments[1].text, record.segments[1].text, "Leave it changes nothing")
        XCTAssertFalse(try read(MeetingFiles.notesName).contains(MeetingFiles.wordsHeading))
        XCTAssertFalse(try read(MeetingStore.notesAsWrittenName).contains(MeetingFiles.wordsHeading))

        let saved = try store.checkWord("Marta", heard: ["Napa"], use: true, in: folder, timeZone: Fixture.utc)
        XCTAssertEqual(saved?.segments[1].text, "Marta costs forty euros a month to begin with.")
        XCTAssertEqual(store.loadRecord(in: folder)?.segments[1].text, saved?.segments[1].text)
        XCTAssertTrue(try read(MeetingFiles.transcriptName).contains("Marta costs forty euros"))
        XCTAssertFalse(try read(MeetingFiles.transcriptName).contains("Napa"))
    }
}
