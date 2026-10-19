import XCTest
@testable import AirlockCore

/// Free, Plus and Pro: what each may do, what a task keeps when the plan
/// changes under it, and the "You're on Free now" card built from both.
final class PlansTests: XCTestCase {
    private let plus = PlanSnapshot(plan: .plus, isPaid: true)
    private let pro = PlanSnapshot(plan: .pro, isPaid: true)
    /// A trial from before plans: everything Plus has, never paid.
    private let trial = PlanSnapshot(plan: .plus, isPaid: false)

    /// 15 November 2026, 09:00 UTC.
    private let ended = Date(timeIntervalSince1970: 1_794_733_200)
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    private func license(renewsAt: Date, plan: License.Plan = .plus) -> License {
        License(id: "lic_1", email: "a@b.com", product: "airlock", period: .monthly,
                issued: renewsAt.addingTimeInterval(-30 * 86_400), renewsAt: renewsAt,
                checkBy: renewsAt.addingTimeInterval(14 * 86_400), plan: plan)
    }

    // MARK: - Plans

    func testAPlanIsWhatTheLicencePaidFor() {
        XCTAssertEqual(AirlockPlan(License.Plan.plus), .plus)
        XCTAssertEqual(AirlockPlan(License.Plan.pro), .pro)
        XCTAssertEqual(AirlockPlan.allCases.map(\.label), ["Free", "Plus", "Pro"])
    }

    /// Notes go online only on a paid plan with money known to be flowing.
    func testOnlyAPaidPlanWritesNotesOnline() {
        XCTAssertFalse(PlanSnapshot.free.limits.writesNotesOnline)
        XCTAssertFalse(PlanSnapshot(plan: .free, isPaid: true).limits.writesNotesOnline)
        XCTAssertFalse(trial.limits.writesNotesOnline, "a trial has no token to ask with")
        XCTAssertFalse(PlanSnapshot(plan: .pro, isPaid: false).limits.writesNotesOnline, "overdue")
        XCTAssertTrue(plus.limits.writesNotesOnline)
        XCTAssertTrue(pro.limits.writesNotesOnline)
    }

    func testWhatIsLostGoingToFree() {
        let free = PlanSnapshot.free.limits
        let limits: [PlanLimits.Difference] = [.shorterClipboard, .oneAgentAtATime, .shorterCallNotes,
                                               .voicesTogether]
        XCTAssertEqual(plus.limits.lost(goingTo: free), limits + [.notesOnTheMac])
        XCTAssertEqual(pro.limits.lost(goingTo: free), limits + [.notesOnTheMac])
        XCTAssertEqual(trial.limits.lost(goingTo: free), limits, "a trial never wrote notes online")
        XCTAssertEqual(free.lost(goingTo: free), [])
        XCTAssertEqual(free.lost(goingTo: plus.limits), [], "nothing is lost going up")
    }

    /// Free's limits, one table, read wherever they apply.
    func testFreesLimits() {
        let free = PlanSnapshot.free.limits
        XCTAssertEqual(free.clipboardShows, 100)
        XCTAssertTrue(free.oneAgentAtATime)
        XCTAssertEqual(free.notesListenFor, 30 * 60)
        XCTAssertFalse(free.tellsVoicesApart)
        XCTAssertFalse(PlanSnapshot(plan: .free, isPaid: true).limits.tellsVoicesApart)
        for paid in [plus, pro, trial, PlanSnapshot(plan: .pro, isPaid: false)] {
            XCTAssertNil(paid.limits.clipboardShows)
            XCTAssertFalse(paid.limits.oneAgentAtATime)
            XCTAssertNil(paid.limits.notesListenFor)
            XCTAssertTrue(paid.limits.tellsVoicesApart, "on the Mac, so it goes by the plan alone")
        }
    }

