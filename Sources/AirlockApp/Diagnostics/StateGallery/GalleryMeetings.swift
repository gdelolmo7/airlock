import SwiftUI
import AirlockCore

/// The call notes window (K), drawn from made-up calls. The page is written
/// by `MeetingFiles.notesPage`, so its layout is the one a real call gets.
///
/// Then the compact island through a call with notes, from the ask to "Notes
/// ready", through `GalleryIsland.compact`: Core resolves both halves, so a
/// row cannot show a slot the ladder would never pick.
@MainActor
enum GalleryMeetings {
    static let area = "Call notes"

    static var states: [GalleryState] {
        [
            GalleryState("K1", area, "Window: a call's notes", ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: calls, tab: .notes))
            },
            GalleryState("K2", area, "Window: the transcript", ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: calls, tab: .transcript))
            },
            GalleryState("K3", area, "Window: notes still being written", ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [unsummarised] + calls, tab: .notes))
            },
            GalleryState("K4", area, "Window: no calls yet", ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [], tab: .notes))
            },
            // The light is drawn at full strength and left there: the gallery
            // runs no tasks, so neither the fade nor the scroll happens.
            GalleryState("K20", area, "Window: tapped a line, the transcript shows where it was said",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: calls, tab: .transcript, spotlightAt: 23))
            },
            GalleryState("K21", area, "Window: one-to-one call, names instead of Them",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [checkIn] + calls, tab: .transcript))
            },
            GalleryState("K28", area, "Window: notes with minutes the model couldn't write",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [overrun] + calls, tab: .notes))
            },
            GalleryState("K31", area, "Window: notes written from a Spanish listening of a Catalan stretch",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [intoCatalan] + calls, tab: .notes))
            },
            // The to-do was written from the Spanish listening and opens the
            // Catalan line said at the same moment.
            GalleryState("K32", area, "Window: \"Catalan from 10:12\", a to-do from the Spanish listening tapped",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [intoCatalan] + calls, tab: .transcript, spotlightAt: 624))
            },
            // The search reads names, notes and what was said; the list keeps
            // only what matches, and the first match is shown.
            GalleryState("K39", area, "Window: searching \"budget\"", ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [intoCatalan] + calls, tab: .notes, search: "budget"))
            },
            GalleryState("K40", area, "Window: a search that finds nothing", ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [intoCatalan] + calls, tab: .notes, search: "giraffe"))
            },
            GalleryState("K41", area, "Window: notes being taken, \"Stop notes\" at the foot of the list",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: calls, tab: .notes, hand: .stop))
            },
            // A meeting in the room: three voices told apart, nobody named,
            // so nobody is "You" yet.
            GalleryState("K42", area, "Window: a meeting in the room, \"Name people\" beside the tabs",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [room()] + calls, tab: .notes))
            },
            GalleryState("K43", area, "Window: \"Who's who\", one voice heard saying its name",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [room()] + calls, tab: .notes, naming: true))
            },
            GalleryState("K44", area, "Window: \"Who's who\" opened again, \"That's me\" and Marc already given",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [room(named: [MeetingVoiceName(voice: 1, name: "", isYou: true),
                                                                  MeetingVoiceName(voice: 2, name: "Marc")])] + calls,
                                        tab: .notes, naming: true))
            },
            GalleryState("K45", area, "Window: the notes once everyone is named", ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [room(named: everyone)] + calls, tab: .notes))
            },
            GalleryState("K46", area, "Window: the transcript once everyone is named",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [room(named: everyone)] + calls, tab: .transcript))
            },
            // The box itself: on screen it hangs off the name that was
            // clicked, in a popover the gallery cannot draw.
            GalleryState("K47", area, "Box: \"Who is Person 3?\" from a name in the transcript",
                         ground: .window, width: 280) {
                let call = room(named: Array(everyone.prefix(2)))
                CallNotesRename(call: call, voice: 3)
                    .environment(CallNotesLibrary(previewing: [call], tab: .transcript))
                    .background(Color(white: 0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(20)
            },

            // A note taken alone: one voice heard, so nothing was numbered.
            // The room is one voice that can be named, or be you.
            GalleryState("K70", area, "Window: a note taken alone, \"Who's who\" offers its one voice",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [alone()] + calls, tab: .transcript, naming: true))
            },
            GalleryState("K71", area, "Box: \"Who is Someone?\" from a note taken alone",
                         ground: .window, width: 280) {
                let call = alone()
                CallNotesRename(call: call, voice: MeetingRecord.otherSide)
                    .environment(CallNotesLibrary(previewing: [call], tab: .transcript))
                    .background(Color(white: 0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(20)
            },
            GalleryState("K72", area, "Window: a note taken alone, once \"That's me\" is saved",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [alone(named: [MeetingVoiceName(voice: MeetingRecord.otherSide,
                                                                                    name: "", isYou: true)])] + calls,
                                        tab: .transcript))
            },

            // A recording somebody already has, added to the window: "Add a
            // recording…" is under "Take notes" on every state above.
            GalleryState("K48", area, "Window: a recording held over the window, its name and length",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: calls, tab: .notes,
                                        dropping: .init(fileName: recordingFile, seconds: 40 * 60)))
            },
            GalleryState("K49", area, "Window: a recording being read, a third of the way",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [recording] + calls, tab: .notes,
                                        reading: reading(.listening, heard: 14 * 60)))
            },
            GalleryState("K50", area, "Window: a recording read, the notes being written",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [recording] + calls, tab: .notes,
                                        reading: reading(.notes, heard: 40 * 60)))
            },
            // With room for words the button says it; down to its icon, the
            // word hangs just below. A call still on has no "Name people".
            GalleryState("K61", area, "Window: Copy pressed mid-call, it says \"Copied\" for a moment",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: [ongoing(checkIn)] + calls, tab: .transcript, copied: true))
            },
            GalleryState("K62", area, "Window: Copy pressed beside \"Name people\", \"Copied\" below its icon",
                         ground: .window, width: size.width) {
                window(CallNotesLibrary(previewing: calls, tab: .transcript, copied: true))
            },

            onCall("K5", "Compact: call starts, \"Notes?\" for 10 s") { .ask },
            onCall("K6", "Compact: notes still on offer (grey dot)") { .offer },
            onCall("K7", "Compact: \"Always\" counting down to the notes") {
                .startingSoon(Date().addingTimeInterval(MeetingNotesFlow.countdown))
            },
            onCall("K8", "Compact: taking notes (breathing dot)") { .recording },
            onCall("K9", "Compact: taking notes, muted in the call") { .muted },
            onCall("K10", "Compact: notes paused") { .paused },
            GalleryIsland.compact("K11", "Compact: call over, writing the notes",
                                  CompactIslandInput(now: now, callNotes: .writing, callNotesAt: now),
                                  area: area),
            GalleryIsland.compact("K12", "Compact: notes ready, two to-dos",
                                  CompactIslandInput(now: now, callNotes: .ready(todos: 2),
                                                     callNotesAt: now.addingTimeInterval(-2)),
                                  area: area),
            GalleryIsland.compact("K33", "Compact: call over, too little said for notes",
                                  CompactIslandInput(now: now, callNotes: .tooLittleSaid,
                                                     callNotesAt: now.addingTimeInterval(-2)),
                                  area: area),
            // Notes started by hand with no call: the pill is the same, the
            // icon is the room's.
            GalleryIsland.compact("K38", "Compact: taking notes of a meeting in the room",
                                  CompactIslandInput(now: now, call: .inPerson(at: now.addingTimeInterval(-1_240))),
                                  area: area, notesMark: { .recording }),
        ]
    }

    /// A FaceTime call twelve minutes in, with the notes' `mark` on its pill.
    private static func onCall(_ id: String, _ name: String,
                               mark: @escaping @MainActor () -> MeetingNotesFlow.PillMark) -> GalleryState {
        let call = OngoingCall(bundleID: "com.apple.FaceTime", appName: "FaceTime",
                               startedAt: now.addingTimeInterval(-734))
        return GalleryIsland.compact(id, name, CompactIslandInput(now: now, call: call),
                                     area: area, notesMark: mark)
    }

    static let size = CGSize(width: 780, height: 560)

    private static func window(_ library: CallNotesLibrary) -> some View {
        CallNotesView().environment(library).frame(width: size.width, height: size.height)
    }

    private static let now = Date()

    /// A stand-up on the calendar with two others: the person typed two
    /// notes, marked the moment the pictures were settled, and paused the
    /// notes for a minute in the middle.
    private static var standUp: MeetingRecord {
        let started = Calendar.current.date(bySettingHour: 10, minute: 2, second: 0, of: now) ?? now
        var record = MeetingRecord(
            bundleID: "com.google.Chrome", appName: "Google Chrome", site: .googleMeet,
            startedAt: started, endedAt: started.addingTimeInterval(14 * 60), languages: ["en-GB"],
            segments: [
                MeetingSegment(speaker: .them, start: 4, end: 11,
                               text: "Morning. Shall we start with the launch date, since that's what everyone's asking about?"),
                MeetingSegment(speaker: .me, start: 12, end: 22,
                               text: "Yes. I think the twentieth still works if the pricing page is done by Friday."),
                MeetingSegment(speaker: .them, start: 23, end: 31,
                               text: "Ana said she can have the copy by Thursday. The pictures are the slow part."),
                MeetingSegment(speaker: .me, start: 95, end: 104,
                               text: "Then let's keep the old pictures for now and swap them after launch."),
                MeetingSegment(speaker: .them, start: 108, end: 114,
                               text: "Fine by me. I'll tell the others."),
                MeetingSegment(speaker: .me, start: 196, end: 205,
                               text: "One more thing: I'll check the analytics before the twentieth."),
                MeetingSegment(speaker: .them, start: 207, end: 212,
                               text: "Great, send me what you find."),
            ],
            event: MeetingEvent(title: "Launch stand-up", start: started, attendees: ["Ana García", "Tom Reed"]))
        record.jot("Ana: copy by Thursday", at: 30)
        record.mark(at: 106)
        record.pause(at: 130)
        record.resume(at: 190)
        record.jot("Ask Tom about the press list", at: 215)
        return record
    }

    private static var standUpPage: String {
        MeetingFiles.notesPage(for: standUp, notes: MeetingNotes(
            summary: "A quick check on the launch. The twentieth still holds if the pricing page is finished by Friday; the new pictures can wait until after launch.",
            todos: [.init(text: "Pricing page copy by Thursday", owner: "Ana García", sources: [3], at: 23),
                    .init(text: "Check the analytics before the twentieth", owner: "You", sources: [6], at: 196),
                    .init(text: "Tell the others about the plan", sources: [5], at: 108)],
            decisions: [.init(text: "Launch stays on the twentieth.", sources: [2], at: 12),
                        .init(text: "Keep the old pictures until after launch.", sources: [4], at: 95)],
            keyPoints: [.init(text: "The pictures are the slowest part of the pricing page.", sources: [3], at: 23)]))
    }

    /// A call the calendar says was with one person, whose name is long
    /// enough to need the second line.
    /// `call` as if it had not ended yet.
    private static func ongoing(_ call: CallNotesLibrary.Call) -> CallNotesLibrary.Call {
        var record = call.record
        record.endedAt = nil
        return CallNotesLibrary.Call(folder: call.folder, record: record, page: nil)
    }

    private static var checkIn: CallNotesLibrary.Call {
        let started = now.addingTimeInterval(-2 * 3_600)
        let record = MeetingRecord(
            bundleID: "us.zoom.xos", appName: "Zoom", startedAt: started,
            endedAt: started.addingTimeInterval(22 * 60), languages: ["en-GB"],
            segments: [
                MeetingSegment(speaker: .them, start: 3, end: 9,
                               text: "Hi! Sorry I'm a minute late, the last call ran over."),
                MeetingSegment(speaker: .me, start: 10, end: 16,
                               text: "No problem. How did the interviews go?"),
                MeetingSegment(speaker: .them, start: 17, end: 30,
                               text: "Really well. Two of the five want to try it next week, and one asked about a team plan."),
                MeetingSegment(speaker: .me, start: 32, end: 38,
                               text: "Good. Send me their names and I'll set them up."),
            ],
            event: MeetingEvent(title: "Weekly check-in", start: started, attendees: ["Mariana García-Robles"]))
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/check-in"), record: record, page: nil)
    }

    /// A call in Spanish that moved into Catalan at 10:12: Jordi first, the
    /// person half a minute later. Apple's notes writer cannot read Catalan,
    /// so the notes are written from the Spanish listening kept beside it,
    /// and the page says so; the times in the notes still open the
    /// transcript where each thing was said.
    private static var intoCatalan: CallNotesLibrary.Call {
        let started = now.addingTimeInterval(-3 * 3_600)
        var record = MeetingRecord(
            bundleID: "com.google.Chrome", appName: "Google Chrome", site: .googleMeet,
            startedAt: started, endedAt: started.addingTimeInterval(11 * 60), languages: ["es_ES"],
            event: MeetingEvent(title: "Venue budget", start: started, attendees: ["Jordi Puig"]))
        record.listen(.me, from: 0, in: "es_ES")
        record.listen(.them, from: 0, in: "es_ES")
        [
            MeetingSegment(speaker: .them, start: 5, end: 12,
                           text: "Hola, ¿me oyes bien? Tengo el presupuesto del local delante."),
            MeetingSegment(speaker: .me, start: 13, end: 18, text: "Sí, perfecto. ¿Cuánto piden al final?"),
            MeetingSegment(speaker: .them, start: 20, end: 31,
                           text: "Tres mil doscientos por los dos días, con el montaje incluido. Es más de lo que pensábamos."),
            MeetingSegment(speaker: .me, start: 590, end: 598,
                           text: "Si lo bajan a tres mil, lo cerramos esta semana."),
            MeetingSegment(speaker: .them, start: 599, end: 607,
                           text: "Lo intento. Les llamo mañana por la mañana y te digo algo."),
        ].forEach { record.add($0) }
        // What each side said once it moved, as the Spanish listening heard it.
        let spanish = [
            MeetingSegment(speaker: .them, start: 612, end: 622,
                           text: "Por cierto, la Marta me ha dicho que el jueves no puede. ¿Lo movemos al viernes?"),
            MeetingSegment(speaker: .them, start: 624, end: 631,
                           text: "Yo le envío la invitación hoy mismo si te va bien."),
            MeetingSegment(speaker: .me, start: 640, end: 648,
                           text: "Sí, el viernes me va bien. Envíale la invitación y yo aviso al catering."),
            MeetingSegment(speaker: .them, start: 650, end: 655, text: "Perfecto. Pues hablamos el viernes."),
        ]
        spanish.forEach { record.add($0) }
        record.switchLanguage(of: .them, at: 612, to: "ca_ES", lines: [
            MeetingSegment(speaker: .them, start: 612, end: 622,
                           text: "Per cert, la Marta m'ha dit que el dijous no hi pot ser. Ho movem al divendres?"),
            MeetingSegment(speaker: .them, start: 624, end: 631,
                           text: "Jo li envio la invitació avui mateix, si et va bé."),
            MeetingSegment(speaker: .them, start: 650, end: 655, text: "Perfecte. Doncs parlem divendres."),
        ], keptAs: "es_ES")
        record.switchLanguage(of: .me, at: 640, to: "ca_ES", lines: [
            MeetingSegment(speaker: .me, start: 640, end: 648,
                           text: "Sí, divendres em va bé. Envia-li la invitació i jo aviso el càtering."),
        ], keptAs: "es_ES")

        let source = MeetingNotesSource(record) { !$0.hasPrefix("ca") }
        let page = MeetingFiles.notesPage(for: record, notes: MeetingNotes(
            summary: "Jordi tiene el presupuesto del local: tres mil doscientos euros por los dos días, con el montaje. Si lo bajan a tres mil, se cierra esta semana. Marta no puede el jueves, así que la reunión pasa al viernes.",
            todos: [.init(text: "Llamar al local para bajar a tres mil", owner: "Jordi Puig", sources: [5], at: 599),
                    .init(text: "Enviar a Marta la invitación del viernes", owner: "Jordi Puig", sources: [7], at: 624),
                    .init(text: "Avisar al catering del cambio", owner: "You", sources: [8], at: 640)],
            decisions: [.init(text: "La reunión pasa del jueves al viernes.", sources: [6], at: 612)]),
            writtenFrom: source.line)
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/venue"), record: record, page: page)
    }

    /// You, Marc and Núria, as "Who's who" names them.
    private static let everyone = [MeetingVoiceName(voice: 1, name: "", isYou: true),
                                   MeetingVoiceName(voice: 2, name: "Marc"),
                                   MeetingVoiceName(voice: 3, name: "Núria")]

    /// A shop meeting in the room with three voices. Marc says who he is;
    /// the notes were written with numbers, as they always are, and named
    /// afterwards (`MeetingNaming`).
    private static func room(named names: [MeetingVoiceName] = []) -> CallNotesLibrary.Call {
        let started = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: now) ?? now
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person",
                                   startedAt: started, endedAt: started.addingTimeInterval(35 * 60),
                                   languages: ["en-GB"])
        [
            (1, 9.0, 15.0, "Right, shall we start? There's a lot on the list today."),
            (2, 41, 48, "For those who don't know me, I'm Marc. I do the weekend shifts."),
            (1, 1_150, 1_156, "So we open on Sundays from the first of December."),
            (2, 1_160, 1_166, "Then we need one more person on the weekend rota."),
            (3, 1_169, 1_173, "I can ask Laura. She wants more hours."),
            (1, 1_178, 1_183, "Good. Let's have the rota done by Friday."),
            (3, 1_184, 1_187, "I'll message her tonight."),
        ].forEach { person, start, end, text in
            record.add(MeetingSegment(speaker: .them, start: start, end: end, text: text, person: person))
        }
        let written = MeetingFiles.notesPage(for: record, notes: MeetingNotes(
            summary: "The shop opens on Sundays from the first of December. The weekend rota is one person short; Person 3 will ask Laura, who wanted more hours.",
            todos: [.init(text: "Ask Laura about the weekend hours", owner: "Person 3", sources: [5], at: 1_169),
                    .init(text: "Finish the December rota by Friday", owner: "Person 1", sources: [6], at: 1_178)],
            decisions: [.init(text: "Open on Sundays from the first of December.", sources: [3], at: 1_150)],
            keyPoints: [.init(text: "The weekend rota needs one more person from December.", sources: [4], at: 1_160)]))
        record.replaceNames(with: names)
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/room"), record: record,
                                     page: MeetingNaming.apply(record, to: written))
    }

    /// A note somebody took alone: every line "Someone", nobody numbered.
    private static func alone(named names: [MeetingVoiceName] = []) -> CallNotesLibrary.Call {
        let started = Calendar.current.date(bySettingHour: 12, minute: 38, second: 0, of: now) ?? now
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person",
                                   startedAt: started, endedAt: started.addingTimeInterval(4 * 60),
                                   languages: ["en-GB"])
        [
            (1.0, 9.0, "Right, notes for the shop before I forget."),
            (12, 19, "The Sunday rota still needs one more person from December."),
            (24, 31, "I'll ask Laura tonight if she wants the extra hours."),
            (95, 101, "And the fridge in the back is making that noise again, so call the repair people."),
        ].forEach { start, end, text in
            record.add(MeetingSegment(speaker: .them, start: start, end: end, text: text))
        }
        let written = MeetingFiles.notesPage(for: record, notes: MeetingNotes(
            summary: "Notes for the shop: the Sunday rota is one person short from December, and the fridge needs a repair.",
            todos: [.init(text: "Ask Laura about the extra Sunday hours", owner: MeetingRecord.someone,
                          sources: [3], at: 24),
                    .init(text: "Call the repair people about the fridge", sources: [4], at: 95)],
            decisions: [],
            keyPoints: [.init(text: "The Sunday rota needs one more person from December.", sources: [2], at: 12)]))
        record.replaceNames(with: names)
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/alone"), record: record,
                                     page: MeetingNaming.apply(record, to: written))
    }

    private static var calls: [CallNotesLibrary.Call] {
        let yesterday = now.addingTimeInterval(-86_400)
        let older = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: yesterday,
                                  endedAt: yesterday.addingTimeInterval(38 * 60))
        let facetime = MeetingRecord(bundleID: "com.apple.FaceTime", appName: "FaceTime",
                                     startedAt: now.addingTimeInterval(-4 * 86_400),
                                     endedAt: now.addingTimeInterval(-4 * 86_400 + 9 * 60))
        return [
            CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/standup"), record: standUp, page: standUpPage),
            CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/zoom"), record: older, page: nil),
            CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/facetime"), record: facetime, page: nil),
        ]
    }

    /// A long planning call whose last twelve minutes the model wrote
    /// nothing for: the notes stop there and say so under the summary.
    private static var overrun: CallNotesLibrary.Call {
        var record = standUp
        record.startedAt = now.addingTimeInterval(-3 * 3_600)
        record.endedAt = record.startedAt.addingTimeInterval(45 * 60)
        record.event = MeetingEvent(title: "Quarterly planning", start: record.startedAt,
                                    attendees: ["Ana García", "Tom Reed"])
        record.add(MeetingSegment(speaker: .them, start: 1_930, end: 1_941,
                                  text: "Last thing on the list is hiring for next quarter."))
        record.add(MeetingSegment(speaker: .me, start: 2_630, end: 2_645,
                                  text: "Good, let's stop there. Thanks, everyone."))
        let page = MeetingFiles.notesPage(for: record, notes: MeetingNotes(
            summary: "The launch stays on the twentieth if the pricing page is finished by Friday. The new pictures wait until after launch, and the analytics get a look first.",
            todos: [.init(text: "Pricing page copy by Thursday", owner: "Ana García", sources: [3], at: 23),
                    .init(text: "Check the analytics before the twentieth", owner: "You", sources: [6], at: 196)],
            decisions: [.init(text: "Launch stays on the twentieth.", sources: [2], at: 12),
                        .init(text: "Keep the old pictures until after launch.", sources: [4], at: 95)],
            unwritten: [.init(start: 1_930, end: 2_645)]))
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/planning"), record: record, page: page)
    }

    private static var unsummarised: CallNotesLibrary.Call {
        var record = standUp
        record.startedAt = now.addingTimeInterval(-60)
        record.endedAt = now
        // Its own name, so the list does not read the same meeting twice.
        record.event = MeetingEvent(title: "Design review", start: record.startedAt)
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/just-now"), record: record, page: nil)
    }

    // MARK: - A recording added afterwards

    static let recordingFile = "Shop handover.m4a"

    /// A 40-minute recording made at 12:25 today, being read: saved with no
    /// end and no notes, as `RecordingReader` saves it before listening.
    private static var recording: CallNotesLibrary.Call {
        let started = Calendar.current.date(bySettingHour: 12, minute: 25, second: 0, of: now) ?? now
        let record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person",
                                   startedAt: started, languages: ["en-GB"],
                                   recording: MeetingRecording(fileName: recordingFile, seconds: 40 * 60))
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/recording"), record: record, page: nil)
    }

    /// How far along `recording` is: at `stage`, `heard` seconds in, with
    /// the first lines written down.
    static func reading(_ stage: RecordingImport.Stage, heard: TimeInterval,
                        folder: URL? = URL(fileURLWithPath: "/var/empty/recording")) -> RecordingImporter.Reading {
        RecordingImporter.Reading(
            progress: RecordingImport.Progress(stage: stage, fileName: recordingFile, seconds: 40 * 60, heard: heard),
            folder: folder, startedAt: now,
            lines: [
                MeetingSegment(speaker: .them, start: 6, end: 11,
                               text: "Right, let's start with the till, that's the most urgent."),
                MeetingSegment(speaker: .them, start: 14, end: 19,
                               text: "Fine. And the stock we look at after, that'll take a while."),
            ])
    }
}
