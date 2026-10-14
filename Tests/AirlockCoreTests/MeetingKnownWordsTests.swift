import XCTest
@testable import AirlockCore

/// The recogniser writes a word it does not know as the words it sounds
/// like. These are about joining those back, and about leaving every other
/// line exactly as it was. Every word here is made up.
final class MeetingKnownWordsTests: XCTestCase {
    private let words = MeetingKnownWords(typed: ["Brightwell", "Velaroja"])

    // MARK: - Joining a split word

    func testASplitWordIsJoined() {
        XCTAssertEqual(words.respelled("We moved the data to bright well last week."),
                       "We moved the data to Brightwell last week.")
        XCTAssertEqual(words.respelled("Hay que cambiar el sistema de vela roja por otro."),
                       "Hay que cambiar el sistema de Velaroja por otro.")
    }

    func testEveryTimeInALineIsJoined() {
        XCTAssertEqual(words.respelled("Bright well or bright well, it's the same."),
                       "Brightwell or Brightwell, it's the same.")
    }

    func testPunctuationAroundTheWordStays() {
        XCTAssertEqual(words.respelled("¿Usamos vela roja?"), "¿Usamos Velaroja?")
        XCTAssertEqual(words.respelled("(bright well), then the rest."), "(Brightwell), then the rest.")
    }

    func testAHyphenatedSplitIsJoined() {
        XCTAssertEqual(words.respelled("The Bright-well export failed."), "The Brightwell export failed.")
    }

    func testAWordSplitInThreeIsJoined() {
        let known = MeetingKnownWords(typed: ["Andalumar"])
        XCTAssertEqual(known.respelled("En and a lu mar no."), "En and a lu mar no.",
                       "four pieces is more than it looks across")
        XCTAssertEqual(known.respelled("En anda lu mar no."), "En Andalumar no.")
    }

    func testNothingIsJoinedAcrossPunctuation() {
        XCTAssertEqual(words.respelled("It was bright, well, mostly."), "It was bright, well, mostly.")
        XCTAssertEqual(words.respelled("Vela. Roja."), "Vela. Roja.")
    }

    /// Whole words only: a longer word that starts the same is another word.
    func testOnlyWholeWordsAreJoined() {
        XCTAssertEqual(words.respelled("The bright wellness plan."), "The bright wellness plan.")
        XCTAssertEqual(words.respelled("Una vela rojiza."), "Una vela rojiza.")
    }

    /// Two short words are far too often just two words.
    func testShortWordsAreNeverJoined() {
        let known = MeetingKnownWords(typed: ["Abit"], names: ["Al Bo"])
        XCTAssertEqual(known.respelled("Just a bit more."), "Just a bit more.")
        XCTAssertEqual(known.respelled("Al bo."), "Al bo.")
    }

    // MARK: - A typed word written whole

    func testATypedWordIsPutBackItsWay() {
        XCTAssertEqual(words.respelled("brightwell is down"), "Brightwell is down")
        XCTAssertEqual(words.respelled("Lo de VELAROJA."), "Lo de Velaroja.")
    }

    func testATypedWordAlreadyRightLeavesTheLineAlone() {
        let line = "Brightwell  and Velaroja."
        XCTAssertEqual(words.respelled(line), line, "not even the double space is touched")
    }

    func testAVeryShortTypedWordIsOnlyEverJoined() {
        let known = MeetingKnownWords(typed: ["Zub"])
        XCTAssertEqual(known.respelled("the zub file"), "the zub file")
    }

    func testATypedWordInLowercaseKeepsTheCapitalThatStartsALine() {
        let known = MeetingKnownWords(typed: ["brightwell"])
        XCTAssertEqual(known.respelled("Bright well is down, bright well."), "Brightwell is down, brightwell.")
    }

    func testAccentsAreTheTypedOnes() {
        let known = MeetingKnownWords(typed: ["Murciélago"])
        XCTAssertEqual(known.respelled("El murcielago."), "El Murciélago.")
        XCTAssertEqual(known.respelled("El murcié lago."), "El Murciélago.")
    }

    // MARK: - Names