    func testTheLimitsAreSaidPlainly() {
        XCTAssertEqual(PlanLimits.Difference.shorterClipboard.sentence(macWritesNotes: true),
                       "The clipboard shows your last 100 copies. Older ones are kept out of sight for 30 days.")
        XCTAssertEqual(PlanLimits.Difference.oneAgentAtATime.sentence(macWritesNotes: true),
                       "The notch answers one coding agent at a time. Others ask in their own terminal.")
        XCTAssertEqual(PlanLimits.Difference.shorterCallNotes.sentence(macWritesNotes: false),
                       "Call notes cover the first 30 minutes of each call.")
        XCTAssertEqual(PlanLimits.Difference.voicesTogether.sentence(macWritesNotes: true),
                       "Everyone on the other side of a call is \u{201C}Them\u{201D}. Telling voices apart comes with Plus.")
        for change in [PlanLimits.Difference.shorterClipboard, .oneAgentAtATime, .shorterCallNotes,
                       .voicesTogether] {
            XCTAssertFalse(change.symbol.isEmpty)
        }
    }

    /// Without Apple Intelligence the Mac writes no notes, so the row says
    /// what is kept instead of promising notes that never come.
    func testTheChangeIsSaidForTheMacItIsOn() {
        let change = PlanLimits.Difference.notesOnTheMac
        XCTAssertEqual(change.sentence(macWritesNotes: true), "Call notes are written on this Mac, not online.")
        XCTAssertEqual(change.sentence(macWritesNotes: false),
                       "Calls keep their transcript. Notes need Apple Intelligence, or Plus.")
        XCTAssertFalse(change.symbol.isEmpty)
    }

    // MARK: - A task keeps the plan it started on

    func testATaskNeverLosesWhatItStartedWith() {
        XCTAssertEqual(PlanSnapshot.kept(startedOn: pro, now: .free), pro)
        XCTAssertEqual(PlanSnapshot.kept(startedOn: plus, now: .free), plus)
        XCTAssertEqual(PlanSnapshot.kept(startedOn: plus, now: PlanSnapshot(plan: .plus, isPaid: false)), plus)
    }

    func testABiggerPlanBoughtSinceCounts() {
        XCTAssertEqual(PlanSnapshot.kept(startedOn: .free, now: plus), plus)
        XCTAssertEqual(PlanSnapshot.kept(startedOn: plus, now: pro), pro)
        XCTAssertEqual(PlanSnapshot.kept(startedOn: trial, now: plus), plus, "paid outranks unpaid")
    }

    func testATaskFromBeforePlansGoesByThePlanNow() {
        XCTAssertEqual(PlanSnapshot.kept(startedOn: nil, now: .free), .free)
        XCTAssertEqual(PlanSnapshot.kept(startedOn: nil, now: pro), pro)
    }

