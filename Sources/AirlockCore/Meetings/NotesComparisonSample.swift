import Foundation

/// The call "What each plan writes" shows three times: a made-up 42-minute
/// budget review between you, Marta and Joan, and the notes each plan wrote
/// of it. Nobody's call: written by hand for this, so nothing real is shown
/// and nothing is sent to show it.
///
/// The notes were written once, by the model each plan uses, and are kept as
/// the pages those models wrote (`NotesComparisonPages`), so the window shows
/// what each plan really writes and asks nothing of the network or of the
/// Mac's model. Free's notes heard only the first 30 minutes, as Free's do.
/// `NotesComparisonSampleMaker` (a test, opt-in, and the online two cost a
/// few cents) writes them again after a model changes.
public enum NotesComparisonSample {
    /// How long the call was, in minutes.
    public static let minutes = 42
    /// How much of it Free's notes heard.
    public static let freeListened = PlanLimits.freeNotesListen
    /// The minutes Free's notes leave out.
    public static var freeLeavesOut: Int { minutes - Int(freeListened / 60) }

    /// The pages are kept with their date in this zone, so the header they
    /// are read without is the same on every Mac.
    public static let timeZone = TimeZone(identifier: "UTC")!
    static let startedAt = Date(timeIntervalSince1970: 1_790_413_200)

    /// The voices on the other side, by the order they first spoke.
    static let martaVoice = 1
    static let joanVoice = 2

    /// The whole call, as Plus and Pro hear it.
    public static var record: MeetingRecord {
        call(lines.map { line in
            MeetingSegment(speaker: line.voice == nil ? .me : .them, start: line.at,
                           end: line.at + max(3, Double(line.text.count) / 15), text: line.text,
                           person: line.voice)
        })
    }

    /// The call as Free hears it: Marta and Joan are one "Them", since
    /// telling voices apart is Plus's, and notes stopped at 30 minutes and
    /// the call went on without them.
    public static var freeRecord: MeetingRecord {
        var heard = call(record.segments.filter { $0.start < freeListened }.map { line in
            var line = line
            line.person = nil
            return line
        }, names: [])
        heard.stoppedAtLimit = freeListened
        return heard
    }

