import SwiftUI
import AirlockCore

/// The call notes in the open panel (K), from the ask to the notes ready.
/// Each row is the real `MeetingNotesBanner` over a previewing model, which
/// starts no audio, timer or detector and writes nothing.
///
/// Dates are made inside each row's draw, so a clock or a countdown reads
/// the same however long the gallery took to reach it.
@MainActor
enum GalleryCallNotesPanel {
    static let area = "Call notes"

    static var states: [GalleryState] {
        [
            GalleryState("K13", area, "Panel: notes offered for the call") {
                banner(.offering(meet()), event: weekly)
            },
            GalleryState("K14", area, "Panel: \"Always\" counting down to the notes") {
                banner(.startingSoon(meet(), startsAt: Date().addingTimeInterval(MeetingNotesFlow.countdown)),
                       event: weekly)
            },
            GalleryState("K15", area, "Panel: taking notes, the first minute (heads-up)") {
                let call = meet(since: 25)
                return banner(.recording(call, since: call.startedAt),
                              record: record(of: call, event: weekly, said: opening))
            },
            GalleryState("K16", area, "Panel: taking notes, transcript shown, two jots") {
                let call = faceTime(since: 754)
                return banner(.recording(call, since: call.startedAt),
                              record: record(of: call, event: withAna, said: launchTalk,
                                             jots: ["Pricing copy by Thursday", "Ask about the pictures"]),
                              transcriptShown: true)
            },
            GalleryState("K17", area, "Panel: notes paused") {
                let call = faceTime(since: 412)
                return banner(.recording(call, since: call.startedAt), pausedSince: Date().addingTimeInterval(-38),
                              record: record(of: call, event: withAna, said: launchTalk, jots: ["Pricing copy by Thursday"]))
            },
            GalleryState("K18", area, "Panel: call over, writing the notes") {
                banner(.writing(faceTime(since: 840)), event: withAna)
            },
            GalleryState("K19", area, "Panel: notes ready, five to-dos") {
                let call = meet(since: 1_860)
                return banner(.ready(folder: "/var/empty/weekly", call: call),
                              record: record(of: call, event: weekly, said: opening), notes: weeklyNotes)
            },
            GalleryState("K22", area, "Panel: notes ready, too little said") {
                let call = faceTime(since: 70)
                return banner(.ready(folder: "/var/empty/short", call: call),
                              record: record(of: call, event: nil, said: []),
                              notes: MeetingNotes(summary: MeetingNotes.tooLittle))
            },
            // The fullest the ready panel gets: five to-dos and the line under them.
            GalleryState("K29", area, "Panel: notes ready, minutes with no notes") {
                let call = meet(since: 2_700)
                var notes = weeklyNotes
                notes.unwritten = [.init(start: 1_930, end: 2_645)]
                return banner(.ready(folder: "/var/empty/weekly", call: call),
                              record: record(of: call, event: weekly, said: opening), notes: notes)
            },
            GalleryState("K30", area, "Panel: taking notes, the call moved into Catalan") {
                let call = faceTime(since: 640)
                return banner(.recording(call, since: call.startedAt), record: intoCatalan(call),
                              transcriptShown: true)
            },
            GalleryState("K34", area, "Panel: notes of a meeting in the room, the first minute (heads-up)") {
                let call = room(since: 40)
                return banner(.recording(call, since: call.startedAt),
                              record: record(of: call, event: nil, said: roomOpening))
            },
            GalleryState("K35", area, "Panel: notes of a meeting in the room, voices told apart") {
                let call = room(since: 1_240)
                return banner(.recording(call, since: call.startedAt),
                              record: record(of: call, event: nil, said: roomTalk), transcriptShown: true)
            },
            GalleryState("K36", area, "Panel: room notes stopped when the Mac went to sleep, writing") {
                banner(.writing(room(since: 1_500)), endedBySleep: true)
            },
            GalleryState("K67", area, "Panel: taking notes, transcript shown, words in grey as they are said") {
                let call = faceTime(since: 754)
                return banner(.recording(call, since: call.startedAt),
                              record: record(of: call, event: withAna, said: launchTalk),
                              transcriptShown: true,
                              hearing: [CallLive.Hearing(speaker: .them, text: "Yes, and I think the pictures on "
                                                         + "the first page could be bigger, because right now nobody "
                                                         + "sees what the app actually does until they scroll",
                                                         since: Date())])
            },
            GalleryState("K37", area, "Panel: room notes ready after the Mac went to sleep") {
                let call = room(since: 1_500)
                return banner(.ready(folder: "/var/empty/room", call: call), endedBySleep: true,
                              record: record(of: call, event: nil, said: roomTalk), notes: roomNotes)
            },
            // Said once a month, under the notes the Mac wrote instead. No
            // Upgrade button while `CloudNotesAllowance.offersUpgrade` is off.
            GalleryState("K51", area, "Panel: notes ready, this month's online notes used, no Upgrade yet") {
                let call = meet(since: 1_860)
                let until = Calendar.current.dateInterval(of: .month, for: Date())?.end ?? Date()
                return banner(.ready(folder: "/var/empty/weekly", call: call),
                              record: record(of: call, event: weekly, said: opening), notes: weeklyNotes,
                              allowanceUntil: until)
            },
            // Asked once, under the first notes that could have gone online,
            // before any transcript leaves the Mac. These were written here.
            GalleryState("K52", area, "Panel: notes ready, asked to write notes online") {
                let call = meet(since: 1_860)
                return banner(.ready(folder: "/var/empty/weekly", call: call),
                              record: record(of: call, event: weekly, said: opening), notes: weeklyNotes,
                              asksOnline: true)
            },
        ]
    }