    /// Kept in `meeting.json`, and a call from before plans still opens.
    func testACallRemembersItsPlan() throws {
        let record = MeetingRecord(bundleID: "a", appName: "A", startedAt: ended, startedOn: pro)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MeetingRecord.self, from: encoder.encode(record)).startedOn, pro)

        let old = #"{"bundleID":"a","appName":"A","startedAt":"2026-10-08T14:10:00Z"}"#
        XCTAssertNil(try decoder.decode(MeetingRecord.self, from: Data(old.utf8)).startedOn)
    }

    // MARK: - What is remembered before Free

    func testWhatIsRememberedAboutEachEntitlement() throws {
        XCTAssertNil(PlanBefore(.free, trialStarted: nil))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let started = ended.addingTimeInterval(-3 * 86_400)
        let fromTrial = try XCTUnwrap(PlanBefore(.trialing(daysRemaining: 11), trialStarted: started,
                                                 calendar: calendar))
        XCTAssertEqual(fromTrial, PlanBefore(plan: trial, ending: .trial,
                                             endedOn: PlanBefore.trialEnds(started: started, calendar: calendar)))

        let key = license(renewsAt: ended, plan: .pro)
        for entitlement: Entitlement in [.licensed(key), .grace(key), .overdue(key)] {
            XCTAssertEqual(PlanBefore(entitlement, trialStarted: started),
                           PlanBefore(plan: pro, ending: .subscription, endedOn: ended),
                           "as it was bought, not as it limped along: \(entitlement)")
        }
    }

    /// Started mid-afternoon on the 1st, the last trial day is the 14th, so
    /// the 15th at midnight is when it ended.
    func testATrialEndsAtTheStartOfItsFirstDayWithNoneLeft() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let started = Date(timeIntervalSince1970: 1_793_545_200)  // 1 Nov 2026, 15:00 UTC
        XCTAssertEqual(PlanBefore.trialEnds(started: started, calendar: calendar),
                       Date(timeIntervalSince1970: 1_794_700_800))  // 15 Nov 2026, 00:00 UTC
        XCTAssertEqual(Entitlement.resolve(verdict: nil, trialStarted: started,
                                           now: Date(timeIntervalSince1970: 1_794_700_800), calendar: calendar),
                       .free)
        XCTAssertEqual(Entitlement.resolve(verdict: nil, trialStarted: started,
                                           now: Date(timeIntervalSince1970: 1_794_700_799), calendar: calendar),
                       .trialing(daysRemaining: 1))
    }

    func testWhatIsRememberedSurvivesARestart() throws {
        let before = PlanBefore(plan: pro, ending: .subscription, endedOn: ended)
        XCTAssertEqual(try JSONDecoder().decode(PlanBefore.self, from: JSONEncoder().encode(before)), before)
    }

    // MARK: - The card

    func testTheCardIsDueOnceOnFreeAfterAnotherPlan() {
        let before = PlanBefore(plan: plus, ending: .subscription, endedOn: ended)
        XCTAssertNotNil(FreeCard.due(entitlement: .free, before: before, seen: false))
        XCTAssertNil(FreeCard.due(entitlement: .free, before: before, seen: true), "seen")
        XCTAssertNil(FreeCard.due(entitlement: .free, before: nil, seen: false), "a new install: nothing ended")
        let key = license(renewsAt: ended.addingTimeInterval(30 * 86_400))
        for entitlement: Entitlement in [.trialing(daysRemaining: 3), .licensed(key), .grace(key), .overdue(key)] {
            XCTAssertNil(FreeCard.due(entitlement: entitlement, before: before, seen: false), "\(entitlement)")
        }
    }

    func testTheCardListsOnlyWhatTheLimitsTakeAway() throws {
        let afterTrial = try XCTUnwrap(FreeCard.due(entitlement: .free,
                                                    before: PlanBefore(plan: trial, ending: .trial, endedOn: ended),
                                                    seen: false))
        XCTAssertEqual(afterTrial.changes, [.shorterClipboard, .oneAgentAtATime, .shorterCallNotes, .voicesTogether])
        let afterPro = try XCTUnwrap(FreeCard.due(entitlement: .free,
                                                  before: PlanBefore(plan: pro, ending: .subscription, endedOn: ended),
                                                  seen: false))
        XCTAssertEqual(afterPro.changes, [.shorterClipboard, .oneAgentAtATime, .shorterCallNotes, .voicesTogether,
                                           .notesOnTheMac])
    }

    private func message(_ before: PlanBefore, now: Date) -> String {
        FreeCard.due(entitlement: .free, before: before, seen: false)!.message(now: now, locale: gb, timeZone: utc)
    }

    func testTheCardSaysWhatEndedAndThatNothingIsGone() {
        let later = ended.addingTimeInterval(86_400)
        XCTAssertEqual(message(PlanBefore(plan: trial, ending: .trial, endedOn: ended), now: later),
                       "Your trial ended on 15 November. Airlock keeps working, and nothing you made is gone. "
                           + "What changes:")
        XCTAssertEqual(message(PlanBefore(plan: trial, ending: .trial, endedOn: nil), now: later),
                       "Your trial has ended. Airlock keeps working, and nothing you made is gone. What changes:")
        XCTAssertEqual(message(PlanBefore(plan: pro, ending: .subscription, endedOn: ended), now: later),
                       "Your Pro subscription ended on 15 November. Airlock keeps working, and nothing you "
                           + "made is gone. What changes:")
    }

    /// A paid-up date still ahead, or none: the key stopped working here
    /// rather than running out, and the card does not claim it "ended".
    func testAKeyThatStoppedWorkingIsNotCalledEnded() {
        let earlier = ended.addingTimeInterval(-86_400)
        for endedOn in [ended, nil] {
            XCTAssertTrue(message(PlanBefore(plan: plus, ending: .subscription, endedOn: endedOn), now: earlier)
                .hasPrefix("Your Plus licence no longer works on this Mac. Airlock keeps working"))
        }
    }

    func testTheCardNamesNoTrialAndBothPrices() {
        XCTAssertEqual(FreeCard.title, "You're on Free now")
        XCTAssertTrue(FreeCard.prices.contains(License.Period.monthly.price))
        XCTAssertTrue(FreeCard.prices.contains(License.Period.yearly.price))
    }

    // MARK: - First-run setup

    /// Setup promises no trial, and names only what Plus is known to add.
    func testSetupSaysThereIsNoTrial() {
        XCTAssertEqual(PlanSetupNote.title, "Airlock is free")
        XCTAssertTrue(PlanSetupNote.detail.hasPrefix("No trial and no card."))
        XCTAssertTrue(PlanSetupNote.detail.contains("Plus writes your call notes online"))
        XCTAssertTrue(PlanSetupNote.detail.contains(License.Period.monthly.price))
        XCTAssertFalse(PlanSetupNote.detail.lowercased().contains("days"), "no countdown")
    }
}

