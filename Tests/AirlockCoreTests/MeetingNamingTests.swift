import XCTest
@testable import AirlockCore

/// Names given to voices once a meeting is over: what the record calls each
/// voice from then on, who the header shows and in which colour, what the
/// notes say, what is suggested, and what is kept on disk.
final class MeetingNamingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private func room(_ lines: [(Int?, String)] = [(1, "Morning, everyone, shall we start?"),
                                                    (2, "Hola, soy Laura y llevo el almacén desde marzo."),
                                                    (3, "I can send the figures by Friday."),
                                                    (1, "Great, thanks.")],
                      languages: [String] = []) -> MeetingRecord {
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person",
                                   startedAt: start, endedAt: start.addingTimeInterval(900), languages: languages)
        for (index, line) in lines.enumerated() {
            let at = TimeInterval(index * 20)
            record.add(MeetingSegment(speaker: .them, start: at, end: at + 5, text: line.1, person: line.0))
        }
        return record
    }

    private func call(invited: [String]? = nil, voices: [Int?] = [nil]) -> MeetingRecord {
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(600),
                                   event: invited.map { MeetingEvent(title: "Sync", start: start, attendees: $0) })
        record.add(MeetingSegment(speaker: .me, start: 0, end: 2, text: "Hi there."))
        for (index, person) in voices.enumerated() {
            let at = TimeInterval(10 + index * 10)
            record.add(MeetingSegment(speaker: .them, start: at, end: at + 4,
                                      text: "Line number \(index) from the other side.", person: person))
        }
        return record
    }

    // MARK: - Labels

    func testANamedVoiceIsCalledByItsNameButTheNotesWriterStillReadsItsNumber() {
        var record = room()
        let line = record.segments[1]
        XCTAssertEqual(record.label(for: line), "Person 2")

        record.name(2, as: "  Laura ")
        XCTAssertEqual(record.label(for: line), "Laura")
        XCTAssertEqual(record.voiceLabel(for: line), "Person 2")
        XCTAssertTrue(NumberedTranscript(record).turns.contains { $0.label == "Person 2" })
        XCTAssertFalse(NumberedTranscript(record).turns.contains { $0.label == "Laura" })
        XCTAssertTrue(MeetingFiles.transcript(of: record).contains("**Laura**"))
    }

    func testABlankNameTakesItAwayAndANewNameReplacesTheOld() {
        var record = room()
        record.name(2, as: "Laura")
        record.name(2, as: "Laura Puig")
        XCTAssertEqual(record.names, [MeetingVoiceName(voice: 2, name: "Laura Puig")])
        record.name(2, as: "   ")
        XCTAssertEqual(record.names, [])
        XCTAssertEqual(record.label(for: record.segments[1]), "Person 2")

        record.name(1, as: "Marc")
        record.replaceNames(with: [MeetingVoiceName(voice: 3, name: "Núria")])
        XCTAssertEqual(record.names, [MeetingVoiceName(voice: 3, name: "Núria")])
    }

    /// "That's me" only means something in the room: on a call your side
    /// is your own microphone.
    func testThatsMeIsYouInTheRoomOnly() {
        var record = room()
        record.name(1, as: nil, isYou: true)
        XCTAssertEqual(record.label(for: record.segments[0]), "You")
        XCTAssertEqual(record.givenName(of: 1)?.isYou, true)

        var other = call(voices: [1, 2])
        other.name(1, as: nil, isYou: true)
        XCTAssertEqual(other.names, [])
    }

    /// A call heard as one voice: the other side is named as a whole, and
    /// the name wins over the calendar's.
    func testTheOtherSideOfACallHeardAsOneVoiceCanBeNamed() {
        var record = call()
        let them = record.segments[1]
        XCTAssertEqual(record.voices, [MeetingRecord.otherSide])
        XCTAssertEqual(record.label(for: them), "Them")
        record.name(MeetingRecord.otherSide, as: "Marc")
        XCTAssertEqual(record.label(for: them), "Marc")
        XCTAssertEqual(record.label(for: .them), "Marc")

        var oneToOne = call(invited: ["Ana García"], voices: [1, 2])
        XCTAssertEqual(oneToOne.voices, [MeetingRecord.otherSide])
        oneToOne.name(MeetingRecord.otherSide, as: "Ana")
        XCTAssertEqual(oneToOne.label(for: oneToOne.segments[1]), "Ana")
    }

    /// A note taken alone: one voice was heard, so none was numbered and
    /// every line is "Someone". The room is then one voice, named as a
    /// whole or "That's me", like the other side of a call heard as one.
    func testARoomThatWasOneVoiceCanBeNamedOrBeYou() {
        var record = room([(nil, "Okay, so this is me trying the notch on my own."),
                           (nil, "I'll send the figures on Friday.")])
        XCTAssertTrue(record.isOneVoiceRoom)
        XCTAssertEqual(record.voices, [MeetingRecord.otherSide])
        XCTAssertEqual(record.label(for: record.segments[0]), MeetingRecord.someone)
        XCTAssertEqual(CallPeople.people(of: record).map(\.name), [])

        record.name(MeetingRecord.otherSide, as: nil, isYou: true)
        XCTAssertEqual(record.label(for: record.segments[1]), "You")
        XCTAssertEqual(record.label(for: .them), "You")
        XCTAssertEqual(record.voiceLabel(for: record.segments[1]), MeetingRecord.someone)
        XCTAssertEqual(CallPeople.people(of: record).map(\.name), ["You"])
        XCTAssertEqual(CallPeople.people(of: record).map(\.isYou), [true])
        XCTAssertTrue(MeetingFiles.transcript(of: record).contains("**You**"))
        let page = "- [ ] Send the figures — Someone · 0:20\nSomeone should book a room."
        XCTAssertEqual(MeetingNaming.apply(record, to: page),
                       "- [ ] Send the figures — You · 0:20\nSomeone should book a room.")

        record.name(MeetingRecord.otherSide, as: "Guille")
        XCTAssertEqual(record.label(for: record.segments[0]), "Guille")
        XCTAssertEqual(CallPeople.people(of: record).map(\.name), ["Guille"])
        XCTAssertEqual(MeetingNaming.apply(record, to: page),
                       "- [ ] Send the figures — Guille · 0:20\nSomeone should book a room.")

        // Voices told apart: a line none was given to is still anyone in
        // the room, and cannot be named.
        let apart = room([(nil, "Shall we start?"), (1, "Morning, everyone."), (2, "Hola, soy Laura.")])
        XCTAssertFalse(apart.isOneVoiceRoom)
        XCTAssertEqual(apart.voices, [1, 2])
        XCTAssertNil(apart.voice(of: apart.segments[0]))
        XCTAssertEqual(apart.label(for: apart.segments[0]), MeetingRecord.someone)
    }

    /// Calls kept before names existed still open, and names survive a save.
    func testNamesAreKeptAndOldRecordsStillOpen() throws {
        var record = room()
        record.name(2, as: "Laura")
        record.name(1, as: nil, isYou: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(record)
        XCTAssertEqual(try decoder.decode(MeetingRecord.self, from: data), record)

        var plain = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        plain.removeValue(forKey: "names")
        let old = try decoder.decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: plain))
        XCTAssertEqual(old.names, [])
        XCTAssertEqual(old.segments, record.segments)
    }

    // MARK: - Who was there

    func testNamesShowInTheHeaderAndKeepTheirVoicesColour() {
        var record = room()
        let before = CallPeople.people(of: record)
        let seatOfThree = CallPeople.seat(of: "Person 3", in: before)

        record.name(3, as: "Marc")
        let after = CallPeople.people(of: record)
        XCTAssertEqual(after.map(\.name), ["Person 1", "Person 2", "Marc"])
        XCTAssertEqual(CallPeople.seat(of: "Marc", in: after), seatOfThree)
        XCTAssertEqual(CallPeople.seat(of: "marc", in: after), seatOfThree)
        // The notes may still say the number somewhere: same colour.
        XCTAssertEqual(CallPeople.seat(of: "Person 3", in: after), seatOfThree)
    }

    /// Two voices given one name are one person, in the first one's colour;
    /// "That's me" puts you first, as on a call.
    func testVoicesGivenOneNameAreOnePersonAndYouComeFirst() {
        var record = room()
        record.name(1, as: "Laura")
        record.name(3, as: "laura")
        record.name(2, as: nil, isYou: true)
        let people = CallPeople.people(of: record)
        XCTAssertEqual(people.map(\.name), ["You", "Laura"])
        XCTAssertEqual(people.map(\.isYou), [true, false])
        XCTAssertEqual(CallPeople.seat(of: "Laura", in: people), .other(0))
        XCTAssertEqual(CallPeople.seat(of: "You", in: people), .you)
        XCTAssertEqual(CallPeople.line(people), "You and Laura")
    }

    func testANamedOtherSideIsWhoTheCallWasWith() {
        var record = call()
        record.name(MeetingRecord.otherSide, as: "Marc")
        XCTAssertEqual(CallPeople.people(of: record).map(\.name), ["You", "Marc"])
    }

    // MARK: - The notes

    private let page = """
    # Notes: meeting in person

    ## Summary

    Person 2 runs the warehouse. Persona 3 will send figures, and Person 1 agreed with person 2.

    ## To-dos

    - [ ] Send the figures — Person 3 · 0:40
    - [ ] Check stock with Person 12 — Person 2 · 1:00
    - [ ] Call the supplier — Them · 2:00
    - [ ] Book a room for them — Ana García · 3:00

    """

    func testNamesArePutIntoTheNotes() {
        var record = room()
        record.name(2, as: "Laura")
        record.name(3, as: "Marc")
        let named = MeetingNaming.apply(record, to: page)
        XCTAssertTrue(named.contains("Laura runs the warehouse. Marc will send figures, and Person 1 agreed with Laura."))
        XCTAssertTrue(named.contains("- [ ] Send the figures — Marc · 0:40"))
        XCTAssertTrue(named.contains("- [ ] Check stock with Person 12 — Laura · 1:00"))
        XCTAssertEqual(MeetingNaming.apply(room(), to: page), page)
    }

    func testThatsMeIsYouAtTheStartOfASentenceAndYouInside() {
        var record = room()
        record.name(2, as: nil, isYou: true)
        let named = MeetingNaming.apply(record, to: page)
        XCTAssertTrue(named.contains("You runs the warehouse."))
        XCTAssertTrue(named.contains("Person 1 agreed with you."))
        XCTAssertTrue(named.contains("— You · 1:00"))
    }

    /// Notes written in Spanish about an in-person meeting.
    private let spanishRoom = """
    # Notes: reunión en persona

    ## Summary

    Santi y Persona 2 coordinarán la mudanza del almacén antes de fin de mes. Persona 2 lleva el \
    inventario desde marzo. Persona 1 habló con Persona 2 de los precios del transporte y lo dejó \
    todo para Persona 2, así que la decisión depende de Persona 2.

    ## To-dos

    - [ ] Enviar las cifras del inventario — Persona 2 · 0:40
    - [ ] Llamar al proveedor de cajas — Persona 1, Persona 2 · 1:00

    """

    /// What the owner saw: "Santi y you coordinarán". In notes in another
    /// language "That's me" is that language's word, in the form the words
    /// before it ask for, and a to-do's owner is still "You", as the notes
    /// write it.
    func testThatsMeInNotesInAnotherLanguageIsThatLanguagesWord() {
        var record = room([(1, "Buenos días a todos, ¿empezamos ya con la mudanza del almacén?"),
                           (2, "Sí, yo llevo el inventario desde marzo y lo tengo casi todo contado."),
                           (1, "Perfecto, gracias.")], languages: ["es_ES"])
        record.name(2, as: nil, isYou: true)
        XCTAssertEqual(MeetingNaming.apply(record, to: spanishRoom), """
            # Notes: reunión en persona

            ## Summary

            Santi y tú coordinarán la mudanza del almacén antes de fin de mes. Tú lleva el \
            inventario desde marzo. Persona 1 habló contigo de los precios del transporte y lo dejó \
            todo para ti, así que la decisión depende de ti.

            ## To-dos

            - [ ] Enviar las cifras del inventario — You · 0:40
            - [ ] Llamar al proveedor de cajas — Persona 1, You · 1:00

            """)
    }

    /// The notes' language is read from the page itself: English notes keep
    /// "you" whatever the call was heard in, and a page too short to say is
    /// in the language the call was heard in.
    func testTheWordForYouFollowsTheLanguageOfTheNotes() {
        var spanishCall = room(languages: ["es_ES"])
        spanishCall.name(2, as: nil, isYou: true)
        let english = """
            ## Summary

            Person 2 runs the warehouse and has counted most of the stock since March. Person 1 talked \
            prices with Person 2 and left the decision about the boxes to Person 2, who will call the \
            supplier this week. Everyone agreed to meet again on Friday to look at the moving plan.
            """
        let named = MeetingNaming.apply(spanishCall, to: english)
        XCTAssertTrue(named.contains("You runs the warehouse"))
        XCTAssertTrue(named.contains("talked prices with you and left the decision about the boxes to you, who"))
        XCTAssertEqual(MeetingNaming.apply(spanishCall, to: "Habló con Persona 2."), "Habló contigo.")

        var german = room(languages: ["de_DE"])
        german.name(2, as: nil, isYou: true)
        XCTAssertEqual(MeetingNaming.apply(german, to: "Anna und Person 2 sprechen mit Person 2 über Person 2."),
                       "Anna und du sprechen mit dir über dich.")

        var french = room(languages: ["fr_FR"])
        french.name(2, as: nil, isYou: true)
        XCTAssertEqual(MeetingNaming.apply(french, to: "Person 2 parle avec Person 2."), "Tu parle avec toi.")

        var unlisted = room(languages: ["nl_NL"])
        unlisted.name(2, as: nil, isYou: true)
        XCTAssertEqual(MeetingNaming.apply(unlisted, to: "Anna en Person 2 bellen."), "Anna en You bellen.",
                       "a language without its word gets the label, never \"you\" mid-sentence")
    }

    /// "them" is a word as well as a label: the label, with its capital,
    /// and the calendar's name are replaced, the word is not.
    func testTheOtherSidesNameReplacesItsLabelAndTheCalendarsNameButNotTheWord() {
        var record = call()
        record.name(MeetingRecord.otherSide, as: "Marc")
        let named = MeetingNaming.apply(record, to: page)
        XCTAssertTrue(named.contains("- [ ] Call the supplier — Marc · 2:00"))
        XCTAssertTrue(named.contains("Book a room for them — Ana García"))

        var oneToOne = call(invited: ["Ana García"])
        oneToOne.name(MeetingRecord.otherSide, as: "Ana")
        XCTAssertTrue(MeetingNaming.apply(oneToOne, to: page).contains("Book a room for them — Ana · 3:00"))
    }

    /// Notes from a call whose other side was "Them": written before the
    /// model was told it is a label ("Them finalizará"), and after, with
    /// the words it was given ("la otra persona").
    private let spanish = """
    # Notes: contrato

    ## Summary

    La otra persona finalizará la ingeniería inversa esta semana y le avisarás tras el push. \
    Them reorganiza el backend con su equipo.

    ## To-dos

    - [ ] Enviar el cuestionario a tu padre — You · 43:26
    - [ ] Avisar a la otra persona tras el push — You · 1:12:40
    - [ ] Revisar el esquema con Them · 34:22

    ## Key points

    - Book a room for them and the other person's team · 40:00
    - Parlar amb l’altra persona del pressupost · 5:00
    - Themes for the launch: another person joins later, otra persona del equipo y los demás · 2:04

    """

    /// What the owner saw: a voice named after the notes were saved, and
    /// the notes still saying "Them". Named, the label and the words the
    /// notes were told to use become the name; "you", "them" the word, "the
    /// others" and anything that only contains the words stay as written.
    func testTheOtherSidesNameReplacesThemAndTheOtherPersonInTheNotes() {
        var record = call()
        record.name(MeetingRecord.otherSide, as: "Alex")
        XCTAssertEqual(MeetingNaming.apply(record, to: spanish), """
            # Notes: contrato

            ## Summary

            Alex finalizará la ingeniería inversa esta semana y le avisarás tras el push. \
            Alex reorganiza el backend con su equipo.

            ## To-dos

            - [ ] Enviar el cuestionario a tu padre — You · 43:26
            - [ ] Avisar a Alex tras el push — You · 1:12:40
            - [ ] Revisar el esquema con Alex · 34:22

            ## Key points

            - Book a room for them and Alex's team · 40:00
            - Parlar amb Alex del pressupost · 5:00
            - Themes for the launch: another person joins later, otra persona del equipo y los demás · 2:04

            """)
        XCTAssertEqual(MeetingNaming.apply(call(), to: spanish), spanish, "nothing named, nothing changed")
    }

    /// The words are the other side's only where the notes were told so:
    /// not where the calendar named it, nor where the invite had several
    /// people, who were "los demás". The label is still its name there.
    func testTheOtherPersonIsANameOnlyWhereTheNotesWereToldSo() {
        var oneToOne = call(invited: ["Marta Vidal"])
        oneToOne.name(MeetingRecord.otherSide, as: "Marta")
        let toMarta = MeetingNaming.apply(oneToOne, to: spanish)
        XCTAssertTrue(toMarta.contains("La otra persona finalizará"))
        XCTAssertTrue(toMarta.contains("Marta reorganiza el backend"))

        var group = call(invited: ["Ana García", "Luis Pérez"])
        group.name(MeetingRecord.otherSide, as: "Ana")
        let toAna = MeetingNaming.apply(group, to: spanish)
        XCTAssertTrue(toAna.contains("La otra persona finalizará"))
        XCTAssertTrue(toAna.contains("- [ ] Revisar el esquema con Ana · 34:22"))

        // Voices told apart, and a stretch that stayed "Them".
        var apart = call(voices: [1, 2, nil])
        apart.name(MeetingRecord.otherSide, as: "Pau")
        let toPau = MeetingNaming.apply(apart, to: spanish)
        XCTAssertTrue(toPau.contains("La otra persona finalizará"))
        XCTAssertTrue(toPau.contains("Pau reorganiza el backend"))
    }

    // MARK: - Suggestions

    func testWhatSomebodyCallsThemselvesIsSuggested() {
        XCTAssertEqual(MeetingNaming.introduction(in: "Hola, soy Laura y llevo el almacén."), "Laura")
        XCTAssertEqual(MeetingNaming.introduction(in: "Hi, my name is Ana García, I run sales."), "Ana García")
        XCTAssertEqual(MeetingNaming.introduction(in: "Bon dia, sóc la Marta."), "Marta")
        XCTAssertEqual(MeetingNaming.introduction(in: "Me llamo Pau."), "Pau")
        XCTAssertEqual(MeetingNaming.introduction(in: "Yes, I'm Tom."), "Tom")
        XCTAssertEqual(MeetingNaming.introductionMatch(in: "Hi, my name is Ana García, I run sales.")?.heard,
                       "my name is Ana García")
        XCTAssertNil(MeetingNaming.introduction(in: "I'm Spanish, so bear with me."))
        XCTAssertNil(MeetingNaming.introduction(in: "Soy de Madrid."))
        XCTAssertNil(MeetingNaming.introduction(in: "I'm sorry, go on."))
        XCTAssertNil(MeetingNaming.introduction(in: "Sorry, I'm Going to check."))
    }

    func testEachVoiceIsSketchedWithHowOftenItSpokeAndALineToKnowItBy() {
        let sketches = MeetingNaming.sketches(of: room())
        XCTAssertEqual(sketches.map(\.voice), [1, 2, 3])
        XCTAssertEqual(sketches.map(\.label), ["Person 1", "Person 2", "Person 3"])
        XCTAssertEqual(sketches.map(\.turns), [2, 1, 1])
        XCTAssertEqual(sketches[1].quote?.text, "Hola, soy Laura y llevo el almacén desde marzo.")
        XCTAssertEqual(sketches[1].quote?.at, 20)
        XCTAssertEqual(sketches[1].suggestions.map(\.name), ["Laura"])
        XCTAssertEqual(sketches[1].suggestions.first?.heard, "soy Laura")
        XCTAssertEqual(sketches[0].suggestions.map(\.name), [])
    }

    /// A name already given to another voice is not offered again; on a
    /// call the invite's names are offered too.
    func testSuggestionsLeaveOutNamesAlreadyGiven() {
        var record = room()
        record.name(3, as: "Laura")
        XCTAssertEqual(MeetingNaming.sketches(of: record)[1].suggestions.map(\.name), [])

        var meeting = call(invited: ["Ana García", "Tom Ruiz"], voices: [1, 2])
        meeting.name(1, as: "Tom Ruiz")
        let sketches = MeetingNaming.sketches(of: meeting)
        XCTAssertEqual(sketches.map(\.voice), [1, 2])
        XCTAssertEqual(sketches[0].suggestions.map(\.name), ["Ana García", "Tom Ruiz"])
        XCTAssertNil(sketches[0].suggestions[0].heard)
        XCTAssertEqual(sketches[1].suggestions.map(\.name), ["Ana García"])
    }

    func testALongLineIsCutAtAWord() {
        let long = Array(repeating: "warehouse", count: 30).joined(separator: " ")
        let cut = MeetingNaming.excerpt(long)
        XCTAssertTrue(cut.hasSuffix("warehouse…"))
        XCTAssertLessThanOrEqual(cut.count, 141)
    }

    // MARK: - On disk

    func testNamingRewritesTheNotesFromThePageAsWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-naming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var record = room()
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        try store.saveNotes(page, in: folder)
        XCTAssertEqual(store.notesPage(in: folder), page)

        record.name(2, as: "Laura")
        try store.saveNames(of: record, in: folder)
        XCTAssertEqual(store.loadRecord(in: folder)?.names, record.names)
        XCTAssertTrue(store.notesPage(in: folder)?.contains("Laura runs the warehouse") == true)
        let transcript = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcriptName),
                                    encoding: .utf8)
        XCTAssertTrue(transcript.contains("**Laura**"))

        // Named again: from the page as written, not from "Laura".
        record.name(2, as: "Laura Puig")
        try store.saveNames(of: record, in: folder)
        XCTAssertTrue(store.notesPage(in: folder)?.contains("Laura Puig runs the warehouse") == true)
        XCTAssertFalse(store.notesPage(in: folder)?.contains("Laura Puig Puig") == true)
        record.name(2, as: "")
        try store.saveNames(of: record, in: folder)
        XCTAssertEqual(store.notesPage(in: folder), page)

        // Notes written later (a summary finishing after the naming) get
        // the names the folder has.
        record.name(3, as: "Marc")
        try store.saveNames(of: record, in: folder)
        try store.saveNotes(page, in: folder)
        XCTAssertTrue(store.notesPage(in: folder)?.contains("— Marc · 0:40") == true)

        // The page as written is hidden: the folder is still one call.
        XCTAssertEqual(store.calls().count, 1)
        XCTAssertTrue(store.unfinishedFolders().isEmpty)
    }

    /// The other side named after the notes were saved, then named again,
    /// then not: the notes follow each time, the page as written never
    /// changes.
    func testNamingTheOtherSideRewritesTheNotesAndKeepsThePageAsWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-naming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var record = call()
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        try store.saveNotes(spanish, in: folder)
        let kept = folder.appendingPathComponent(MeetingStore.notesAsWrittenName)

        record.name(MeetingRecord.otherSide, as: "Nico")
        try store.saveNames(of: record, in: folder)
        let named = try XCTUnwrap(store.notesPage(in: folder))
        XCTAssertTrue(named.contains("Nico finalizará la ingeniería inversa"))
        XCTAssertTrue(named.contains("- [ ] Avisar a Nico tras el push — You · 1:12:40"))
        XCTAssertTrue(named.contains("Nico reorganiza el backend"))
        XCTAssertFalse(named.contains("Them "))
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcriptName),
                                 encoding: .utf8).contains("**Nico**"))
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), spanish)

        record.name(MeetingRecord.otherSide, as: "Nico Ruiz")
        try store.saveNames(of: record, in: folder)
        XCTAssertTrue(store.notesPage(in: folder)?.contains("Nico Ruiz finalizará") == true)
        XCTAssertFalse(store.notesPage(in: folder)?.contains("Ruiz Ruiz") == true)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), spanish)

        record.name(MeetingRecord.otherSide, as: "")
        try store.saveNames(of: record, in: folder)
        XCTAssertEqual(store.notesPage(in: folder), spanish)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), spanish)
    }

    /// Notes written before names existed are the page as written already.
    func testNotesFromBeforeNamesAreKeptAsWrittenTheFirstTime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-naming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var record = room()
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        try Data(page.utf8).write(to: folder.appendingPathComponent(MeetingFiles.notesName))

        record.name(3, as: "Marc")
        try store.saveNames(of: record, in: folder)
        let kept = folder.appendingPathComponent(MeetingStore.notesAsWrittenName)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), page)
        XCTAssertTrue(store.notesPage(in: folder)?.contains("— Marc · 0:40") == true)
    }
}