    // MARK: - Drawing

    private static func banner(_ phase: MeetingNotesFlow.Phase, pausedSince: Date? = nil,
                               endedBySleep: Bool = false,
                               record: MeetingRecord? = nil, notes: MeetingNotes? = nil,
                               event: MeetingEvent? = nil, transcriptShown: Bool = false,
                               allowanceUntil: Date? = nil, asksOnline: Bool = false,
                               hearing: [CallLive.Hearing] = []) -> some View {
        let flow = MeetingNotesFlow(previewing: phase, pausedSince: pausedSince, endedBySleep: endedBySleep)
        let model = MeetingNotesModel(previewing: flow, record: record, notes: notes, event: event,
                                      allowanceUntil: allowanceUntil, asksOnline: asksOnline,
                                      hearing: hearing)
        return MeetingNotesBanner(meetings: model, transcriptShown: transcriptShown)
    }

    // MARK: - Made-up calls

    /// A Google Meet tab in Chrome, `since` seconds in.
    private static func meet(since seconds: TimeInterval = 0) -> OngoingCall {
        OngoingCall(bundleID: "com.google.Chrome", appName: "Google Chrome",
                    startedAt: Date().addingTimeInterval(-seconds), site: .googleMeet)
    }

    /// A FaceTime call, `since` seconds in.
    private static func faceTime(since seconds: TimeInterval) -> OngoingCall {
        OngoingCall(bundleID: "com.apple.FaceTime", appName: "FaceTime",
                    startedAt: Date().addingTimeInterval(-seconds))
    }

    /// Notes taken by hand of a meeting in the room, `since` seconds in.
    private static func room(since seconds: TimeInterval) -> OngoingCall {
        .inPerson(at: Date().addingTimeInterval(-seconds))
    }

    private static var weekly: MeetingEvent {
        MeetingEvent(title: "Weekly product sync", start: Date(), attendees: ["Ana", "Marc", "Lucía"])
    }

    /// One other person on the invite, so "Them" reads as her name.
    private static var withAna: MeetingEvent {
        MeetingEvent(title: "", start: Date(), attendees: ["Ana"])
    }

    private static func record(of call: OngoingCall, event: MeetingEvent?, said: [MeetingSegment],
                               jots: [String] = []) -> MeetingRecord {
        var record = MeetingRecord(bundleID: call.bundleID, appName: call.appName, site: call.site,
                                   startedAt: call.startedAt, languages: ["en-GB"], event: event)
        said.forEach { record.add($0) }
        for (index, text) in jots.enumerated() {
            record.jot(text, at: 120 + Double(index) * 90)
        }
        return record
    }

