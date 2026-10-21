import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// A small, made-up call: the budget, a launch date, a venue nobody pays for
/// yet, a catering quote.
private enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_791_468_600)

    static func record(bundleID: String = "us.zoom.xos", attendees: [String]? = ["Marta Vidal"],
                       endedAfter: TimeInterval? = 90, writer: MeetingNotesWriter? = nil) -> MeetingRecord {
        MeetingRecord(
            bundleID: bundleID, appName: "Zoom", startedAt: start,
            endedAt: endedAfter.map { start.addingTimeInterval($0) },
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
                               text: "No idea yet. The old hall might be free again."), // S5
                MeetingSegment(speaker: .them, start: 70, end: 75,
                               text: "The catering quote came in lower than last year."), // S6
            ],
            event: attendees.map { MeetingEvent(title: "Launch", start: start, attendees: $0) },
            notesWriter: writer)
    }

    static let utc = TimeZone(identifier: "UTC")!

    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}

// MARK: - The prompt

final class CloudNotesPromptTests: XCTestCase {
    func testTheOnlineRulesAreThePartRulesForTheWholeTranscriptThenTheSummary() {
        let expected = CallNotesPrompts.factsInstructions
            .replacingOccurrences(of: "from part of the transcript", with: "from the transcript")
            + "\n"
            + "Then write the summary, for someone who missed the meeting, in two parts: what the meeting was "
            + "for, in one sentence; then what came out of it, in one or two sentences naming two or three of "
            + "the decisions, to-dos or open questions by what they are. A to-do is still to be done, not done. "
            + "Never write only that things were discussed or decisions were made: say which.\n"
            + "Key points are up to five short lines on the topics discussed, saying what the decisions, "
            + "to-dos and open questions do not already say. Each lists the IDs of the lines it comes from.\n"
            + "The title names the meeting by what it was about, in two to six words in the notes' language, "
            + #"as someone would file it: "Kitchen tiles and delivery dates", not "Meeting about the kitchen". "#
            + "No quotes, no full stop, no date, no app name.\n"
            + "At most 8 decisions, 15 to-dos, 8 open questions and 5 key points.\n"
            + #"Answer with JSON only, in this shape: {"summary": "...", "title": "...", "decisions": [{"text": "...", "#
            + #""sources": ["S12"]}], "todos": [{"task": "...", "owner": "...", "due": "...", "sources": "#
            + #"["S12"]}], "questions": [{"text": "...", "sources": ["S12"]}], "keyPoints": [{"text": "...", "#
            + #""sources": ["S12"]}]}"#
        XCTAssertEqual(CallNotesPrompts.cloudInstructions, expected)
        XCTAssertTrue(CallNotesPrompts.cloudInstructions.hasPrefix("You take notes from the transcript of a meeting"))
        XCTAssertFalse(CallNotesPrompts.cloudInstructions.contains("part of the transcript"))
        XCTAssertLessThanOrEqual(CloudNotes.size(CallNotesPrompts.cloudInstructions), CloudNotes.instructionsLimit)
    }

    func testTheOnlinePromptIsTheWholeCallWithTheJotsBeforeIt() {
        var record = Fixture.record()
        record.jot("budget\nby Friday", at: 12)
        XCTAssertEqual(CallNotesPrompts.cloud(for: record, language: "Spanish"), """
            Take notes from this call. Write them in Spanish.
            People on the call: You, and Marta Vidal (the other side).
            The call lasted 1 minute: about 1 topic.

            The person wrote these during the call; they matter, make sure they are covered:
            - 0:12 budget by Friday

            TRANSCRIPT START
            [S1 0:05 Marta Vidal] Can you send me the budget by Friday?
            [S2 0:14 You] Sure, I'll send it on Thursday.
            [S3 0:30 Marta Vidal] Good. Then we launch on the twentieth.
            [S4 0:42 You] Agreed. Who pays for the venue, though?
            [S5 0:52 Marta Vidal] No idea yet. The old hall might be free again.
            [S6 1:10 Marta Vidal] The catering quote came in lower than last year.
            TRANSCRIPT END
            """)
    }

    func testWithNothingTypedAndNoLanguageThePromptSaysNoMore() {
        let prompt = CallNotesPrompts.cloud(for: Fixture.record(), language: nil)
        XCTAssertTrue(prompt.hasPrefix(
            "Take notes from this call.\nPeople on the call: You, and Marta Vidal (the other side).\n"
            + "The call lasted 1 minute: about 1 topic.\n\nTRANSCRIPT START\n"))
        XCTAssertFalse(prompt.contains("The person wrote"))
    }

    func testAMeetingInTheRoomIsCalledAMeeting() {
        let record = Fixture.record(bundleID: OngoingCall.inPersonBundleID, attendees: nil)
        XCTAssertTrue(CallNotesPrompts.cloud(for: record, language: nil).hasPrefix("Take notes from this meeting.\n"))
    }

    /// A call nobody on the calendar names: the transcript says "Them", and
    /// the prompt says what the notes call them instead.
    func testACallWithNoNameSaysWhatToCallThem() {
        let record = Fixture.record(attendees: nil)
        XCTAssertTrue(CallNotesPrompts.cloud(for: record, language: "Spanish").hasPrefix("""
            Take notes from this call. Write them in Spanish.
            People on the call: You, and Them (everyone else on the call).
            In the notes, Them is "la otra persona".
            The call lasted 1 minute: about 1 topic.

            TRANSCRIPT START
            [S1 0:05 Them] Can you send me the budget by Friday?
            [S2 0:14 You] Sure, I'll send it on Thursday.
            """))
        XCTAssertFalse(CallNotesPrompts.cloud(for: Fixture.record(), language: "Spanish").contains("In the notes, Them"))
    }
}

// MARK: - Reading the answer

