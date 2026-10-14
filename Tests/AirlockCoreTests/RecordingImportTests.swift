import XCTest
@testable import AirlockCore

/// A recording added after the meeting: what it is called, when it began,
/// how far along its reading is in words, and what is kept about it.
final class RecordingImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)

    // MARK: - The meeting's name

    func testTitleIsTheFileNameWithoutItsExtension() {
        XCTAssertEqual(RecordingImport.title(forFile: "Kitchen planning.m4a"), "Kitchen planning")
        XCTAssertEqual(RecordingImport.title(forFile: "/Users/ana/Desktop/Budget review.MP3"), "Budget review")
        XCTAssertEqual(RecordingImport.title(forFile: "WhatsApp Audio 2026-10-13 at 12.25.03.opus"),
                       "WhatsApp Audio 2026-10-13 at 12.25.03")
    }

    func testTitleReadsUnderscoresAndRunsOfSpacesAsOneSpace() {
        XCTAssertEqual(RecordingImport.title(forFile: "team_sync__monday.wav"), "team sync monday")
        XCTAssertEqual(RecordingImport.title(forFile: "  New   Recording 3 .m4a"), "New Recording 3")
    }

    func testAnEndWithNoLetterIsNotAnExtension() {
        XCTAssertEqual(RecordingImport.title(forFile: "Call 12.25.03"), "Call 12.25.03")
    }

    func testANamelessFileIsARecording() {
        XCTAssertEqual(RecordingImport.title(forFile: ".m4a"), RecordingImport.fallbackTitle)
        XCTAssertEqual(RecordingImport.title(forFile: "___.mp3"), RecordingImport.fallbackTitle)
    }

    func testItsLengthIsInMinutesOrUnderTwoInMinutesAndSeconds() {
        XCTAssertEqual(RecordingImport.length(2_400), "40 min")
        XCTAssertEqual(RecordingImport.length(2_430), "41 min")
        XCTAssertEqual(RecordingImport.length(90), "1:30")
    }

    func testSoundFilesAreKnownByTheirExtension() {
        XCTAssertTrue(RecordingImport.isSound(URL(fileURLWithPath: "/a/b.M4A")))
        XCTAssertTrue(RecordingImport.isSound(URL(fileURLWithPath: "/a/voice.opus")))
        XCTAssertFalse(RecordingImport.isSound(URL(fileURLWithPath: "/a/notes.txt")))
        XCTAssertFalse(RecordingImport.isSound(URL(fileURLWithPath: "/a/folder")))
    }

    // MARK: - When it began

    func testTheRecordingsOwnDateWins() {
        let recorded = now.addingTimeInterval(-7_200)
        XCTAssertEqual(RecordingImport.startedAt(recorded: recorded, modified: now, seconds: 2_400, now: now),
                       recorded)
    }

    func testWithoutOneTheFilesLastChangeLessItsLength() {
        let modified = now.addingTimeInterval(-3_600)
        XCTAssertEqual(RecordingImport.startedAt(recorded: nil, modified: modified, seconds: 2_400, now: now),
                       modified.addingTimeInterval(-2_400))
    }

    func testWithNeitherItEndedJustNow() {
        XCTAssertEqual(RecordingImport.startedAt(recorded: nil, modified: nil, seconds: 600, now: now),
                       now.addingTimeInterval(-600))
    }

    func testItNeverBeganLaterThanItCouldHaveEndedByNow() {
        // A date from a clock set ahead is not believed.
        let ahead = now.addingTimeInterval(3_600)
        XCTAssertEqual(RecordingImport.startedAt(recorded: ahead, modified: ahead, seconds: 600, now: now),
                       now.addingTimeInterval(-600))
        // Recorded ten minutes ago, forty minutes long: it can't have ended yet.
        XCTAssertEqual(RecordingImport.startedAt(recorded: now.addingTimeInterval(-600), modified: nil,
                                                 seconds: 2_400, now: now),
                       now.addingTimeInterval(-2_400))
    }

    // MARK: - How far along

    private func progress(_ stage: RecordingImport.Stage, heard: TimeInterval = 0,
                          voices: Bool = true) -> RecordingImport.Progress {
        RecordingImport.Progress(stage: stage, fileName: "Kitchen planning.m4a", seconds: 2_400,
                                 heard: heard, tellsVoices: voices)
    }

    func testAFortyMinuteRecordingTakesSevenToNineMinutes() {
        let left = progress(.opening).timeLeft
        XCTAssertGreaterThan(left, 7 * 60)
        XCTAssertLessThan(left, 9 * 60)
    }

    func testTheBarOnlyEverGoesForward() {
        let steps = [progress(.opening), progress(.listening), progress(.listening, heard: 840),
                     progress(.listening, heard: 2_400), progress(.voices), progress(.notes)]
        let fractions = steps.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(fractions.first, 0)
        XCTAssertLessThan(fractions.last ?? 1, 1)
    }

    func testFourteenMinutesInIsAboutAThirdWithAboutSixMinutesLeft() {
        let at = progress(.listening, heard: 840)
        XCTAssertEqual(at.heardWords, "14 of 40 min")
        XCTAssertTrue((25...40).contains(at.percent), "\(at.percent)%")
        XCTAssertEqual(at.timeLeftSentence, "About 6 minutes left.")
        XCTAssertEqual(at.timeLeftShort, "about 6 min left")
        XCTAssertEqual(at.doing, "Reading the recording")
        XCTAssertEqual(at.heading, "Listening to the recording")
        XCTAssertEqual(progress(.notes).heading, "Writing the notes")
    }

    func testTheLastMomentsAreSaidPlainly() {
        let short = RecordingImport.Progress(stage: .notes, fileName: "a.m4a", seconds: 30)
        XCTAssertEqual(short.timeLeftSentence, "Almost done.")
        XCTAssertEqual(short.timeLeftShort, "almost done")
        XCTAssertEqual(short.doing, "Writing the notes")
        let voices = RecordingImport.Progress(stage: .voices, fileName: "a.m4a", seconds: 1_800)
        XCTAssertEqual(voices.timeLeftSentence, "About a minute left.")
        XCTAssertEqual(RecordingImport.Progress(stage: .voices, fileName: "a.m4a", seconds: 300).timeLeftSentence,
                       "Less than a minute left.")
    }

    func testAShortRecordingCountsInMinutesAndSeconds() {
        let at = RecordingImport.Progress(stage: .listening, fileName: "a.m4a", seconds: 90, heard: 45)
        XCTAssertEqual(at.heardWords, "0:45 of 1:30")
    }

    func testTheStepsSayWhatIsDoneAndWhatIsNext() {
        let steps = progress(.listening, heard: 840).steps
        XCTAssertEqual(steps.map(\.text), ["Opened \u{201C}Kitchen planning.m4a\u{201D}",
                                           "Writing down what was said", "Telling the voices apart",
                                           "Writing the notes"])
        XCTAssertEqual(steps.map(\.state), [.done, .now, .later, .later])
        XCTAssertEqual(steps.map(\.detail), [nil, "14 of 40 min", nil, nil])
        XCTAssertEqual(progress(.opening).steps.first?.text, "Opening \u{201C}Kitchen planning.m4a\u{201D}")
    }

    func testWithoutTheVoiceModelTheVoicesStepIsLeftOut() {
        let steps = progress(.notes, voices: false).steps
        XCTAssertEqual(steps.map(\.text).count, 3)
        XCTAssertFalse(steps.map(\.text).contains("Telling the voices apart"))
        XCTAssertEqual(steps.map(\.state), [.done, .done, .now])
    }

    // MARK: - What is kept

    func testAMeetingFromARecordingIsNamedAfterIt() {
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: now)
        record.recording = MeetingRecording(fileName: "Kitchen planning.m4a", seconds: 2_400)
        XCTAssertEqual(MeetingFiles.title(of: record), "Kitchen planning")
        XCTAssertTrue(MeetingFiles.folderName(for: record, timeZone: TimeZone(identifier: "UTC")!)
            .hasSuffix(" – Kitchen planning"))
        record.endedAt = now.addingTimeInterval(2_400)
        XCTAssertTrue(MeetingFiles.notesPage(for: record, notes: nil).hasPrefix("# Notes: Kitchen planning"))
        // The calendar's name, if it were ever given one, still wins.
        record.event = MeetingEvent(title: "Shop handover", start: now)
        XCTAssertEqual(MeetingFiles.title(of: record), "Shop handover")
    }

    func testWhileItIsReadItsEndIsItsStartPlusItsLength() {
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: now)
        XCTAssertNil(record.shownEnd)
        record.recording = MeetingRecording(fileName: "a.m4a", seconds: 2_400)
        XCTAssertEqual(record.shownEnd, now.addingTimeInterval(2_400))
        record.endedAt = now.addingTimeInterval(2_399)
        XCTAssertEqual(record.shownEnd, now.addingTimeInterval(2_399))
    }

    func testTheCallsTabKnowsARowCameFromARecording() {
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: now)
        record.endedAt = now.addingTimeInterval(600)
        var added = record
        added.recording = MeetingRecording(fileName: "a.m4a", seconds: 600)
        let rows = CallsCard.rows(from: [(URL(fileURLWithPath: "/m/a"), record), (URL(fileURLWithPath: "/m/b"), added)],
                                  page: { _ in nil })
        XCTAssertEqual(rows.first { $0.folder == "a" }?.fromRecording, false)
        XCTAssertEqual(rows.first { $0.folder == "b" }?.fromRecording, true)
    }

    func testTheRecordingIsKeptInTheRecordAndAnOlderRecordHasNone() throws {
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: now)
        record.recording = MeetingRecording(fileName: "Voice memo.m4a", seconds: 61)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(MeetingRecord.self, from: encoder.encode(record))
        XCTAssertEqual(back.recording, MeetingRecording(fileName: "Voice memo.m4a", seconds: 61))
        XCTAssertTrue(back.isInPerson)

        let old = #"{"bundleID":"us.zoom.xos","appName":"Zoom","startedAt":"2026-10-08T12:00:00Z"}"#
        XCTAssertNil(try decoder.decode(MeetingRecord.self, from: Data(old.utf8)).recording)
    }
}
