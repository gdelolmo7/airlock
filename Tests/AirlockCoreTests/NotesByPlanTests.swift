import Foundation
import XCTest
@testable import AirlockCore

/// Call notes by plan (Free, Plus, Pro, a trial from before plans) and by
/// what the Mac's own model can do (ready, Apple Intelligence switched off,
/// a Mac that can't run it): what the page says, and what the notes window
/// offers beside it (`CallNotesOffers`).
final class NotesByPlanTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")
    private let online = CallNotesOffers.Online(exists: true, settingOn: true, blocked: false)
    private let firstOfNovember = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!

    private static let plus = PlanSnapshot(plan: .plus, isPaid: true)
    private static let pro = PlanSnapshot(plan: .pro, isPaid: true)
    /// Everything Plus has but online notes, which need money flowing.
    private static let trial = PlanSnapshot(plan: .plus, isPaid: false)
    private static let plans: [(name: String, plan: PlanSnapshot)] = [
        ("Free", .free), ("Plus", plus), ("Pro", pro), ("a trial from before plans", trial),
    ]

    private var ended: Date { NotesComparisonSample.record.endedAt! }

    private func notes() -> MeetingNotes {
        MeetingNotes(summary: "Marketing is over budget; halving travel covers it.",
                     todos: [.init(text: "Send the revised numbers", owner: "Marta", at: 383)])
    }

    /// The example call with `writer` on its record, and its page: notes
    /// when the Mac's model is ready or they were written online, none
    /// otherwise.
    private func call(_ writer: MeetingNotesWriter?, model: ModelAvailability = .ready,
                      stopped: Bool = false) -> (record: MeetingRecord, page: String) {
        var record = stopped ? NotesComparisonSample.freeRecord : NotesComparisonSample.record
        record.notesWriter = writer
        let written = model == .ready || writer?.place == .online
        let page = MeetingFiles.notesPage(for: record, notes: written ? notes() : nil, writer: writer,
                                          noModel: model == .ready ? nil : model, locale: gb, timeZone: utc)
        return (record, page)
    }

    private func offers(_ call: (record: MeetingRecord, page: String), on plan: PlanSnapshot,
                        online: CallNotesOffers.Online? = nil) -> CallNotesOffers {
        CallNotesOffers.of(call.record, page: call.page, plan: plan, online: online ?? self.online)
    }

    /// The Mac's own notes, and why it wrote them on `plan`.
    private func macWriter(_ plan: PlanSnapshot, why: MeetingNotesWriter.MacWhy? = nil) -> MeetingNotesWriter {
        .mac(at: ended, why: why ?? (plan.limits.writesNotesOnline ? .setting : .plan), plan: plan)
    }

    /// The first paragraph under the date: the one a notice or the empty
    /// card is read from. A page's lines run on into one paragraph until a
    /// blank line, as in any Markdown.
    private func firstParagraph(_ call: (record: MeetingRecord, page: String)) -> String? {
        let header = MeetingFiles.header(of: call.record, timeZone: utc)
        for block in MeetingPage.body(of: call.page, header: header) {
            if case .paragraph(let text) = block { return CallNotesNotice.plain(text) }
        }
        return nil
    }

    // MARK: - Apple Intelligence on

    /// Notes the Mac wrote: Free (and an old trial) are offered a look at
    /// what Plus writes and a redo that opens the plans, tagged Plus; a paid
    /// plan gets a redo that writes them online, untagged.
    func testTheMacsNotesOfferPlusOnFreeAndARedoOnPaidPlans() {
        for (name, plan) in Self.plans {
            let offered = offers(call(macWriter(plan)), on: plan)
            if plan.limits.writesNotesOnline {
                XCTAssertEqual(offered, CallNotesOffers(redo: .rewritesOnline), name)
                XCTAssertFalse(offered.redoTagged, name)
            } else {
                XCTAssertEqual(offered, CallNotesOffers(seePlus: true, redo: .opensPlans), name)
                XCTAssertTrue(offered.redoTagged, name)
            }
            XCTAssertTrue(call(macWriter(plan)).page.contains("_\(MeetingFiles.basicModelFooter), from "), name)
        }
    }

    /// Nothing is offered beside notes written online, on any plan now.
    func testNotesWrittenOnlineOfferNothing() {
        for (name, plan) in Self.plans {
            let written = call(.online(model: "google/gemini-3.8-flash", at: ended, plan: Self.plus))
            XCTAssertEqual(offers(written, on: plan), CallNotesOffers(), name)
            XCTAssertFalse(written.page.contains("basic model"), name)
        }
    }

    /// A copy without online notes offers nothing that would lead there.
    func testACopyWithoutOnlineNotesOffersNothing() {
        for (name, plan) in Self.plans {
            XCTAssertEqual(offers(call(macWriter(plan)), on: plan, online: CallNotesOffers.Online.none),
                           CallNotesOffers(), name)
        }
    }

    /// A paid plan whose redo can't be asked now (notes online off in
    /// Settings, or the server said no) doesn't show the button; Free's
    /// opens the plans whatever the server says.
    func testARedoThatCantBeAskedIsNotOffered() {
        let off = CallNotesOffers.Online(exists: true, settingOn: false, blocked: false)
        let blocked = CallNotesOffers.Online(exists: true, settingOn: true, blocked: true)
        for plan in [Self.plus, Self.pro] {
            XCTAssertNil(offers(call(macWriter(plan)), on: plan, online: off).redo)
            XCTAssertNil(offers(call(macWriter(plan)), on: plan, online: blocked).redo)
        }
        XCTAssertEqual(offers(call(macWriter(.free)), on: .free, online: blocked).redo, .opensPlans)
    }

    /// A call that hasn't ended, or where too little was said, has nothing
    /// to write again.
    func testOnlyAnEndedCallWithEnoughSaidCanBeRedone() {
        var running = call(macWriter(Self.plus))
        running.record.endedAt = nil
        XCTAssertNil(offers(running, on: Self.plus).redo)
        XCTAssertTrue(offers(running, on: .free).seePlus, "the look at Plus is still offered")

        var short = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: ended.addingTimeInterval(-60),
                                  endedAt: ended, segments: [MeetingSegment(speaker: .them, start: 1, end: 3,
                                                                            text: "Hello, can you hear me?")])
        short.notesWriter = macWriter(.free)
        let page = MeetingFiles.notesPage(for: short, notes: notes(), writer: short.notesWriter, timeZone: utc)
        XCTAssertNil(CallNotesOffers.of(short, page: page, plan: .free, online: online).redo)
    }

    /// Notes from before plans (no writer kept) read as the Mac's.
    func testAPageFromBeforePlansGetsTheSameOffers() {
        XCTAssertEqual(offers(call(nil), on: .free), CallNotesOffers(seePlus: true, redo: .opensPlans))
        XCTAssertEqual(offers(call(nil), on: Self.pro), CallNotesOffers(redo: .rewritesOnline))
    }

    // MARK: - Apple Intelligence switched off

    /// Free, with Apple Intelligence off: no notes, and the page says to
    /// turn it on (the window adds the button to System Settings). No look
    /// at Plus and no redo: there are no notes to compare or redo.
    func testAppleIntelligenceSwitchedOffSaysToTurnItOn() {
        for (name, plan) in Self.plans where !plan.limits.writesNotesOnline {
            let empty = call(macWriter(plan), model: .needsAppleIntelligence)
            XCTAssertEqual(firstParagraph(empty), MeetingFiles.turnOnAppleIntelligence
                           + " Airlock writes call notes with your Mac's own model, and Apple Intelligence is "
                           + "switched off. " + MeetingFiles.transcriptLine, name)
            XCTAssertFalse(MeetingFiles.hasNotes(empty.page), name)
            XCTAssertTrue(empty.page.contains(MeetingFiles.transcriptLine), name)
            XCTAssertEqual(offers(empty, on: plan), CallNotesOffers(empty: .turnOnAppleIntelligence), name)
        }
    }

    /// A paid plan with Apple Intelligence off gets its notes online: the
    /// page is the online one. With notes online switched off it says to
    /// turn Apple Intelligence on, and once notes online are back on, the
    /// redo writes the first notes that call has.
    func testAPaidPlanWithAppleIntelligenceOffWritesOnline() {
        for plan in [Self.plus, Self.pro] {
            let written = call(.online(model: "openai/gpt-6.1-sol", at: ended, plan: plan),
                               model: .needsAppleIntelligence)
            XCTAssertTrue(MeetingFiles.hasNotes(written.page))
            XCTAssertFalse(written.page.contains(MeetingFiles.turnOnAppleIntelligence))

            let settingOff = call(macWriter(plan, why: .setting), model: .needsAppleIntelligence)
            XCTAssertTrue(firstParagraph(settingOff)?.hasPrefix(MeetingFiles.turnOnAppleIntelligence) == true)
            XCTAssertEqual(offers(settingOff, on: plan),
                           CallNotesOffers(redo: .rewritesOnline, empty: .turnOnAppleIntelligence))
        }
    }

    /// Notes on their way online don't tell anyone to turn Apple
    /// Intelligence on: they're coming anyway.
    func testNotesOnTheirWayOnlineDontAskForAppleIntelligence() {
        let waiting = call(.noNotes(.failed, at: ended), model: .needsAppleIntelligence)
        XCTAssertEqual(firstParagraph(waiting), MeetingFiles.noNotesFailedLine)
        XCTAssertFalse(waiting.page.contains(MeetingFiles.turnOnAppleIntelligence))
        XCTAssertEqual(offers(waiting, on: Self.plus), CallNotesOffers(), "the wait asks again by itself")
    }

    // MARK: - A Mac that can't run Apple Intelligence

    /// Free on a Mac that can't run Apple's model: the page says Plus writes
    /// notes online on any Mac, and the window offers the look at Plus.
    func testAMacThatCantRunAppleIntelligenceOffersPlus() {
        for (name, plan) in Self.plans where !plan.limits.writesNotesOnline {
            let empty = call(macWriter(plan), model: .deviceNotEligible)
            XCTAssertEqual(firstParagraph(empty), MeetingFiles.macCantWriteNotes
                           + " Your transcripts are always kept, on every plan. " + MeetingFiles.transcriptLine,
                           name)
            XCTAssertEqual(offers(empty, on: plan), CallNotesOffers(seePlus: true, empty: .cantWriteNotes), name)
        }
    }

    /// On a paid plan, or in a copy without online notes, the page doesn't
    /// sell Plus: the plan already writes online, or nothing could.
    func testTheCantWriteLineIsOnlyForAPlanThatCouldGetPlus() {
        for plan in [Self.plus, Self.pro] {
            let page = call(macWriter(plan, why: .setting), model: .deviceNotEligible).page
            XCTAssertFalse(page.contains(MeetingFiles.macCantWriteNotes))
        }
        let noOnline = call(nil, model: .deviceNotEligible).page
        XCTAssertFalse(noOnline.contains(MeetingFiles.macCantWriteNotes))
        XCTAssertTrue(noOnline.contains("No summary this time"))
        XCTAssertNil(MeetingFiles.noModelLines(.deviceNotEligible, writer: .noNotes(.offline, at: ended)))
    }

    func testNoModelLinesOnlyForAMacWithoutOne() {
        for model: ModelAvailability in [.ready, .modelNotReady, .unknown("Busy")] {
            XCTAssertNil(MeetingFiles.noModelLines(model, writer: macWriter(.free)))
        }
        XCTAssertNil(MeetingFiles.noModelLines(nil, writer: macWriter(.free)))
        XCTAssertEqual(MeetingFiles.noModelLines(.needsAppleIntelligence, writer: nil)?.headline,
                       MeetingFiles.turnOnAppleIntelligence, "switched off is said even without online notes")
    }

    // MARK: - Free's 30 minutes

    func testNotesStoppedByTheLimitSayHowMuchTheyCover() {
        XCTAssertEqual(MeetingFiles.coverLine(30 * 60, of: 42 * 60),
                       "These notes cover the first 30 minutes of a 42-minute call.")
        XCTAssertEqual(MeetingFiles.coverLine(30 * 60), "These notes cover the first 30 minutes.")
        XCTAssertEqual(MeetingFiles.coverLine(30 * 60, of: 30 * 60 + 20), "These notes cover the first 30 minutes.",
                       "not a whole minute longer")
        XCTAssertEqual(MeetingFiles.coverLine(40), "These notes cover the first minute.")

        let stopped = call(macWriter(.free), stopped: true)
        XCTAssertEqual(firstParagraph(stopped), "These notes cover the first 30 minutes of a 42-minute call.")
        XCTAssertNil(firstParagraph(call(macWriter(.free))).flatMap(CallNotesNotice.of),
                     "notes that heard the whole call say nothing")
    }

    // MARK: - This month's online notes used up

    func testUsedUpNotesSayWhenTheyComeBackAndThatProHasMore() {
        XCTAssertEqual(MeetingFiles.allowanceUsedMacLine(backOn: firstOfNovember, plan: Self.plus, locale: gb,
                                                         timeZone: utc),
                       "This month's online notes are used up, so these were written on your Mac. "
                       + "Online notes are back on 1 November. Pro has twice as many.")
        XCTAssertEqual(MeetingFiles.allowanceUsedMacLine(backOn: firstOfNovember, plan: Self.pro, locale: gb,
                                                         timeZone: utc),
                       "This month's online notes are used up, so these were written on your Mac. "
                       + "Online notes are back on 1 November.")
        XCTAssertEqual(MeetingFiles.allowanceUsedMacLine(backOn: nil, plan: Self.pro),
                       "This month's online notes are used up, so these were written on your Mac.")
        XCTAssertEqual(MeetingFiles.noNotesAllowanceLine(until: firstOfNovember, plan: Self.plus, locale: gb,
                                                         timeZone: utc),
                       "No notes yet. You've used this month's online notes, so these will be written on "
                       + "1 November. Pro has twice as many.")
        XCTAssertEqual(MeetingFiles.noNotesAllowanceLine(until: nil),
                       "No notes yet. You've used this month's online notes, so these will be written once they're back.")
    }

    /// Plus, used up: the Mac's notes say so under the date, and the window
    /// offers Pro beside them, not a redo the server would refuse. Pro
    /// isn't offered itself.
    func testUsedUpOnPlusOffersPro() {
        let blocked = CallNotesOffers.Online(exists: true, settingOn: true, blocked: true)
        for plan in [Self.plus, Self.pro] {
            let used = MeetingNotesWriter.mac(at: ended, why: .allowanceUsed, plan: plan, backOn: firstOfNovember)
            let page = call(used)
            XCTAssertEqual(firstParagraph(page).flatMap(CallNotesNotice.of),
                           .allowanceUsed(MeetingFiles.allowanceUsedMacLine(backOn: firstOfNovember, plan: plan,
                                                                            locale: gb, timeZone: utc)))
            XCTAssertEqual(offers(page, on: plan, online: blocked), CallNotesOffers(seePro: plan == Self.plus))
        }
        let waiting = MeetingNotesWriter.noNotes(.allowanceUsed, at: ended, notBefore: firstOfNovember)
        XCTAssertEqual(offers(call(waiting, model: .deviceNotEligible), on: Self.plus, online: blocked),
                       CallNotesOffers(seePro: true), "a page waiting for them gets the same")
    }

    // MARK: - The online service down

    /// Said at the foot on every plan; a paid plan can ask again.
    func testServiceDownIsSaidAtTheFootOnEveryPlan() {
        for (name, plan) in Self.plans {
            let down = call(macWriter(plan, why: .serviceDown))
            XCTAssertTrue(down.page.contains("_\(MeetingFiles.serviceDownFooter), from "), name)
            XCTAssertFalse(down.page.contains(MeetingFiles.basicModelFooter + ","), name)
        }
        XCTAssertEqual(offers(call(macWriter(Self.pro, why: .serviceDown)), on: Self.pro).redo, .rewritesOnline)
    }

    // MARK: - Notices

    func testEachLineUnderTheDateIsReadAsItsNotice() {
        XCTAssertEqual(CallNotesNotice.of("_These notes cover the first 30 minutes._"),
                       .cover("These notes cover the first 30 minutes."))
        let used = MeetingFiles.allowanceUsedMacLine(backOn: nil, plan: Self.plus)
        XCTAssertEqual(CallNotesNotice.of(used), .allowanceUsed(used))
        XCTAssertEqual(CallNotesNotice.of(MeetingFiles.offlineLine), .improvedOnline(MeetingFiles.offlineLine))
        XCTAssertEqual(CallNotesNotice.of(MeetingFiles.turnOnAppleIntelligence), .noModel)
        XCTAssertEqual(CallNotesNotice.of(MeetingFiles.macCantWriteNotes), .noModel)
        XCTAssertEqual(CallNotesNotice.of(MeetingFiles.noNotesOfflineLine),
                       .waitingForNetwork("They'll be written online once you're back online."))
        XCTAssertEqual(CallNotesNotice.of(MeetingFiles.noNotesFailedLine),
                       .waitingForService("The online notes service didn't answer, so Airlock will try again later."))
        XCTAssertEqual(CallNotesNotice.of(MeetingFiles.noNotesAllowanceLine(until: nil)),
                       .waitingForAllowance("You've used this month's online notes, so these will be written once they're back."))
        XCTAssertNil(CallNotesNotice.of("Marketing is over budget."))
        XCTAssertEqual(CallNotesNotice.plain("*Said.*"), "Said.")
        XCTAssertEqual(CallNotesNotice.plain("_"), "_")
    }

    /// The notices come out of the cards, and the card above the first
    /// heading goes when they were all it held.
    func testTheNoticesAreTakenOutOfTheCards() {
        let page = call(.mac(at: ended, why: .allowanceUsed, plan: Self.plus, backOn: firstOfNovember),
                        stopped: true).page
        let header = MeetingFiles.header(of: NotesComparisonSample.freeRecord, timeZone: utc)
        let sections = MeetingPage.sections(MeetingPage.placed(MeetingPage.body(of: page, header: header))).sections
        XCTAssertNil(sections.first?.heading)
        let split = CallNotesNotice.split(sections)
        XCTAssertEqual(split.notices, [
            .allowanceUsed(MeetingFiles.allowanceUsedMacLine(backOn: firstOfNovember, plan: Self.plus,
                                                             locale: gb, timeZone: utc)),
            .cover("These notes cover the first 30 minutes of a 42-minute call."),
        ])
        XCTAssertEqual(split.sections.first?.heading, MeetingFiles.summaryHeading)
        XCTAssertEqual(split.sections.count, sections.count - 1)
    }

    func testOnlyTheNotesHeadingsCountAsNotes() {
        XCTAssertTrue(MeetingFiles.hasNotes(call(macWriter(.free)).page))
        XCTAssertFalse(MeetingFiles.hasNotes(call(macWriter(.free), model: .needsAppleIntelligence).page))
        XCTAssertFalse(MeetingFiles.hasNotes("# Notes: Call\n\n## Your notes\n\n- Ask about Lisbon · 2:00\n"))
        XCTAssertTrue(MeetingFiles.hasNotes("# Notes: Call\n\n## To-dos\n\n- [ ] Ask about Lisbon\n"))
    }

    // MARK: - Why the Mac wrote them

    func testWhyTheMacWroteThemFollowsWhyOnlineWasntAsked() {
        let until = firstOfNovember
        XCTAssertEqual(MeetingNotesWriter.MacWhy(.settingOff), .setting)
        XCTAssertEqual(MeetingNotesWriter.MacWhy(.notSubscribed), .plan)
        XCTAssertEqual(MeetingNotesWriter.MacWhy(.allowanceUsed(until: until)), .allowanceUsed)
        XCTAssertEqual(MeetingNotesWriter.MacWhy(.offline), .offline)
        let other: [CloudNotesRoute.Reason] = [.hiddenSwitchOff, .noToken, .noServer, .tooShort, .tooLong,
                                               .notEligible(until: until)]
        for reason in other { XCTAssertEqual(MeetingNotesWriter.MacWhy(reason), .other) }
    }

    /// Why, plan and back-on day read back; older records have none, and a
    /// reason or plan this build doesn't know reads as none.
    func testTheWriterKeepsWhyAndPlan() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let writer = MeetingNotesWriter.mac(at: firstOfNovember, why: .allowanceUsed, plan: Self.plus,
                                            backOn: firstOfNovember)
        XCTAssertEqual(try decoder.decode(MeetingNotesWriter.self, from: encoder.encode(writer)), writer)
        let old = try decoder.decode(MeetingNotesWriter.self,
                                     from: Data(#"{"place": "mac", "writtenAt": "2026-10-14T10:00:00Z"}"#.utf8))
        XCTAssertNil(old.why)
        XCTAssertNil(old.plan)
        XCTAssertNil(old.backOn)
        let newer = #"{"place": "mac", "writtenAt": "2026-10-14T10:00:00Z", "why": "somethingNew", "#
            + #""plan": {"plan": "ultra", "isPaid": true}}"#
        let read = try decoder.decode(MeetingNotesWriter.self, from: Data(newer.utf8))
        XCTAssertNil(read.why)
        XCTAssertNil(read.plan)
    }

    // MARK: - Dictation's tidy-up

    func testTidyingUpSaysWhenItNeedsAppleIntelligence() throws {
        let off = try XCTUnwrap(TranscriptCleanup.noModelLine(.needsAppleIntelligence))
        XCTAssertTrue(off.contains("switched off on this Mac"))
        XCTAssertTrue(off.contains("dictation types your words as you said them"))
        let cant = try XCTUnwrap(TranscriptCleanup.noModelLine(.deviceNotEligible))
        XCTAssertTrue(cant.contains("which this Mac can't run"))
        for model: ModelAvailability in [.ready, .modelNotReady, .unknown("Busy")] {
            XCTAssertNil(TranscriptCleanup.noModelLine(model))
        }
    }

    // MARK: - What each plan writes

    func testTheExampleCallIsFortyTwoMinutesAndFreeHearsThirty() {
        XCTAssertEqual(NotesComparisonSample.minutes, 42)
        XCTAssertEqual(NotesComparisonSample.freeListened, PlanLimits.freeNotesListen)
        XCTAssertEqual(NotesComparisonSample.freeLeavesOut, 12)
        let whole = NotesComparisonSample.record
        let free = NotesComparisonSample.freeRecord
        XCTAssertTrue(free.segments.allSatisfy { $0.start < PlanLimits.freeNotesListen })
        XCTAssertTrue(whole.segments.contains { $0.start > PlanLimits.freeNotesListen })
        XCTAssertEqual(free.stoppedAtLimit, PlanLimits.freeNotesListen)
        XCTAssertNil(whole.stoppedAtLimit)
        XCTAssertEqual(whole.endedAt?.timeIntervalSince(whole.startedAt), 42 * 60)
    }

    /// Free's page is what the Mac's model wrote of the first 30 minutes,
    /// said at the top and the foot, with Marta and Joan by name.
    func testFreesExamplePageIsTheMacsFromTheFirstThirtyMinutes() throws {
        let page = NotesComparisonSample.page(.free)
        XCTAssertTrue(page.contains("_These notes cover the first 30 minutes of a 42-minute call._"))
        XCTAssertTrue(page.contains("_\(MeetingFiles.basicModelFooter), from "))
        XCTAssertFalse(page.contains("Person "), "names are put in, as on a saved page")
        XCTAssertTrue(NotesComparisonSample.written(.free).contains("Person "), "the writer read voices, not names")
        try assertEverythingSaidBefore(PlanLimits.freeNotesListen, in: page)
        let sections = NotesComparisonSample.sections(.free)
        XCTAssertEqual(sections.first?.heading, MeetingFiles.summaryHeading)
        XCTAssertFalse(sections.contains { $0.heading == nil }, "the lines under the date are not cards")
    }

    /// Plus's and Pro's pages were written online, of the whole call.
    func testThePaidPlansExamplePagesWereWrittenOnline() throws {
        for plan in [AirlockPlan.plus, .pro] {
            let written = NotesComparisonSample.written(plan).trimmingCharacters(in: .whitespacesAndNewlines)
            try XCTSkipIf(written.isEmpty, "\(plan.label)'s example notes are not written yet: run "
                          + "NotesComparisonSampleMaker with an OpenRouter key that has credit.")
            let page = NotesComparisonSample.page(plan)
            XCTAssertTrue(page.contains("_Written online by Airlock, "), plan.label)
            XCTAssertFalse(page.contains("These notes cover"), plan.label)
            XCTAssertFalse(page.contains("Person "), plan.label)
            XCTAssertEqual(NotesComparisonSample.sections(plan).first?.heading, MeetingFiles.summaryHeading,
                           plan.label)
        }
    }

    /// Every time on the page ("· 25:02") is before `limit`.
    private func assertEverythingSaidBefore(_ limit: TimeInterval, in page: String,
                                            line: UInt = #line) throws {
        let times = try NSRegularExpression(pattern: #" · (\d+):(\d\d)$"#, options: .anchorsMatchLines)
        let matches = times.matches(in: page, range: NSRange(page.startIndex..., in: page))
        XCTAssertFalse(matches.isEmpty, line: line)
        for match in matches {
            let minutes = Double((page as NSString).substring(with: match.range(at: 1)))!
            let seconds = Double((page as NSString).substring(with: match.range(at: 2)))!
            XCTAssertLessThan(minutes * 60 + seconds, limit, line: line)
        }
    }
}