    private static func call(_ segments: [MeetingSegment],
                             names: [MeetingVoiceName] = [MeetingVoiceName(voice: martaVoice, name: "Marta"),
                                                          MeetingVoiceName(voice: joanVoice, name: "Joan")])
        -> MeetingRecord {
        MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: startedAt,
                      endedAt: startedAt + TimeInterval(minutes * 60), languages: ["en_US"],
                      segments: segments,
                      event: MeetingEvent(title: "Budget review", start: startedAt, attendees: ["Marta", "Joan"]),
                      names: names)
    }

    /// The page each plan wrote, as it was written: Plus's and Pro's
    /// writers read "Person 2", never a name (`MeetingRecord.voiceLabel(for:)`),
    /// and Free's read one "Them".
    public static func written(_ plan: AirlockPlan) -> String {
        switch plan {
        case .free: NotesComparisonPages.free
        case .plus: NotesComparisonPages.plus
        case .pro: NotesComparisonPages.pro
        }
    }

    /// The page each plan wrote, with Marta's and Joan's names put in, as a
    /// call's notes are saved once its voices have names (`MeetingNaming`).
    public static func page(_ plan: AirlockPlan) -> String {
        MeetingNaming.apply(plan == .free ? freeRecord : record, to: written(plan))
    }

    /// The cards of `plan`'s page: without its title and date, the lines
    /// under the date that say how the notes came to be, and the closing
    /// line. Only what the notes say, to set side by side.
    public static func sections(_ plan: AirlockPlan) -> [MeetingPage.Section] {
        let header = MeetingFiles.header(of: plan == .free ? freeRecord : record, timeZone: timeZone)
        let placed = MeetingPage.placed(MeetingPage.body(of: page(plan), header: header))
        return CallNotesNotice.split(MeetingPage.sections(placed).sections).sections
    }

    // MARK: - What was said

    private struct Line {
        let at: TimeInterval
        /// Nil for you.
        let voice: Int?
        let text: String
    }

    private static func you(_ clock: String, _ text: String) -> Line { Line(at: seconds(clock), voice: nil, text: text) }
    private static func marta(_ clock: String, _ text: String) -> Line { Line(at: seconds(clock), voice: martaVoice, text: text) }
    private static func joan(_ clock: String, _ text: String) -> Line { Line(at: seconds(clock), voice: joanVoice, text: text) }

    private static func seconds(_ clock: String) -> TimeInterval {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
    }

    /// The first 30 minutes: the quarter's numbers, marketing €18k over from
    /// the autumn campaign, the September invoice, travel halved to cover
    /// it, revised numbers by Friday. The last 12: the offsite moves to
    /// January, the agency's new terms need legal before 1 November, and
    /// whether the travel cut takes in the Lisbon client visit, left open.
    private static let lines: [Line] = [
        you("0:04", "Morning, both. Thanks for making time. I'd like to go through the quarter's budget first, and then a couple of things about the offsite and the agency."),
        marta("0:19", "Morning. I have the numbers up. Do you want the overview first?"),
        you("0:26", "Yes, start with the overview, please."),
        marta("0:31", "Overall we closed the quarter about four percent over plan. Salaries are on plan, software is slightly under, and office costs are flat."),
        marta("0:52", "The one line that stands out is marketing. Marketing is eighteen thousand euros over plan."),
        joan("1:06", "That's mostly the autumn campaign. We ran a second wave of ads in September that wasn't in the original plan."),
        you("1:22", "Was the second wave approved?"),
        joan("1:27", "It was agreed in July, but it never made it into the budget sheet. That one is on me."),
        you("1:41", "Okay. So the eighteen thousand is mostly the autumn campaign."),
        marta("1:49", "About fifteen of the eighteen is the campaign. The rest is the agency's September invoice, which is higher than usual."),
        joan("2:06", "The September invoice looked wrong to me as well. I think they billed us twice for the video edits."),
        you("2:21", "Can you ask the agency about it?"),
        joan("2:25", "Sure. I'll ask the agency about the September invoice this week."),
        marta("2:37", "If it was billed twice, that's about three thousand back, which helps, but it doesn't solve the problem."),
        you("2:50", "Right. What does the rest of the year look like if we change nothing?"),
        marta("3:01", "If we change nothing, we end the year around twenty-five thousand over. The board asked us to be back on plan by December."),
        you("3:18", "So we need to find the money this quarter."),
        marta("3:24", "Yes. Ideally the whole eighteen thousand."),
        you("3:31", "What are the options?"),
        marta("3:36", "Three, really. We delay the new hire, we cut the events budget, or we cut travel."),
        joan("3:52", "Please don't touch events. The trade fair in November is where most of our leads come from."),
        you("4:06", "Agreed, events stay. And I don't want to delay the hire either. We need that person in January, not in March."),
        marta("4:20", "Then it's travel. Travel this quarter is budgeted at thirty-six thousand."),
        you("4:31", "What if we halve it?"),
        marta("4:36", "Halving travel saves eighteen thousand. That covers marketing almost exactly."),
        joan("4:48", "Halving is a lot. Some of those trips are customer visits, not just internal meetings."),
        you("5:01", "I know. But it's only for this quarter. We go back to the normal budget in January."),
        joan("5:13", "If it's only for the quarter, I can live with it."),
        marta("5:20", "I'd put one rule on it: internal trips become video calls, and customer trips need your approval."),
        you("5:33", "That's fair. Let's decide it, then. Travel is halved for the rest of the quarter."),
        marta("5:43", "Fine by me. I'll update the forecast with that."),
        joan("5:50", "And I'll tell my team not to book anything new until the rules are written down."),
        you("6:02", "Good. Marta, how long do you need for the revised numbers?"),
        marta("6:10", "I need the agency answer first, and the travel bookings that are already paid. Give me until Friday."),
        you("6:23", "Friday works. Send the revised numbers to both of us by Friday."),
        marta("6:30", "Will do."),
        you("6:41", "Let's go through the other lines quickly, so there are no surprises later."),
        marta("6:49", "Software first. We're two thousand under, because the design tool renewal moved to January."),
        you("7:04", "Is that a real saving or just a later invoice?"),
        marta("7:10", "Just later. It shows up again in the first quarter."),
        you("7:17", "Then don't count it as a saving."),
        marta("7:22", "I won't. Office costs are flat. The new lease starts in March, so nothing changes this year."),
        joan("7:40", "What about the coffee machine? Half the office keeps asking."),
        marta("7:47", "That's eight hundred euros. It fits in office costs if nothing else breaks."),
        you("7:55", "Let's leave the coffee machine for January. It's not the moment."),
        joan("8:03", "Fair enough."),
        marta("8:15", "Salaries are on plan. The bonus accrual is in, at the same level as last year."),
        you("8:28", "And revenue?"),
        marta("8:32", "Revenue is three percent above plan, mostly from the two renewals in August."),
        you("8:44", "So we're over on cost and over on revenue. The margin is still fine?"),
        marta("8:52", "The margin is fine. The problem is only that the board looks at each cost line against its own plan."),
        joan("9:07", "So even if the campaign paid for itself, it still shows as over."),
        marta("9:14", "Exactly. And to be fair, we don't know yet whether it paid for itself."),
        you("9:23", "Joan, do we have numbers on the campaign?"),
        joan("9:28", "Early ones. About four hundred new leads, and twenty-two of them are already in talks with sales."),
        you("9:42", "That's not bad for six weeks."),
        joan("9:47", "It's good. The cost per lead is lower than the spring campaign, even with the second wave."),
        marta("10:01", "Can you put that in writing? It would help when I explain the overspend to the board."),
        joan("10:09", "I'll put two slides together for you."),
        you("10:20", "Let's talk about how we stop this from happening again."),
        you("10:28", "Anything agreed outside the budget sheet should go into the sheet the same week."),
        marta("10:38", "I'd like a monthly check as well. Fifteen minutes, every first Monday, just the lines that moved."),
        joan("10:51", "I'm fine with that, as long as it really is fifteen minutes."),
        you("10:58", "It will be. Marta, can you set it up?"),
        marta("11:03", "Yes, I'll send an invite."),
        you("11:15", "Back to travel for a moment. Who decides what counts as a customer trip?"),
        marta("11:24", "I'd say you, since you approve them. Anything with a customer meeting on the calendar counts."),
        joan("11:38", "Sales will push back. They travel the most."),
        you("11:45", "I'll talk to the head of sales myself. It's three months, not forever."),
        joan("11:54", "That helps."),
        marta("12:10", "One more thing on the forecast. The euro to dollar rate moved, and two of our tools bill in dollars."),
        you("12:23", "How much difference?"),
        marta("12:27", "A few hundred euros a month. Not enough to change anything today, but I'll keep an eye on it."),
        you("12:38", "Okay. Keep it in the forecast, but don't act on it yet."),
        joan("13:00", "Can I raise the spring campaign while we're on marketing?"),
        you("13:06", "Go ahead."),
        joan("13:09", "We planned it at the same size as the autumn one. With what we learnt, I'd like to keep the size and change the mix."),
        marta("13:24", "As long as the total doesn't change, that's your call."),
        joan("13:31", "The total stays the same. More video, fewer display ads."),
        you("13:40", "Fine. Put it in the plan you bring next month."),
        marta("14:02", "Should we look at the hiring plan as well, since it came up?"),
        you("14:08", "Briefly. The January hire stays. Anything else?"),
        marta("14:14", "The second hire is in April. I'd keep it, but only if the first quarter lands on plan."),
        you("14:26", "Agreed. We decide the April hire in March."),
        joan("14:33", "Makes sense."),
        you("15:10", "Let me check I have everything for the board."),
        you("15:16", "Marketing is eighteen thousand over, mostly the autumn campaign. Travel is halved for the quarter to cover it. Events and the January hire stay."),
        marta("15:34", "That's it. Plus whatever comes back from the agency on the invoice."),
        joan("15:42", "I'll chase them tomorrow morning."),
        marta("16:20", "One question from me. Do we tell the whole team about the travel cut, or only the managers?"),
        you("16:31", "The whole team. Better they hear it from us than find out when a booking gets refused."),
        joan("16:42", "I can write the note, if you want."),
        you("16:47", "Please. Keep it short, and say it's only until January."),
        marta("17:40", "On the board meeting itself, it's on the twelfth. I'd like the deck ready on the eighth."),
        you("17:51", "That's fine. Put my part last, I'll present the plan to get back on budget."),
        marta("18:02", "Okay."),
        joan("19:15", "Going back to the agency. Apart from the invoice, they're asking about next year."),
        you("19:23", "Let's keep that for the end. I have it on my list."),
        joan("19:28", "Sure."),
        marta("21:05", "I've just looked at the paid travel bookings. About four thousand is already spent this quarter."),
        you("21:16", "So the cut is from what's left."),
        marta("21:20", "Yes. It still works, but it's tighter than it sounds."),
        you("21:28", "Understood. Let's see it in Friday's numbers."),
        joan("23:40", "Sorry, someone at the door. I'm back."),
        you("23:46", "No problem."),
        marta("25:02", "I'll also move the design tool renewal into the first quarter forecast, so nobody counts it twice."),
        you("25:12", "Good."),
        you("27:30", "Anything else on the budget before we move on?"),
        marta("27:36", "Nothing from me."),
        joan("27:40", "Nothing else."),
        you("28:55", "Then let's take a short break and come back for the last two things."),
        // The notes stop listening at 30 minutes on Free.
        you("30:20", "Okay, two more things before we finish. First, the offsite."),
        joan("30:30", "The team offsite is booked for the second week of December, in Girona."),
        marta("30:45", "That's about eleven thousand with the hotel and the train."),
        you("31:00", "With travel cut, December feels wrong. What if we move the offsite to January?"),
        joan("31:13", "January works. The hotel is cheaper then, too."),
        marta("31:20", "And it lands in next year's budget, which takes eleven thousand off this quarter."),
        you("31:31", "Then the offsite moves to January. I'll move it, and I'll call the hotel this week."),
        joan("31:42", "The deposit is refundable until the end of October, so there's time."),
        you("31:52", "Good, I'll do it before then."),
        joan("34:00", "Second thing: the agency sent new terms for next year."),
        joan("34:12", "They want a twelve-month contract and a higher monthly fee, about ten percent more."),
        marta("34:26", "Has legal seen it?"),
        joan("34:30", "Not yet."),
        marta("34:34", "Legal has to approve the new agency terms before anyone signs. Their review usually takes two weeks."),
        joan("34:49", "That's the problem. If the terms aren't approved before the first of November, the spring campaign slips."),
        you("35:04", "Then let's get legal on it now. Joan, can you send it to them today?"),
        joan("35:12", "Yes. I'll get legal to approve the agency terms before the first of November."),
        marta("35:24", "And I'd like to see the fee before it's signed. Ten percent more is real money."),
        joan("35:32", "I'll copy you in."),
        you("36:10", "Do we want to push back on the twelve months?"),
        joan("36:16", "I'd ask for six months with an option to extend. They'll probably accept."),
        you("36:25", "Try that. If they won't, twelve is acceptable."),
        joan("38:00", "One question about the travel cut. Does it include the client visit in Lisbon?"),
        marta("38:12", "Good question. That trip alone is about four thousand."),
        you("38:20", "I'm not sure. The client is important, and they asked to meet in person."),
        joan("38:31", "We need to know soon. The flights get expensive after next week."),
        you("38:40", "Let's leave Lisbon open for now. I want to talk to the account manager first."),
        marta("38:52", "Okay, I'll keep it out of the forecast until we know."),
        you("40:30", "Anything else from either of you?"),
        marta("40:36", "No, that's everything. Revised numbers on Friday."),
        joan("40:42", "Nothing else from me."),
        you("41:30", "Great. Thanks, both. Talk soon."),
        marta("41:36", "Thanks. Bye."),
        joan("41:40", "Bye."),
    ]
}
