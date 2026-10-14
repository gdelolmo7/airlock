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
            + "At most 8 decisions, 15 to-dos, 8 open questions and 5 key points.\n"
            + #"Answer with JSON only, in this shape: {"summary": "...", "decisions": [{"text": "...", "#
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
            "Take notes from this call.\nPeople on the call: You, and Marta Vidal (the other side).\n\nTRANSCRIPT START\n"))
        XCTAssertFalse(prompt.contains("The person wrote"))
    }

    func testAMeetingInTheRoomIsCalledAMeeting() {
        let record = Fixture.record(bundleID: OngoingCall.inPersonBundleID, attendees: nil)
        XCTAssertTrue(CallNotesPrompts.cloud(for: record, language: nil).hasPrefix("Take notes from this meeting.\n"))
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
        CloudNotesConditions(hiddenSwitch: true, setting: true, entitlement: subscriber, hasToken: true,
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
        XCTAssertEqual(route { $0.entitlement = .trialing(daysRemaining: 9) }, .mac(.notSubscribed))
        XCTAssertEqual(route { $0.entitlement = .free }, .mac(.notSubscribed))
        XCTAssertEqual(route { $0.entitlement = .trialExpired }, .mac(.notSubscribed))
        if case let .licensed(license) = subscriber {
            XCTAssertEqual(route { $0.entitlement = .overdue(license) }, .mac(.notSubscribed), "run out")
            XCTAssertEqual(route { $0.entitlement = .grace(license) }, .online, "grace is still paid")
        }
        XCTAssertEqual(route { $0.hasToken = false }, .mac(.noToken))
        XCTAssertEqual(route { $0.hasServer = false }, .mac(.noServer))
        XCTAssertEqual(route { $0.words = MeetingNotes.minimumWords - 1 }, .mac(.tooShort))
        XCTAssertEqual(route { $0.promptSize = CloudNotes.promptLimit + 1 }, .mac(.tooLong))
        XCTAssertEqual(route { $0.promptSize = CloudNotes.promptLimit }, .online)
        XCTAssertEqual(route { $0.notEligibleUntil = later }, .mac(.notEligible(until: later)))
        XCTAssertEqual(route { $0.notEligibleUntil = earlier }, .online, "a day later, it asks again")
        XCTAssertEqual(route { $0.allowanceUntil = later }, .mac(.allowanceUsed(until: later)))
        XCTAssertEqual(route { $0.allowanceUntil = earlier }, .online, "after resetsAt, it asks again")
        XCTAssertEqual(route { $0.online = false }, .mac(.offline))
    }

    /// The hidden switch first: off, nothing else is even looked at, and
    /// today's notes are written exactly as they were.
    func testTheFirstReasonThatHoldsIsTheOneGiven() {
        let nothing = CloudNotesConditions(hiddenSwitch: false, setting: false, entitlement: .trialExpired,
                                           hasToken: false, hasServer: false, online: false, words: 0,
                                           promptSize: .max, allowanceUntil: .distantFuture,
                                           notEligibleUntil: .distantFuture, now: now)
        var conditions = nothing
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.hiddenSwitchOff))
        conditions.hiddenSwitch = true
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.settingOff))
        conditions.setting = true
        XCTAssertEqual(CloudNotesRoute.decide(conditions), .mac(.notSubscribed))
        conditions.entitlement = subscriber
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
                      .mac(.notEligible(until: now)), .mac(.notAsked), .mac(.notAskedOffline)] {
            XCTAssertFalse(route.waitsForOnline, "\(route)")
        }
    }

    // MARK: Asked once, before anything leaves

    /// Not asked yet sends nothing, and is the one case that asks: only
    /// when everything else would have sent it.
    func testNotAskedYetIsWrittenOnTheMacAndAsks() {
        XCTAssertEqual(route { $0.setting = nil }, .mac(.notAsked))
        XCTAssertTrue(CloudNotesRoute.mac(.notAsked).asks)
        XCTAssertEqual(route { $0.setting = true }, .online)
        XCTAssertEqual(route { $0.setting = false }, .mac(.settingOff), "said no: never asked again")
        XCTAssertFalse(CloudNotesRoute.mac(.settingOff).asks)
    }

    /// Never for a trial, offline, over the month's allowance, or notes that
    /// couldn't go online anyway: those say why, and ask nothing.
    func testNothingIsAskedWhenTheNotesCouldNotGoOnlineAnyway() {
        let later = now.addingTimeInterval(3_600)
        let unasked: [(inout CloudNotesConditions) -> Void] = [
            { $0.entitlement = .trialing(daysRemaining: 9) },
            { $0.entitlement = .free },
            { $0.online = false },
            { $0.allowanceUntil = later },
            { $0.notEligibleUntil = later },
            { $0.words = MeetingNotes.minimumWords - 1 },
            { $0.promptSize = CloudNotes.promptLimit + 1 },
            { $0.hasToken = false },
            { $0.hasServer = false },
            { $0.hiddenSwitch = false },
        ]
        let expected: [CloudNotesRoute] = [
            .mac(.notSubscribed), .mac(.notSubscribed), .mac(.notAskedOffline),
            .mac(.allowanceUsed(until: later)), .mac(.notEligible(until: later)), .mac(.tooShort),
            .mac(.tooLong), .mac(.noToken), .mac(.noServer), .mac(.hiddenSwitchOff),
        ]
        for (change, reason) in zip(unasked, expected) {
            let decided = route {
                $0.setting = nil
                change(&$0)
            }
            XCTAssertEqual(decided, reason)
            XCTAssertFalse(decided.asks, "\(decided)")
        }
    }

    /// Offline and not asked yet: written on the Mac like any other, and
    /// nothing promised, since nobody has said they may go online.
    func testOfflineAndNotAskedPromisesNothing() {
        let decided = route {
            $0.setting = nil
            $0.online = false
        }
        XCTAssertEqual(decided, .mac(.notAskedOffline))
        XCTAssertFalse(decided.waitsForOnline)
        XCTAssertEqual(route { $0.online = false }, .mac(.offline), "said yes: written again once online")
    }

    func testTheReasonsAreLoggedInWords() {
        XCTAssertEqual(CloudNotesRoute.Reason.notAsked.logName, "not asked yet")
        XCTAssertEqual(CloudNotesRoute.Reason.notAskedOffline.logName, "offline, not asked yet")
        XCTAssertEqual(CloudNotesRoute.Reason.settingOff.logName, "said no")
    }
}