/// The Apple Intelligence row in first-run setup.
final class AppleIntelligenceSetupTests: XCTestCase {
    func testOnIsTickedAndOffersNothing() {
        let row = AppleIntelligenceSetup.row(.ready)
        XCTAssertTrue(row.isOn)
        XCTAssertNil(row.tag)
        XCTAssertNil(row.button)
        XCTAssertTrue(row.detail.hasPrefix("On."))
    }

    /// Switched off: one button to the pane with the switch, and what to do
    /// when the switch is not there.
    func testSwitchedOffOpensSystemSettings() {
        let row = AppleIntelligenceSetup.row(.needsAppleIntelligence)
        XCTAssertFalse(row.isOn)
        XCTAssertEqual(row.tag, "switched off")
        XCTAssertEqual(row.button, .openSystemSettings)
        XCTAssertTrue(row.detail.contains("Turn it on in System Settings"))
        XCTAssertTrue(row.detail.contains("language or region"))
    }

    /// Can't be turned on: no button to a dead end, and what the plans mean
    /// for this Mac.
    func testAMacThatCannotRunItIsToldWhatThatMeans() {
        let row = AppleIntelligenceSetup.row(.deviceNotEligible)
        XCTAssertFalse(row.isOn)
        XCTAssertEqual(row.tag, "not on this Mac")
        XCTAssertNil(row.button)
        XCTAssertTrue(row.detail.contains("On Free, calls get a transcript but no notes."))
        XCTAssertTrue(row.detail.contains("Plus writes notes online on any Mac."))
    }

    func testStillDownloadingWorksOnceItFinishes() {
        let row = AppleIntelligenceSetup.row(.modelNotReady)
        XCTAssertFalse(row.isOn)
        XCTAssertEqual(row.tag, "downloading")
        XCTAssertNil(row.button, "nothing to do but wait")
        XCTAssertTrue(row.detail.contains("once it finishes"))
    }

    func testAReasonThisBuildDoesNotKnowGuessesNothing() {
        let row = AppleIntelligenceSetup.row(.unknown("something new"))
        XCTAssertFalse(row.isOn)
        XCTAssertNil(row.tag)
        XCTAssertEqual(row.button, .openSystemSettings)
        XCTAssertFalse(row.detail.contains("something new"))
    }

    func testTheButtonOpensAppleIntelligenceAndSiri() throws {
        let button = AppleIntelligenceSetup.Button.openSystemSettings
        XCTAssertEqual(button.title, "Open System Settings")
        let url = try XCTUnwrap(button.url)
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url.absoluteString.contains("Siri-Settings"))
    }

    /// Every line leads with what it is for, bar the one for a Mac that
    /// cannot run it, which leads with that.
    func testEveryLineSaysWhatItIsFor() {
        for availability: ModelAvailability in [.ready, .needsAppleIntelligence, .modelNotReady, .unknown("x")] {
            XCTAssertTrue(AppleIntelligenceSetup.row(availability).detail.contains(AppleIntelligenceSetup.purpose),
                          "\(availability)")
        }
    }
}