final class CloudNotesParseTests: XCTestCase {
    private let answer = #"""
        {"summary": "A call to plan the launch.",
         "decisions": [{"text": "Launch on the twentieth", "sources": ["S3"]}],
         "todos": [{"task": "Send the budget", "owner": "You", "due": "Thursday", "sources": ["[S2 0:14 You]"]},
                   {"task": "Find a venue", "owner": null, "due": null, "sources": "S4, S5"}],
         "questions": [{"text": "Who pays for the venue?", "sources": [4]}],
         "keyPoints": [{"text": "Catering is cheaper this year", "sources": ["6"]}]}
        """#

    func testTheAnswerIsReadIntoADraft() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(answer))
        XCTAssertEqual(draft.summary, "A call to plan the launch.")
        XCTAssertEqual(draft.lines.decisions, [.init(text: "Launch on the twentieth", sources: ["S3"])])
        XCTAssertEqual(draft.lines.todos, [
            .init(task: "Send the budget", owner: "You", due: "Thursday", sources: ["[S2 0:14 You]"]),
            .init(task: "Find a venue", owner: "", due: "", sources: ["S4", " S5"]),
        ])
        XCTAssertEqual(draft.lines.questions, [.init(text: "Who pays for the venue?", sources: ["4"])])
        XCTAssertEqual(draft.keyPoints, [.init(text: "Catering is cheaper this year", sources: ["6"])])
    }

    func testAFencedOrIntroducedAnswerIsStillRead() throws {
        let fenced = "```json\n" + answer + "\n```"
        let introduced = "Here are the notes:\n" + answer + "\nLet me know if you need more."
        XCTAssertEqual(CloudNotes.parse(fenced), CloudNotes.parse(answer))
        XCTAssertEqual(CloudNotes.parse(introduced), CloudNotes.parse(answer))
    }

    func testMissingListsAndOtherSpellingsAreTolerated() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(
            #"{"summary": "Short.", "key_points": [{"text": "Hall", "sources": "S5"}], "todos": [{"text": "Book it", "sources": ["S5"]}]}"#))
        XCTAssertEqual(draft.lines.decisions, [])
        XCTAssertEqual(draft.lines.questions, [])
        XCTAssertEqual(draft.lines.todos, [.init(task: "Book it", sources: ["S5"])])
        XCTAssertEqual(draft.keyPoints, [.init(text: "Hall", sources: ["S5"])])
    }

    func testWhatIsNotTheAskedForJSONIsNothing() {
        for text in ["", "No notes today.", "[]", #"{"answer": 42}"#, #"{"summary": "x""#, "{ not json }"] {
            XCTAssertNil(CloudNotes.parse(text), text)
        }
    }
}

// MARK: - Checking it

final class CloudNotesCheckTests: XCTestCase {
    func testLinesThatCiteNothingRealAreDroppedAsTheMacsAre() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(#"""
            {"summary": "A call to plan the launch. The launch is on the twentieth and the budget goes out on Thursday. Who pays for the venue is open. Lunch was mentioned too.",
             "decisions": [{"text": "Launch on the twentieth", "sources": ["S3"]},
                           {"text": "Move the office", "sources": ["S99"]}],
             "todos": [{"task": "Send the budget", "owner": "You", "due": "Thursday", "sources": ["[S2 0:14 You]"]},
                       {"task": "Call the bank", "owner": "Pedro", "due": "", "sources": ["2"]}],
             "questions": [{"text": "Who pays for the venue?", "sources": [4]}],
             "keyPoints": [{"text": "The catering quote came in lower than last year", "sources": ["S6"]},
                           {"text": "Launch on the twentieth", "sources": ["S3"]},
                           {"text": "Hire a band", "sources": ["S42"]}]}
            """#))
        let (notes, tally) = CloudNotes.notes(from: draft, record: Fixture.record())

        XCTAssertEqual(notes.summary, "A call to plan the launch. The launch is on the twentieth and the budget "
                       + "goes out on Thursday. Who pays for the venue is open.")
        XCTAssertEqual(notes.decisions.map(\.text), ["Launch on the twentieth"], "S99 does not exist")
        XCTAssertEqual(notes.todos.map(\.text).count, 2)
        XCTAssertEqual(notes.todos.map(\.owner), ["You", nil], "nobody called Pedro was on the call")
        XCTAssertEqual(notes.questions.map(\.sources), [[4]])
        XCTAssertEqual(notes.keyPoints, [.init(text: "The catering quote came in lower than last year",
                                               sources: [6], at: 70)],
                       "one key point says the decision again, one cites a line that doesn't exist")
        XCTAssertEqual(tally, .init(kept: 5, dropped: 3))
    }

    func testNoMoreIsKeptThanTheModelWasToldToWrite() throws {
        let tasks = ["Hire the caterer", "Book the hall", "Print the posters", "Order the chairs",
                     "Rent the lights", "Pay the deposit", "Hire a photographer", "Send the invitations",
                     "Buy the flowers", "Fix the stage"]
        let draft = CloudNotes.Draft(lines: MeetingDraft(decisions: tasks.map { .init(text: $0, sources: ["S3"]) }))
        let (notes, tally) = CloudNotes.notes(from: draft, record: Fixture.record())
        XCTAssertEqual(notes.decisions.count, CloudNotes.decisionLimit)
        XCTAssertEqual(tally.dropped, 2)
    }

    func testAnAnswerWithNothingThatHoldsUpIsEmpty() {
        let draft = CloudNotes.Draft(lines: MeetingDraft(decisions: [.init(text: "Move the office", sources: ["S99"])]))
        XCTAssertTrue(CloudNotes.notes(from: draft, record: Fixture.record()).notes.isEmpty)
    }
}

// MARK: - The server

final class CloudNotesReplyTests: XCTestCase {
    private func read(_ status: Int, _ body: String) -> CloudNotes.Reply {
        CloudNotes.Reply.read(status: status, body: Data(body.utf8))
    }

    func testTheRequestCarriesTheTokenTheRulesAndThePromptOnly() throws {
        let body = CloudNotes.requestBody(token: "tok", instructions: "rules", prompt: "question")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["token": "tok", "instructions": "rules", "prompt": "question"])
    }

    /// Notes by topic say so; a server from before them ignores the word.
    func testTheShapeIsSentOnlyWhenAskedFor() throws {
        let body = CloudNotes.requestBody(token: "tok", instructions: "rules", prompt: "question",
                                          shape: CloudNotes.topicsShape)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["token": "tok", "instructions": "rules", "prompt": "question", "shape": "topics"])
    }

    func testNotesAreReadFromA200() throws {
        XCTAssertEqual(read(200, #"{"notes": "{\"summary\": \"Hi.\"}", "model": "gemini-x", "usedFraction": 0.25}"#),
                       .notes(text: #"{"summary": "Hi."}"#, model: "gemini-x", usedFraction: 0.25))
        XCTAssertEqual(read(200, #"{"notes": "x", "usedFraction": 1.5}"#),
                       .notes(text: "x", model: nil, usedFraction: 1))
        guard case let .notes(text, _, _) = read(200, #"{"notes": {"summary": "Hi.", "decisions": []}}"#) else {
            return XCTFail("notes sent already read are read too")
        }
        XCTAssertEqual(CloudNotes.parse(text)?.summary, "Hi.")
        XCTAssertEqual(read(200, #"{"model": "gemini-x"}"#), .unavailable)
        XCTAssertEqual(read(200, "<html>"), .unavailable)
    }

    func testEachRefusalIsToldApart() {
        XCTAssertEqual(read(401, ""), .badToken)
        XCTAssertEqual(read(402, #"{"error":"budget","message":"m","resetsAt":"2026-11-01T00:00:00Z"}"#),
                       .allowanceUsed(resetsAt: Fixture.date("2026-11-01T00:00:00Z")))
        XCTAssertEqual(read(402, #"{"error":"budget"}"#), .allowanceUsed(resetsAt: nil))
        XCTAssertEqual(read(403, #"{"error":"not-eligible"}"#), .notEligible)
        XCTAssertEqual(read(413, ""), .tooLarge)
        for status in [500, 502, 503, 429, 404] {
            XCTAssertEqual(read(status, #"{"error":"x"}"#), .unavailable, "\(status)")
        }
    }

    /// Only a request that never left can be made again: one that timed out
    /// or was cut may have reached the server, and cost money.
    func testOnlyARequestThatNeverLeftCountsAsOffline() {
        XCTAssertTrue(CloudNotes.neverLeft(.notConnectedToInternet))
        XCTAssertTrue(CloudNotes.neverLeft(.cannotFindHost))
        XCTAssertFalse(CloudNotes.neverLeft(.timedOut))
        XCTAssertFalse(CloudNotes.neverLeft(.networkConnectionLost))
        XCTAssertFalse(CloudNotes.neverLeft(.badServerResponse))
    }
}

// MARK: - Routing

final class CloudNotesRouteTests: XCTestCase {
    private let now = Fixture.start

    private var subscriber: Entitlement {
        .licensed(License(id: "lic_1", email: "a@b.com", product: "airlock", period: .yearly,
                          issued: now, renewsAt: now.addingTimeInterval(30 * 86_400),
                          checkBy: now.addingTimeInterval(44 * 86_400)))
    }

    private func everythingHolds() -> CloudNotesConditions {
        CloudNotesConditions(hiddenSwitch: true, setting: true, plan: subscriber.snapshot, hasToken: true,
                             hasServer: true, online: true, words: 200, promptSize: 5_000, now: now)
    }

    private func route(_ change: (inout CloudNotesConditions) -> Void) -> CloudNotesRoute {
        var conditions = everythingHolds()
        change(&conditions)
        return CloudNotesRoute.decide(conditions)
    }

    func testOnlineOnlyWhenEverythingHolds() {
        XCTAssertEqual(CloudNotesRoute.decide(everythingHolds()), .online)
    }

    func testEachReasonIsNamed() {
        let later = now.addingTimeInterval(3_600), earlier = now.addingTimeInterval(-3_600)
        XCTAssertEqual(route { $0.hiddenSwitch = false }, .mac(.hiddenSwitchOff))
        XCTAssertEqual(route { $0.setting = false }, .mac(.settingOff))
        XCTAssertEqual(route { $0.plan = Entitlement.trialing(daysRemaining: 9).snapshot }, .mac(.notSubscribed))
        XCTAssertEqual(route { $0.plan = .free }, .mac(.notSubscribed))
        if case let .licensed(license) = subscriber {
            XCTAssertEqual(route { $0.plan = Entitlement.overdue(license).snapshot }, .mac(.notSubscribed),
                           "run out")
            XCTAssertEqual(route { $0.plan = Entitlement.grace(license).snapshot }, .online,
                           "grace is still paid")
        }
        XCTAssertEqual(route { $0.plan = PlanSnapshot(plan: .pro, isPaid: true) }, .online)
        XCTAssertEqual(route { $0.hasToken = false }, .mac(.noToken))
        XCTAssertEqual(route { $0.hasServer = false }, .mac(.noServer))
        XCTAssertEqual(route { $0.words = MeetingNotes.minimumWords - 1 }, .mac(.tooShort))
        XCTAssertEqual(route { $0.promptSize = CloudNotes.promptLimit + 1 }, .mac(.tooLong))
        XCTAssertEqual(route { $0.promptSize = CloudNotes.promptLimit }, .online)
        XCTAssertEqual(route { $0.notEligibleUntil = later }, .mac(.notEligible(until: later)))
        XCTAssertEqual(route { $0.notEligibleUntil = earlier }, .online, "a month later, it asks again")
        XCTAssertEqual(route { $0.allowanceUntil = later }, .mac(.allowanceUsed(until: later)))
        XCTAssertEqual(route { $0.allowanceUntil = earlier }, .online, "after resetsAt, it asks again")
        XCTAssertEqual(route { $0.online = false }, .mac(.offline))
    }

    /// The hidden switch first: off, nothing else is even looked at, and
    /// today's notes are written exactly as they were.
    func testTheFirstReasonThatHoldsIsTheOneGiven() {
        let nothing = CloudNotesConditions(hiddenSwitch: false, setting: false, plan: .free,
                                           hasToken: false, hasServer: false, online: false, words: 0,
                                           promptSize: .max, allowanceUntil: .distantFuture,
                                           notEligibleUntil: .distantFuture, now: now)
        var conditions = nothing
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.hiddenSwitchOff))
        conditions.hiddenSwitch = true
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.settingOff))
        conditions.setting = true
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.notSubscribed))
        conditions.plan = subscriber.snapshot
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.noToken))
        conditions.hasToken = true
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.noServer))
        conditions.hasServer = true
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.tooShort))
        conditions.words = 100
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.tooLong))
        conditions.promptSize = 100
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.notEligible(until: .distantFuture)))
        conditions.notEligibleUntil = nil
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.allowanceUsed(until: .distantFuture)))
        conditions.allowanceUntil = nil
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.offline))
        conditions.online = true
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .online)
    }

    func testOnlyNotesWrittenOfflineWaitForOnline() {
        XCTAssertTrue(CloudNotesRoute.mac(.offline).waitsForOnline)
        for route in [CloudNotesRoute.online, .mac(.hiddenSwitchOff), .mac(.settingOff), .mac(.notSubscribed),
                      .mac(.tooShort), .mac(.tooLong), .mac(.allowanceUsed(until: now)),
                      .mac(.notEligible(until: now))] {
            XCTAssertFalse(route.waitsForOnline, "\(route)")
        }
    }

    // MARK: On unless switched off

    /// Nobody is asked: an untouched switch is on, and only off keeps a
    /// subscriber's notes on the Mac.
    func testAnUntouchedSettingIsOn() {
        XCTAssertEqual(route { $0.setting = nil }, .online)
        XCTAssertEqual(route { $0.setting = true }, .online)
        XCTAssertEqual(route { $0.setting = false }, .mac(.settingOff))
    }

    /// Offline with the switch untouched: written on the Mac, and written
    /// again online once the Mac is back online, as after a yes.
    func testOfflineTheNotesWaitForOnlineWhateverTheSwitchSays() {
        for setting in [nil, true] as [Bool?] {
            let decided = route {
                $0.setting = setting
                $0.online = false
            }
            XCTAssertEqual(decided, .mac(.offline), "\(String(describing: setting))")
            XCTAssertTrue(decided.waitsForOnline)
        }
        XCTAssertEqual(route {
            $0.setting = false
            $0.online = false
        }, .mac(.settingOff), "switched off: nothing waits")
    }

    func testTheReasonsAreLoggedInWords() {
        XCTAssertEqual(CloudNotesRoute.Reason.settingOff.logName, "switched off in Settings")
        XCTAssertEqual(CloudNotesRoute.Reason.offline.logName, "offline")
    }
}

// MARK: - The switch in Settings

final class CloudNotesSettingTests: XCTestCase {
    /// Untouched is on; only a false is off.
    func testTheSwitchIsOnUnlessSwitchedOff() {
        XCTAssertTrue(CloudNotesSetting.isOn(nil))
        XCTAssertTrue(CloudNotesSetting.isOn(true))
        XCTAssertFalse(CloudNotesSetting.isOn(false))
    }

    /// Says where the transcript goes, that nobody keeps it, and what off means.
    func testTheWordsSayWhereItGoesAndThatNobodyKeepsIt() {
        XCTAssertEqual(CloudNotesSetting.title, "Write notes online")
        XCTAssertEqual(CloudNotesSetting.subtitle,
                       "When a meeting ends, its transcript goes through Airlock's server to Google's Gemini to "
                       + "write better notes. Neither Airlock nor Google keeps it, and it isn't used to train AI. "
                       + "Off, or without internet, notes are written on this Mac.")
        XCTAssertEqual(CloudNotesSetting.subtitle(for: .plus), CloudNotesSetting.subtitle)
        XCTAssertEqual(CloudNotesSetting.subtitle(for: nil), CloudNotesSetting.subtitle, "unknown reads as Plus")
    }

    /// Pro's notes go to another company's model, by another company's
    /// computers: the switch names both, and that neither keeps it.
    func testProSaysItsNotesGoToOpenAIRunByMicrosoft() {
        XCTAssertEqual(CloudNotesSetting.subtitle(for: .pro),
                       "When a meeting ends, its transcript goes through Airlock's server to OpenAI's GPT, run by "
                       + "Microsoft Azure, to write better notes. Neither Airlock, OpenAI nor Microsoft keeps it, "
                       + "and it isn't used to train AI. Off, or without internet, notes are written on this Mac.")
    }
}

// MARK: - A refusal, kept for one licence

final class CloudNotesNotEligibleTests: XCTestCase {
    private let until = Fixture.start.addingTimeInterval(30 * 86_400)

    func testItIsBelievedForAMonth() {
        XCTAssertEqual(CloudNotesAllowance.notEligibleFor, 30 * 86_400)
    }

    /// Believed only for the token it came with.
    func testItHoldsOnlyForTheSameLicence() {
        let mark = CloudNotesAllowance.tokenMark("token-a")
        XCTAssertEqual(CloudNotesAllowance.notEligibleUntil(saved: until, savedMark: mark, token: "token-a"), until)
        XCTAssertNil(CloudNotesAllowance.notEligibleUntil(saved: until, savedMark: mark, token: "token-b"),
                     "renewed or bought: asked again at once")
        XCTAssertNil(CloudNotesAllowance.notEligibleUntil(saved: until, savedMark: mark, token: nil))
        XCTAssertNil(CloudNotesAllowance.notEligibleUntil(saved: until, savedMark: nil, token: "token-a"),
                     "kept without a mark, by 1.0.20")
        XCTAssertNil(CloudNotesAllowance.notEligibleUntil(saved: nil, savedMark: mark, token: "token-a"))
    }

    /// Short, the same every time, and not the token.
    func testTheMarkIsShortAndNotTheToken() {
        let token = "eyJsaWNlbmNlIjoibGljXzEifQ.c2lnbmF0dXJl"
        let mark = CloudNotesAllowance.tokenMark(token)
        XCTAssertEqual(mark, CloudNotesAllowance.tokenMark(token))
        XCTAssertEqual(mark.count, 16)
        XCTAssertFalse(token.contains(mark))
        XCTAssertNotEqual(mark, CloudNotesAllowance.tokenMark(token + "x"))
    }
}

// MARK: - The month's allowance

final class CloudNotesAllowanceTests: XCTestCase {
    private let britain = Locale(identifier: "en_GB")
    private let now = Fixture.date("2026-10-14T09:30:00Z")

    func testTheMessageSaysUntilWhenInDayAndMonth() {
        let until = Fixture.date("2026-11-01T00:00:00Z")
        XCTAssertEqual(CloudNotesAllowance.message(until: until, locale: britain, timeZone: Fixture.utc),
                       "This month's online notes are used up, so these were written on your Mac. "
                       + "Online notes are back on 1 November.")
        XCTAssertEqual(CloudNotesAllowance.day(until, locale: Locale(identifier: "en_US"), timeZone: Fixture.utc),
                       "November 1")
    }

    /// A Mac that can't write notes says when this call's will be.
    func testOnAMacThatCantWriteNotesItSaysTheDayThisCallsAreWritten() {
        let until = Fixture.date("2026-11-01T00:00:00Z")
        XCTAssertEqual(CloudNotesAllowance.message(until: until, macWrites: false, locale: britain,
                                                   timeZone: Fixture.utc),
                       "This month's online notes are used up, so this call's notes will be written on 1 November.")
    }

    /// No higher plan exists yet, so nothing offers one.
    func testNoUpgradeIsOfferedForNow() {
        XCTAssertFalse(CloudNotesAllowance.offersUpgrade)
        let until = Fixture.date("2026-11-01T00:00:00Z")
        XCTAssertFalse(CloudNotesAllowance.message(until: until, locale: britain, timeZone: Fixture.utc)
            .contains("Upgrade"))
    }

    /// The wording kept for when there is a plan to move to, so it doesn't
    /// rot while switched off.
    func testWithTheUpgradeOnItIsOfferedInWordsAndAButton() {
        let until = Fixture.date("2026-11-01T00:00:00Z")
        XCTAssertEqual(CloudNotesAllowance.message(until: until, locale: britain, timeZone: Fixture.utc,
                                                   offersUpgrade: true),
                       "This month's online notes are used up, so these were written on your Mac. "
                       + "Online notes are back on 1 November. Upgrade for more.")
        XCTAssertEqual(CloudNotesAllowance.upgradeButton, "Upgrade")
    }

    func testTheServersDateIsKeptAsItIs() {
        let resets = Fixture.date("2026-10-20T00:00:00Z")
        XCTAssertEqual(CloudNotesAllowance.until(resetsAt: resets, now: now, calendar: Fixture.gregorian), resets)
    }

    func testWithoutADateItIsTheFirstOfNextMonth() {
        XCTAssertEqual(CloudNotesAllowance.until(resetsAt: nil, now: now, calendar: Fixture.gregorian),
                       Fixture.date("2026-11-01T00:00:00Z"))
    }

    func testADateAlreadyPastWaitsAnHourNotAMonth() {
        let past = Fixture.date("2026-10-01T00:00:00Z")
        XCTAssertEqual(CloudNotesAllowance.until(resetsAt: past, now: now, calendar: Fixture.gregorian),
                       now.addingTimeInterval(3_600))
    }

    func testTheServersDatesAreRead() {
        let first = Fixture.date("2026-11-01T00:00:00Z")
        XCTAssertEqual(CloudNotesAllowance.date("2026-11-01T00:00:00Z"), first)
        XCTAssertEqual(CloudNotesAllowance.date("2026-11-01T00:00:00.000Z"), first)
        XCTAssertEqual(CloudNotesAllowance.date("2026-11-01"), first)
        XCTAssertNil(CloudNotesAllowance.date(nil))
        XCTAssertNil(CloudNotesAllowance.date("soon"))
    }

    func testItIsSaidOnceAMonth() {
        let calendar = Fixture.gregorian
        XCTAssertTrue(CloudNotesAllowance.noticeDue(lastShown: nil, now: now, calendar: calendar))
        XCTAssertFalse(CloudNotesAllowance.noticeDue(lastShown: Fixture.date("2026-10-02T08:00:00Z"),
                                                     now: now, calendar: calendar))
        XCTAssertTrue(CloudNotesAllowance.noticeDue(lastShown: Fixture.date("2026-09-30T23:00:00Z"),
                                                    now: now, calendar: calendar))
    }
}

// MARK: - Written again once online

final class CloudNotesRedoTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/meetings/x")

    private func call(startedAfter hours: Double, writer: MeetingNotesWriter?, ended: Bool = true)
        -> (folder: URL, record: MeetingRecord) {
        var record = Fixture.record(endedAfter: ended ? 90 : nil, writer: writer)
        record.startedAt = Fixture.start.addingTimeInterval(hours * 3_600)
        return (folder.appendingPathComponent("\(hours)"), record)
    }

    func testNewestWaitingFirstAndOnlyAFew() {
        let waiting = MeetingNotesWriter.mac(at: Fixture.start, waitsForOnline: true)
        var sent = waiting
        sent.onlineTries = 1
        let calls = [
            call(startedAfter: 1, writer: waiting),
            call(startedAfter: 5, writer: waiting),
            call(startedAfter: 2, writer: nil),
            call(startedAfter: 3, writer: .mac(at: Fixture.start)),
            call(startedAfter: 4, writer: .online(model: "m", at: Fixture.start)),
            call(startedAfter: 6, writer: sent),
            call(startedAfter: 7, writer: waiting, ended: false),
            call(startedAfter: 8, writer: waiting),
            call(startedAfter: 0, writer: waiting),
        ]
        XCTAssertEqual(CloudNotesRedo.waiting(calls).map(\.folder.lastPathComponent), ["8.0", "5.0", "1.0"])
        XCTAssertEqual(CloudNotesRedo.perReturn, 3)
    }

    func testOnlyComingOnlineStartsIt() {
        XCTAssertTrue(CloudNotesRedo.shouldStart(wasOnline: nil, isOnline: true))
        XCTAssertTrue(CloudNotesRedo.shouldStart(wasOnline: false, isOnline: true))
        XCTAssertFalse(CloudNotesRedo.shouldStart(wasOnline: true, isOnline: true))
        XCTAssertFalse(CloudNotesRedo.shouldStart(wasOnline: false, isOnline: false))
        XCTAssertFalse(CloudNotesRedo.shouldStart(wasOnline: true, isOnline: false))
    }

    func testWhatToDoWithAWaitingMeeting() {
        XCTAssertEqual(CloudNotesRedo.step(for: .online), .send)
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.tooShort)), .leave)
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.tooLong)), .leave)
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.offline)), .stop)
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.allowanceUsed(until: Fixture.start))), .stop)
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.settingOff)), .stop)
    }

    /// Sent once: a reply of any kind means it may have cost money, so it
    /// is never sent again. Only a request that never left gives its try back.
    func testAMeetingIsNeverSentTwice() {
        var writer = MeetingNotesWriter.mac(at: Fixture.start, waitsForOnline: true)
        writer.onlineTries = 1
        let answered = CloudNotesRedo.afterFailedTry(writer, neverLeft: false)
        XCTAssertFalse(answered.waitsForOnline)
        let neverLeft = CloudNotesRedo.afterFailedTry(writer, neverLeft: true)
        XCTAssertTrue(neverLeft.waitsForOnline)
        XCTAssertEqual(neverLeft.onlineTries, 0)
        XCTAssertEqual(CloudNotesRedo.waiting([call(startedAfter: 1, writer: answered)]).count, 0)
        XCTAssertEqual(CloudNotesRedo.waiting([call(startedAfter: 1, writer: neverLeft)]).count, 1)
    }

    // A Mac that can't write notes (no Apple Intelligence)

    private let ended = Fixture.date("2026-10-14T10:00:00Z")

    /// Every miss that will pass keeps the call waiting, with the day it
    /// is due; one that won't (switched off, not a subscriber, too long)
    /// leaves the page as it was, saying why there are no notes.
    func testAMacThatCantWriteNotesKeepsTheCallWaiting() {
        let until = Fixture.date("2026-11-01T00:00:00Z")
        let failed = CloudNotesRedo.withoutNotes(.failed, now: ended)
        XCTAssertEqual(failed?.noNotesYet, .failed)
        XCTAssertEqual(failed?.notBefore, ended.addingTimeInterval(3_600), "tried again an hour after the call")
        XCTAssertEqual(failed?.waitsForOnline, true)
        XCTAssertEqual(failed?.place, .mac)
        XCTAssertNil(failed?.model)

        let offline = CloudNotesRedo.withoutNotes(.mac(.offline), now: ended)
        XCTAssertEqual(offline?.noNotesYet, .offline)
        XCTAssertNil(offline?.notBefore, "it waits for the network, not a date")

        let used = CloudNotesRedo.withoutNotes(.mac(.allowanceUsed(until: until)), now: ended)
        XCTAssertEqual(used?.noNotesYet, .allowanceUsed)
        XCTAssertEqual(used?.notBefore, until)

        for reason: CloudNotesRoute.Reason in [.settingOff, .hiddenSwitchOff, .tooShort, .tooLong] {
            XCTAssertNil(CloudNotesRedo.withoutNotes(.mac(reason), now: ended), "\(reason)")
        }
    }

    /// Not sent before its day, then sent; the Mac's own notes keep being
    /// sent at once, as before.
    func testACallWithNoNotesIsSentOnlyFromItsDay() throws {
        let writer = try XCTUnwrap(CloudNotesRedo.withoutNotes(.failed, now: ended))
        let calls = [call(startedAfter: 1, writer: writer)]
        XCTAssertFalse(CloudNotesRedo.isDue(writer, now: ended.addingTimeInterval(3_599)))
        XCTAssertTrue(CloudNotesRedo.isDue(writer, now: ended.addingTimeInterval(3_600)))
        XCTAssertEqual(CloudNotesRedo.waiting(calls, now: ended.addingTimeInterval(60)).count, 0)
        XCTAssertEqual(CloudNotesRedo.waiting(calls, now: ended.addingTimeInterval(3_600)).count, 1)
        XCTAssertTrue(CloudNotesRedo.isDue(.mac(at: ended, waitsForOnline: true), now: ended))
    }

    /// After a try that didn't work: an hour, six, a day, then it stops
    /// waiting, where the Mac's notes are sent once and never again.
    func testAFailedTryIsTriedAgainAfterLongerWaitsThenStops() throws {
        var writer = try XCTUnwrap(CloudNotesRedo.withoutNotes(.failed, now: ended))
        var now = ended
        var waits: [TimeInterval] = []
        for _ in 0..<10 {
            guard let due = writer.notBefore, writer.waitsForOnline else { break }
            now = due
            XCTAssertTrue(CloudNotesRedo.isDue(writer, now: now))
            writer.onlineTries += 1          // counted before it is sent
            writer = CloudNotesRedo.afterFailedTry(writer, neverLeft: false, now: now)
            if let next = writer.notBefore { waits.append(next.timeIntervalSince(now)) }
        }
        XCTAssertEqual(waits, [6 * 3_600, 86_400], "after the first wait (an hour): six hours, then a day")
        XCTAssertEqual(writer.onlineTries, 3)
        XCTAssertFalse(writer.waitsForOnline, "three tries after the call's own, then no more")
        XCTAssertNil(writer.noNotesYet)
        XCTAssertNil(writer.notBefore)
        XCTAssertNil(CloudNotesRedo.nextLook([call(startedAfter: 1, writer: writer)], now: now))
        XCTAssertEqual(CloudNotesRedo.maxTries(for: .mac(at: ended, waitsForOnline: true)), 1)
    }

    /// A request that never left gives its try back, and keeps its day.
    func testATryThatNeverLeftCostsNothingHereEither() throws {
        var writer = try XCTUnwrap(CloudNotesRedo.withoutNotes(.failed, now: ended))
        writer.onlineTries = 1
        let back = CloudNotesRedo.afterFailedTry(writer, neverLeft: true, now: ended)
        XCTAssertEqual(back.onlineTries, 0)
        XCTAssertEqual(back.notBefore, writer.notBefore)
        XCTAssertEqual(back.noNotesYet, .failed)
    }

    /// This month's notes used: it waits for the day they come back, and the
    /// refusal costs no try. The Mac's own notes stop at it, as before.
    func testAUsedMonthMakesItWaitForTheDayAndCostsNoTry() throws {
        let until = Fixture.date("2026-11-01T00:00:00Z")
        var writer = try XCTUnwrap(CloudNotesRedo.withoutNotes(.mac(.offline), now: ended))
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.allowanceUsed(until: until)), writer: writer),
                       .waitUntil(until))
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.allowanceUsed(until: until)),
                                           writer: .mac(at: ended, waitsForOnline: true)), .stop)
        XCTAssertEqual(CloudNotesRedo.step(for: .mac(.offline), writer: writer), .stop)
        XCTAssertEqual(CloudNotesRedo.step(for: .online, writer: writer), .send)

        writer.onlineTries = 1
        let refused = CloudNotesRedo.afterAllowanceUsed(writer, until: until, triedNow: true)
        XCTAssertEqual(refused.onlineTries, 0)
        XCTAssertEqual(refused.noNotesYet, .allowanceUsed)
        XCTAssertEqual(refused.notBefore, until)
        XCTAssertTrue(refused.waitsForOnline)
        let told = CloudNotesRedo.afterAllowanceUsed(writer, until: until, triedNow: false)
        XCTAssertEqual(told.onlineTries, 1, "not sent, so nothing to give back")
    }

    /// The service looks again on the earliest day a call waits for; one
    /// already due but not sent is looked at again in an hour, not every
    /// minute; calls waiting only for the network don't plan a look.
    func testTheNextLookIsTheEarliestDay() throws {
        let now = ended.addingTimeInterval(60)
        let soon = try XCTUnwrap(CloudNotesRedo.withoutNotes(.failed, now: ended))
        let later = try XCTUnwrap(CloudNotesRedo.withoutNotes(
            .mac(.allowanceUsed(until: Fixture.date("2026-11-01T00:00:00Z"))), now: ended))
        let network = try XCTUnwrap(CloudNotesRedo.withoutNotes(.mac(.offline), now: ended))
        XCTAssertEqual(CloudNotesRedo.nextLook([call(startedAfter: 1, writer: later),
                                                call(startedAfter: 2, writer: soon),
                                                call(startedAfter: 3, writer: network)], now: now),
                       ended.addingTimeInterval(3_600))
        XCTAssertEqual(CloudNotesRedo.nextLook([call(startedAfter: 1, writer: soon)],
                                               now: ended.addingTimeInterval(7_200)),
                       ended.addingTimeInterval(7_200 + CloudNotesRedo.lookAgainAfter))
        XCTAssertNil(CloudNotesRedo.nextLook([call(startedAfter: 3, writer: network),
                                              call(startedAfter: 4, writer: .mac(at: ended, waitsForOnline: true)),
                                              call(startedAfter: 5, writer: soon, ended: false)], now: now))
    }
}

// MARK: - The record, the page and the files

final class CloudNotesFilesTests: XCTestCase {
    func testAnOlderRecordReadsWithoutAWriterAndWritesNone() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let plain = String(decoding: try encoder.encode(Fixture.record()), as: UTF8.self)
        XCTAssertFalse(plain.contains("notesWriter"), "meeting.json is what it always was")
        XCTAssertNil(try decoder.decode(MeetingRecord.self, from: Data(plain.utf8)).notesWriter)

        let written = Fixture.record(writer: .online(model: "gemini-x", at: Fixture.start))
        XCTAssertEqual(try decoder.decode(MeetingRecord.self, from: encoder.encode(written)), written)

        let early = #"{"place": "mac", "writtenAt": "2026-10-14T10:00:00Z"}"#
        XCTAssertEqual(try decoder.decode(MeetingNotesWriter.self, from: Data(early.utf8)),
                       MeetingNotesWriter(place: .mac, model: nil, writtenAt: Fixture.date("2026-10-14T10:00:00Z")))
    }

    private func page(_ writer: MeetingNotesWriter?) -> String {
        MeetingFiles.notesPage(for: Fixture.record(), notes: MeetingNotes(
            summary: "A call to plan the launch.",
            decisions: [.init(text: "Launch on the twentieth", sources: [3], at: 30)]),
            writer: writer, timeZone: Fixture.utc)
    }

    func testNotesWrittenOfflineSaySoUnderTheDate() {
        let waiting = page(.mac(at: Fixture.start, waitsForOnline: true))
        XCTAssertTrue(waiting.contains(
            "\n\n_Written on this Mac while offline. They'll be improved once you're back online._\n\n## "))
        XCTAssertEqual(MeetingFiles.withoutWaitingLine(waiting), page(nil))
        XCTAssertEqual(page(.mac(at: Fixture.start)), page(nil), "the Mac's notes, online or not, read as today")
    }

    private func emptyPage(_ writer: MeetingNotesWriter?) -> String {
        MeetingFiles.notesPage(for: Fixture.record(), notes: nil, unavailableReason: "Made up.",
                               writer: writer, timeZone: Fixture.utc)
    }

    /// A page with no notes yet says why, and when they will come.
    func testAPageWithNoNotesYetSaysWhenTheyWillCome() throws {
        let ended = Fixture.date("2026-10-14T10:00:00Z")
        let until = Fixture.date("2026-11-01T00:00:00Z")
        let offline = try XCTUnwrap(CloudNotesRedo.withoutNotes(.mac(.offline), now: ended))
        let failed = try XCTUnwrap(CloudNotesRedo.withoutNotes(.failed, now: ended))
        let used = try XCTUnwrap(CloudNotesRedo.withoutNotes(.mac(.allowanceUsed(until: until)), now: ended))
        XCTAssertTrue(emptyPage(offline).contains(
            "\n\n_No notes yet. They'll be written online once you're back online._\n\n"))
        XCTAssertTrue(emptyPage(failed).contains(
            "\n\n_No notes yet. The online notes service didn't answer, so Airlock will try again later._\n\n"))
        XCTAssertEqual(MeetingFiles.waitingLine(for: used, locale: Locale(identifier: "en_GB"), timeZone: Fixture.utc),
                       "No notes yet. This month's online notes are used up, so these will be written on 1 November.")
        XCTAssertTrue(emptyPage(offline).contains("No summary this time: Made up."), "and still why the Mac wrote none")
        XCTAssertNil(MeetingFiles.waitingLine(for: CloudNotesRedo.stopped(failed)))
        XCTAssertNil(MeetingFiles.waitingLine(for: nil))
    }

    /// The line follows the wait: changed in place when the reason or the
    /// day changes, gone once it stops waiting; nothing else moves.
    func testTheWaitingLineIsPutRightInPlace() throws {
        let ended = Fixture.date("2026-10-14T10:00:00Z")
        let until = Fixture.date("2026-11-01T00:00:00Z")
        let offline = try XCTUnwrap(CloudNotesRedo.withoutNotes(.mac(.offline), now: ended))
        let used = CloudNotesRedo.afterAllowanceUsed(offline, until: until, triedNow: false)
        XCTAssertEqual(MeetingFiles.withWaitingLine(emptyPage(offline), for: used, timeZone: Fixture.utc),
                       emptyPage(used))
        XCTAssertEqual(MeetingFiles.withWaitingLine(emptyPage(used), for: offline, timeZone: Fixture.utc),
                       emptyPage(offline))
        XCTAssertEqual(MeetingFiles.withWaitingLine(emptyPage(used), for: CloudNotesRedo.stopped(used)),
                       emptyPage(nil))
        XCTAssertEqual(MeetingFiles.withoutWaitingLine(emptyPage(offline)), emptyPage(nil))
        XCTAssertEqual(MeetingFiles.withWaitingLine(emptyPage(nil), for: used), emptyPage(nil),
                       "a page without one is left as it is")
        XCTAssertEqual(MeetingFiles.withWaitingLine(page(.mac(at: ended, waitsForOnline: true)), for: nil),
                       page(nil), "the Mac's offline line too")
    }

    /// Older records have neither field; new ones read back whole.
    func testANoNotesWriterReadsBack() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let writer = MeetingNotesWriter.noNotes(.allowanceUsed, at: Fixture.date("2026-10-14T10:00:00Z"),
                                                notBefore: Fixture.date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(try decoder.decode(MeetingNotesWriter.self, from: encoder.encode(writer)), writer)
        let old = #"{"place": "mac", "writtenAt": "2026-10-14T10:00:00Z", "waitsForOnline": true}"#
        let read = try decoder.decode(MeetingNotesWriter.self, from: Data(old.utf8))
        XCTAssertNil(read.noNotesYet)
        XCTAssertNil(read.notBefore)
        let future = #"{"place": "mac", "writtenAt": "2026-10-14T10:00:00Z", "noNotesYet": "somethingNew"}"#
        XCTAssertNil(try decoder.decode(MeetingNotesWriter.self, from: Data(future.utf8)).noNotesYet,
                     "a reason this build doesn't know is read as none")
    }

    func testNotesWrittenOnlineSaySoAtTheFoot() {
        let online = page(.online(model: "gemini-x", at: Fixture.start))
        XCTAssertTrue(online.contains("_Written online by Airlock, with Google's Gemini. No audio was kept."))
        XCTAssertFalse(online.contains("Written on this Mac"))
        XCTAssertFalse(online.contains("model"))
        XCTAssertTrue(page(nil).contains("_Written on your Mac. No audio was kept."))
    }

    /// Notes the Mac wrote say so, on every plan; when the online service
    /// was meant to write them, the foot says it didn't answer instead. No
    /// foot names a model or a file.
    func testTheMacsNotesSayTheMacWroteThem() {
        for plan in AirlockPlan.allCases {
            let snapshot = PlanSnapshot(plan: plan, isPaid: plan != .free)
            let mac = page(.mac(at: Fixture.start, why: .plan, plan: snapshot))
            XCTAssertTrue(mac.contains("\n_Written on your Mac. No audio was kept. "), plan.label)
            let down = page(.mac(at: Fixture.start, why: .serviceDown, plan: snapshot))
            XCTAssertTrue(down.contains("\n_The online notes service didn't answer, so these were written on your "
                                        + "Mac. No audio was kept. "), plan.label)
            for page in [mac, down] {
                XCTAssertFalse(page.contains("model"), plan.label)
                XCTAssertFalse(page.contains(MeetingFiles.transcriptName), plan.label)
            }
        }
        XCTAssertTrue(emptyPage(nil).contains("_Written on this Mac by Airlock. No audio was kept."),
                      "a page without notes names no model")
        XCTAssertFalse(emptyPage(nil).contains(MeetingFiles.transcriptName))
    }

    /// The foot names whose model wrote them, from the model the server
    /// says it used; one it doesn't know is left unnamed rather than guessed.
    func testTheFootNamesWhoseModelWroteThem() {
        XCTAssertTrue(page(.online(model: "openai/gpt-6.1-sol", at: Fixture.start))
            .contains("_Written online by Airlock, with OpenAI's GPT. "))
        XCTAssertTrue(page(.online(model: "google/gemini-3.8-flash", at: Fixture.start))
            .contains("with Google's Gemini. "))
        XCTAssertTrue(page(.online(model: "somebody/else-1", at: Fixture.start))
            .contains("_Written online by Airlock. No audio was kept."))
        XCTAssertEqual(CloudNotes.maker(ofModel: nil), "Google's Gemini", "notes from before the model was kept")
        XCTAssertEqual(CloudNotes.maker(ofModel: "gpt-6.1-sol"), "OpenAI's GPT")
        XCTAssertEqual(CloudNotes.maker(ofModel: "gemini-x"), "Google's Gemini")
        XCTAssertNil(CloudNotes.maker(ofModel: "anthropic/claude"))
    }

    func testAnEarlierPageIsNeverWrittenOver() {
        XCTAssertEqual(MeetingFiles.earlierNotesName(existing: []), "Notes (earlier version).md")
        XCTAssertEqual(MeetingFiles.earlierNotesName(existing: ["Notes.md", "Notes (earlier version).md"]),
                       "Notes (earlier version) 2.md")
        XCTAssertEqual(MeetingFiles.earlierNotesName(
            existing: ["Notes (earlier version).md", "Notes (earlier version) 2.md"]),
                       "Notes (earlier version) 3.md")
    }

    func testTheStoreKeepsEarlierPagesAndTheWriter() throws {
        let scratch = TestScratch("cn")
        let store = MeetingStore(root: scratch.root)
        let record = Fixture.record()
        let folder = try store.makeFolder(for: record, timeZone: Fixture.utc)
        try store.saveTranscript(record, in: folder)

        XCTAssertNil(try store.keepEarlierNotes(in: folder), "nothing to keep yet")
        try store.saveNotes("first\n", in: folder)
        XCTAssertEqual(try store.keepEarlierNotes(in: folder), "Notes (earlier version).md")
        try store.saveNotes("second\n", in: folder)
        XCTAssertEqual(try store.keepEarlierNotes(in: folder), "Notes (earlier version) 2.md")
        try store.saveNotes("third\n", in: folder)
        let read = { (name: String) in try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }
        XCTAssertEqual(try read("Notes (earlier version).md"), "first\n")
        XCTAssertEqual(try read("Notes (earlier version) 2.md"), "second\n")
        XCTAssertEqual(store.notesPage(in: folder), "third\n")

        let waiting = MeetingNotesWriter.mac(at: Fixture.start, waitsForOnline: true)
        try store.saveNotesWriter(waiting, in: folder)
        XCTAssertEqual(store.loadRecord(in: folder)?.notesWriter, waiting)
        try store.saveNames(of: record, in: folder, timeZone: Fixture.utc)
        XCTAssertEqual(store.loadRecord(in: folder)?.notesWriter, waiting, "naming a voice keeps who wrote them")
    }

    func testTheWaitingLineGoesFromBothPages() throws {
        let scratch = TestScratch("cn")
        let store = MeetingStore(root: scratch.root)
        let record = Fixture.record()
        let folder = try store.makeFolder(for: record, timeZone: Fixture.utc)
        try store.saveTranscript(record, in: folder)
        try store.saveNotes(page(.mac(at: Fixture.start, waitsForOnline: true)), in: folder)
        try store.dropWaitingLine(in: folder)
        XCTAssertEqual(store.notesPage(in: folder), page(nil))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(MeetingStore.notesAsWrittenName),
                                  encoding: .utf8), page(nil))
    }
}