// MARK: - The question

final class CloudNotesQuestionTests: XCTestCase {
    /// Absent is not asked yet, and the switch shows off until a yes.
    func testTheSwitchIsOnOnlyAfterAYes() {
        XCTAssertFalse(CloudNotesQuestion.switchIsOn(nil))
        XCTAssertFalse(CloudNotesQuestion.switchIsOn(false))
        XCTAssertTrue(CloudNotesQuestion.switchIsOn(true))
    }

    /// Says where the transcript goes, that nobody keeps it, and the way back.
    func testTheWordsSayWhereItGoesAndThatNobodyKeepsIt() {
        XCTAssertEqual(CloudNotesQuestion.title, "Write better notes online?")
        XCTAssertEqual(CloudNotesQuestion.text,
                       "Airlock can send this meeting's transcript through its server to Google's Gemini, which "
                       + "writes clearer notes and finds the real to-dos. Neither Airlock nor Google keeps it, "
                       + "and it isn't used to train AI.")
        XCTAssertEqual(CloudNotesQuestion.settingsLine, "You can change this in Settings.")
        XCTAssertEqual(CloudNotesQuestion.keepButton, "Keep on this Mac")
        XCTAssertEqual(CloudNotesQuestion.writeButton, "Write online")
        XCTAssertEqual(CloudNotesQuestion.settingsSubtitle,
                       "When a meeting ends, its transcript goes through Airlock's server to Google's Gemini to "
                       + "write better notes. Neither Airlock nor Google keeps it, and it isn't used to train AI. "
                       + "Off, or without internet, notes are written on this Mac.")
    }

    /// "Write online": the Mac's notes, never sent, set waiting so the
    /// queue writes them again online now. Nothing else is sent again.
    func testWritingOnlineNowSetsOnlyTheMacsUnsentNotesWaiting() throws {
        let mac = MeetingNotesWriter.mac(at: Fixture.start)
        let waiting = try XCTUnwrap(CloudNotesRedo.writeOnlineNow(mac))
        XCTAssertTrue(waiting.waitsForOnline)
        XCTAssertEqual(waiting.onlineTries, 0)
        XCTAssertEqual(CloudNotesRedo.waiting([(URL(fileURLWithPath: "/meetings/x"),
                                                Fixture.record(endedAfter: 90, writer: waiting))]).count, 1)
        var sent = mac
        sent.onlineTries = 1
        XCTAssertNil(CloudNotesRedo.writeOnlineNow(sent), "sent once already")
        XCTAssertNil(CloudNotesRedo.writeOnlineNow(.online(model: "m", at: Fixture.start)), "already online")
        XCTAssertNil(CloudNotesRedo.writeOnlineNow(nil), "an older record, no writer")
    }
}

// MARK: - The month's allowance

final class CloudNotesAllowanceTests: XCTestCase {
    private let britain = Locale(identifier: "en_GB")
    private let now = Fixture.date("2026-10-14T09:30:00Z")

    func testTheMessageSaysUntilWhenInDayAndMonth() {
        let until = Fixture.date("2026-11-01T00:00:00Z")
        XCTAssertEqual(CloudNotesAllowance.message(until: until, locale: britain, timeZone: Fixture.utc),
                       "You've used this month's online notes. Notes are written on your Mac until 1 November.")
        XCTAssertEqual(CloudNotesAllowance.day(until, locale: Locale(identifier: "en_US"), timeZone: Fixture.utc),
                       "November 1")
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
                       "You've used this month's online notes. Notes are written on your Mac until 1 November. "
                       + "Upgrade for more.")
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
        XCTAssertEqual(MeetingFiles.withoutOfflineLine(waiting), page(nil))
        XCTAssertEqual(page(.mac(at: Fixture.start)), page(nil), "the Mac's notes, online or not, read as today")
    }

    func testNotesWrittenOnlineSaySoAtTheFoot() {
        let online = page(.online(model: "gemini-x", at: Fixture.start))
        XCTAssertTrue(online.contains("_Written online by Airlock, with Google's Gemini, from "
                                      + "\(MeetingFiles.transcriptName). No audio was kept."))
        XCTAssertFalse(online.contains("Written on this Mac"))
        XCTAssertTrue(page(nil).contains("_Written on this Mac by Airlock from \(MeetingFiles.transcriptName)."))
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

    func testTheOfflineLineGoesFromBothPages() throws {
        let scratch = TestScratch("cn")
        let store = MeetingStore(root: scratch.root)
        let record = Fixture.record()
        let folder = try store.makeFolder(for: record, timeZone: Fixture.utc)
        try store.saveTranscript(record, in: folder)
        try store.saveNotes(page(.mac(at: Fixture.start, waitsForOnline: true)), in: folder)
        try store.dropOfflineLine(in: folder)
        XCTAssertEqual(store.notesPage(in: folder), page(nil))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(MeetingStore.notesAsWrittenName),
                                  encoding: .utf8), page(nil))
    }
}
