import SwiftUI
import AirlockCore

/// A call's transcript watched while it is written (K): the window that
/// sits beside the call, and the notes window on the call that is on.
///
/// The call is made inside each row's draw, so its clock and "just now"
/// read the same however long the gallery took to reach it.
@MainActor
enum GalleryLiveTranscript {
    static let area = "Call notes"

    static var states: [GalleryState] {
        let states: [GalleryState] = [
            GalleryState("K53", area, "Side window: following the call as it is written",
                         ground: .window, width: side.width) {
                window(record())
            },
            GalleryState("K54", area, "Side window: scrolled up, \"3 new lines\" to come back down",
                         ground: .window, width: side.width) {
                window(record(), scrolledAwayFor: 3)
            },
            GalleryState("K55", area, "Side window: notes paused",
                         ground: .window, width: side.width) {
                window(record(), paused: true)
            },
            GalleryState("K56", area, "Side window: call over, the notes being written",
                         ground: .window, width: side.width) {
                window(record(ended: true))
            },
            GalleryState("K57", area, "Side window: the notes are ready, with two to-dos",
                         ground: .window, width: side.width) {
                window(record(ended: true), outcome: .saved(.notes, todos: 2))
            },
            GalleryState("K58", area, "Side window: the notes stopped mid-call",
                         ground: .window, width: side.width) {
                window(record(), outcome: .failed("Notes stopped: the microphone went away."))
            },
            GalleryState("K59", area, "Window: the call that is on, its transcript live",
                         ground: .window, width: GalleryMeetings.size.width) {
                calls(.transcript)
            },
            GalleryState("K60", area, "Window: the call that is on, its notes tab",
                         ground: .window, width: GalleryMeetings.size.width) {
                calls(.notes)
            },
            GalleryState("K63", area, "Side window: your words in grey at the end of your last line as you say them",
                         ground: .window, width: side.width) {
                let record = record()
                return window(record, hearing: [saying(.me, "and I'll put the team pricing on the last slide")])
            },
            GalleryState("K64", area, "Side window: the other side starts to speak, in grey on a row of its own",
                         ground: .window, width: side.width) {
                let record = record()
                return window(record, hearing: [saying(.them, "Perfect. Last thing, the website still")])
            },
            GalleryState("K65", area, "Side window: the first words, before any line is written",
                         ground: .window, width: side.width) {
                let record = record(said: false)
                return window(record, hearing: [saying(.them, "Hi! Sorry I'm a minute late, the last call ran over. "
                                                       + "So, the interviews")])
            },
            GalleryState("K66", area, "Window: the call that is on, words in grey as they are said",
                         ground: .window, width: GalleryMeetings.size.width) {
                calls(.transcript, hearing: [(.me, "and I'll put the team pricing on the last slide")])
            },
            GalleryState("K68", area, "Side window: a meeting in person, the room as Someone, the cloud once for each run",
                         ground: .window, width: side.width) {
                let record = record(inPerson: true)
                return window(record, hearing: [saying(.them, "Perfect. Last thing, the website still")])
            },
            GalleryState("K69", area, "Window: a meeting in person, the cloud and name once for each run",
                         ground: .window, width: GalleryMeetings.size.width) {
                calls(.transcript, inPerson: true, hearing: [(.them, "Perfect. Last thing, the website still")])
            },
            GalleryState("K73", area, "Side window: two people told apart while the meeting goes on, Person 2 being named",
                         ground: .window, width: side.width) {
                window(record(inPerson: true, twoPeople: true), naming: 2)
            },
        ]
        // Each opens on the newest line, which takes a run loop to settle.
        return states.map { var state = $0; state.settles = true; return state }
    }

    static let side = CGSize(width: 360, height: 640)