    /// A name joins a split, and nothing else: a name is often a word too.
    func testANameOnlyJoinsASplit() {
        let known = MeetingKnownWords(typed: [], names: ["Rosamar Quintela"])
        XCTAssertEqual(known.respelled("Talk to Rosa Mar about it."), "Talk to Rosamar about it.")
        XCTAssertEqual(known.respelled("Talk to rosamar about it."), "Talk to rosamar about it.")
        XCTAssertEqual(known.respelled("Quin tela said no."), "Quintela said no.")
        XCTAssertEqual(known.respelled("rosamar quintela"), "rosamar quintela")
    }

    func testShortPartsOfANameAreNotLookedFor() {
        let known = MeetingKnownWords(typed: [], names: ["Ana Lu"])
        XCTAssertEqual(known.spellings, ["Ana Lu"])
    }

    func testAnEmailAddressIsNotAName() {
        let known = MeetingKnownWords(typed: [], names: ["someone@example.com"])
        XCTAssertTrue(known.isEmpty)
    }

    func testATypedSpellingWinsOverAName() {
        let known = MeetingKnownWords(typed: ["BrightWell"], names: ["Brightwell"])
        XCTAssertEqual(known.spellings, ["BrightWell"])
        XCTAssertEqual(known.respelled("bright well"), "BrightWell")
    }

    func testAMeetingsNamesComeFromTheInviteAndFromVoicesNamedBefore() {
        let start = Date(timeIntervalSince1970: 0)
        let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   event: MeetingEvent(title: "Plan", start: start, attendees: ["Quintela"]),
                                   names: [MeetingVoiceName(voice: 2, name: "Rosamar"),
                                           MeetingVoiceName(voice: 1, name: "", isYou: true)])
        let earlier = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                    names: [MeetingVoiceName(voice: 3, name: "Valdemoro")])
        let known = MeetingKnownWords.forMeeting(record, typed: ["Brightwell"], earlier: [earlier])
        XCTAssertEqual(known.spellings, ["Brightwell", "Quintela", "Rosamar", "Valdemoro"])
    }

    // MARK: - A whole meeting

    func testEveryLineOfAMeetingIsRespelledTheShadowToo() {
        let start = Date(timeIntervalSince1970: 0)
        var record = MeetingRecord(
            bundleID: "a", appName: "Zoom", startedAt: start,
            segments: [MeetingSegment(speaker: .them, start: 1, end: 2, text: "Bright well first."),
                       MeetingSegment(speaker: .me, start: 3, end: 4, text: "Then lunch.")],
            shadow: [MeetingShadowLine(segment: MeetingSegment(speaker: .them, start: 1, end: 2,
                                                               text: "Vela roja primero."),
                                       language: "es_ES")])
        XCTAssertEqual(words.respell(&record), 1)
        XCTAssertEqual(record.segments.map(\.text), ["Brightwell first.", "Then lunch."])
        XCTAssertEqual(record.shadow.map(\.segment.text), ["Velaroja primero."])
        XCTAssertEqual(record.segments.map(\.start), [1, 3], "times and order are kept")
    }

    func testNoWordsChangeNothing() {
        let start = Date(timeIntervalSince1970: 0)
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   segments: [MeetingSegment(speaker: .them, start: 1, end: 2, text: "bright well")])
        let before = record
        XCTAssertEqual(MeetingKnownWords(typed: []).respell(&record), 0)
        XCTAssertEqual(record, before)
    }

    // MARK: - The list in Settings

    func testSeveralWordsCanBeAddedAtOnce() {
        XCTAssertEqual(MeetingKnownWords.adding(" Brightwell,  Vela  roja ;Quintela\n", to: []),
                       ["Brightwell", "Vela roja", "Quintela"])
    }

    func testAWordAlreadyListedIsNotAddedAgain() {
        XCTAssertEqual(MeetingKnownWords.adding("brightwell, Velaroja", to: ["Brightwell"]),
                       ["Brightwell", "Velaroja"])
    }

    func testNothingTypedAddsNothing() {
        XCTAssertEqual(MeetingKnownWords.adding(" , ; ", to: ["Brightwell"]), ["Brightwell"])
    }

    func testTheListHasALimit() {
        let many = (0..<300).map { "Word\($0)" }
        XCTAssertEqual(MeetingKnownWords.adding(many.joined(separator: ","), to: []).count,
                       MeetingKnownWords.mostTyped)
    }

    func testAWordIsRemovedHoweverItIsWritten() {
        XCTAssertEqual(MeetingKnownWords.removing("brightwell", from: ["Brightwell", "Velaroja"]), ["Velaroja"])
    }
}