    /// A call with Jordi in Spanish that he moved into Catalan at 10:12,
    /// while the person kept answering in Spanish: the panel's divider sits
    /// between the two, and the Spanish listening of his lines is kept for
    /// the notes (`MeetingRecord.switchLanguage`).
    private static func intoCatalan(_ call: OngoingCall) -> MeetingRecord {
        var record = MeetingRecord(bundleID: call.bundleID, appName: call.appName, startedAt: call.startedAt,
                                   languages: ["es_ES"],
                                   event: MeetingEvent(title: "", start: Date(), attendees: ["Jordi"]))
        record.listen(.me, from: 0, in: "es_ES")
        record.listen(.them, from: 0, in: "es_ES")
        [
            MeetingSegment(speaker: .me, start: 590, end: 596, text: "Vale, pues lo cerramos esta semana."),
            MeetingSegment(speaker: .them, start: 597, end: 606,
                           text: "Perfecto. Les llamo mañana por la mañana y te digo algo."),
            MeetingSegment(speaker: .them, start: 612, end: 622,
                           text: "Por cierto, la Marta me ha dicho que el jueves no puede."),
        ].forEach { record.add($0) }
        record.switchLanguage(of: .them, at: 612, to: "ca_ES", lines: [
            MeetingSegment(speaker: .them, start: 612, end: 622,
                           text: "Per cert, la Marta m'ha dit que el dijous no hi pot ser. Ho movem al divendres?"),
        ], keptAs: "es_ES")
        record.add(MeetingSegment(speaker: .me, start: 624, end: 630,
                                  text: "Sí, el viernes me va bien. Avísala tú."))
        return record
    }

    private static let opening: [MeetingSegment] = [
        MeetingSegment(speaker: .them, start: 3, end: 8, text: "Hi all, can everyone hear me?"),
        MeetingSegment(speaker: .me, start: 9, end: 12, text: "Loud and clear."),
    ]

    private static let launchTalk: [MeetingSegment] = [
        MeetingSegment(speaker: .them, start: 300, end: 309,
                       text: "So the twentieth still holds if the pricing page is done by Friday."),
        MeetingSegment(speaker: .me, start: 310, end: 315,
                       text: "Ana, can you have the copy by Thursday?"),
        MeetingSegment(speaker: .them, start: 316, end: 324,
                       text: "Yes, the copy is fine. The pictures are the slow part, they need another round."),
        MeetingSegment(speaker: .me, start: 325, end: 331,
                       text: "Then let's keep the old pictures and swap them after launch."),
        MeetingSegment(speaker: .them, start: 332, end: 336, text: "Fine by me. I'll tell the others."),
    ]

    /// The room's first words, before the voice model has numbered anyone.
    private static let roomOpening: [MeetingSegment] = [
        MeetingSegment(speaker: .them, start: 6, end: 11, text: "Shall we start? Everyone's here."),
        MeetingSegment(speaker: .them, start: 14, end: 22,
                       text: "Yes. First thing is the shop opening hours for December."),
    ]

    /// Three voices in the room, numbered in the order they first spoke.
    private static let roomTalk: [MeetingSegment] = [
        MeetingSegment(speaker: .them, start: 1_150, end: 1_158,
                       text: "So we open on Sundays from the first of December.", person: 1),
        MeetingSegment(speaker: .them, start: 1_160, end: 1_167,
                       text: "Then we need one more person on the weekend rota.", person: 2),
        MeetingSegment(speaker: .them, start: 1_169, end: 1_176,
                       text: "I can ask Laura. She asked for more hours last month.", person: 3),
        MeetingSegment(speaker: .them, start: 1_178, end: 1_183,
                       text: "Good. Let's have the rota done by Friday.", person: 1),
    ]

    private static var roomNotes: MeetingNotes {
        MeetingNotes(
            summary: "The shop opens on Sundays from the first of December. One more person is needed on the weekend rota, and Laura may take the extra hours.",
            todos: [
                .init(text: "Ask Laura about the weekend hours", owner: "Person 3", sources: [3], at: 1_169),
                .init(text: "Finish the December rota by Friday", owner: "Person 1", sources: [4], at: 1_178),
            ],
            decisions: [.init(text: "Open on Sundays from the first of December.", sources: [1], at: 1_150)])
    }

    private static var weeklyNotes: MeetingNotes {
        MeetingNotes(
            summary: "The launch stays on the twentieth, as long as the pricing page is finished by Friday. Ana has the copy by Thursday; the new pictures wait until after launch. Marc raised the support inbox, which nobody owns yet.",
            todos: [
                .init(text: "Pricing page copy by Thursday", owner: "Ana", sources: [3], at: 316),
                .init(text: "Tell the others the launch date holds", owner: "Marc", sources: [5], at: 332),
                .init(text: "Swap in the new pictures after launch", sources: [4], at: 325),
                .init(text: "Find an owner for the support inbox", owner: "Lucía", sources: [6], at: 400),
                .init(text: "Book the launch retro", sources: [7], at: 520),
            ],
            decisions: [.init(text: "Launch stays on the twentieth.", sources: [1], at: 300)])
    }
}