    private static func window(_ record: MeetingRecord, paused: Bool = false, outcome: CallLive.Outcome? = nil,
                               hearing: [CallLive.Hearing] = [], scrolledAwayFor: Int? = nil,
                               naming: Int? = nil) -> some View {
        LiveTranscriptView(live: CallNotesLive(previewing: record, outcome: outcome, hearing: hearing),
                           actions: LiveTranscriptActions(isPaused: { paused }, pause: {}, resume: {}, stop: {},
                                                          open: { _ in }, close: {}),
                           scrolledAwayFor: scrolledAwayFor, naming: naming)
            .frame(width: side.width, height: side.height)
            .background(CallsLook.sidebar)
            .environment(\.colorScheme, .dark)
    }

    private static func calls(_ tab: CallNotesLibrary.Tab, inPerson: Bool = false,
                              hearing: [(MeetingSpeaker, String)] = []) -> some View {
        let record = record(inPerson: inPerson)
        let live = CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/check-in-live"),
                                         record: record, page: nil)
        return CallNotesView()
            .environment(CallNotesLibrary(previewing: [live], tab: tab, hand: .stop, live: true,
                                          hearing: hearing.map { saying($0.0, $0.1) }))
            .frame(width: GalleryMeetings.size.width, height: GalleryMeetings.size.height)
    }

    /// `speaker` saying `text` now, begun a second ago.
    private static func saying(_ speaker: MeetingSpeaker, _ text: String) -> CallLive.Hearing {
        CallLive.Hearing(speaker: speaker, text: text, since: Date().addingTimeInterval(-1))
    }

    /// A weekly check-in 12:45 in, its last line said three seconds ago.
    /// Ended, it ran 13 minutes, and Mariana had the last word.
    /// `said` false: the call has just begun and nothing is written yet.
    /// `inPerson`: the same talk in a room, with no calendar name for it.
    /// `twoPeople`: the room told apart, its lines Person 1's and Person 2's
    /// in turn.
    private static func record(ended: Bool = false, said: Bool = true, inPerson: Bool = false,
                               twoPeople: Bool = false) -> MeetingRecord {
        let now = Date()
        let started = now.addingTimeInterval(ended ? -15 * 60 : -765)
        var turns: [(MeetingSpeaker, TimeInterval, TimeInterval, String)] = [
            (.them, 681, 687, "Hi! Sorry I'm a minute late, the last call ran over."),
            (.me, 689, 694, "No problem. How did the interviews go?"),
            (.them, 697, 706, "Really well. Two of the five want to try it next week, and one asked about a team plan."),
            (.me, 708, 713, "Good. Send me their names and I'll set them up."),
            (.them, 722, 727, "Will do. The one asking about teams runs a studio of twelve people."),
            (.me, 729, 734, "Then let's give them a month free and see how they use it."),
            (.them, 736, 741, "Makes sense. Should I promise anything about the price?"),
            (.me, 744, 749, "Not yet. Say we'll have team pricing before the end of the month."),
            (.them, 751, 756, "Okay. And the slides for Thursday, are you still doing those?"),
            (.me, 758, 762, "Yes, I'll have a draft by Wednesday so you can look at it."),
        ]
        if ended {
            turns += [
                (.them, 766, 770, "Perfect. Last thing, the website still says beta."),
                (.me, 772, 775, "Good catch. I'll fix it today."),
                (.them, 778, 781, "Great, that's all from me."),
            ]
        }
        return MeetingRecord(
            bundleID: inPerson ? OngoingCall.inPersonBundleID : "us.zoom.xos",
            appName: inPerson ? "In person" : "Zoom", startedAt: started,
            endedAt: ended ? started.addingTimeInterval(13 * 60 + 5) : nil, languages: ["en-GB"],
            segments: said ? turns.enumerated().map { index, turn in
                MeetingSegment(speaker: turn.0, start: turn.1, end: turn.2, text: turn.3,
                               person: twoPeople && turn.0 == .them ? index / 2 % 2 + 1 : nil)
            } : [],
            event: inPerson ? nil
                : MeetingEvent(title: "Weekly check-in", start: started, attendees: ["Mariana García-Robles"]))
    }
}
