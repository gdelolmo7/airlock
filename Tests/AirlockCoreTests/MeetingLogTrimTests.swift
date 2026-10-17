import Foundation
import XCTest
@testable import AirlockCore

final class MeetingLogTrimTests: XCTestCase {
    // MARK: - A long call

    func testAThreeHourCallKeepsItsOpeningItsEventsAndItsEnd() {
        let call = Call(minutes: 180)
        let log = written(Call(minutes: 40, app: "com.google.Chrome", startHour: 7).lines + call.lines)
        let lines = log.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.first, MeetingLogTrim.cutNote, "a cut log says so first")
        XCTAssertEqual(lines.filter { $0 == MeetingLogTrim.cutNote }.count, 1, "and only once, however many cuts")
        for line in call.opening { XCTAssertTrue(lines.contains(line), "lost from the opening: \(line)") }
        for line in call.events { XCTAssertTrue(lines.contains(line), "lost from the middle: \(line)") }
        for line in call.end { XCTAssertTrue(lines.contains(line), "lost from the end: \(line)") }
        for line in call.checkUps.suffix(40) { XCTAssertTrue(lines.contains(line), "lost a recent check-up: \(line)") }
        XCTAssertFalse(lines.contains(call.checkUps[100]), "the middle check-ups are what makes room")
    }

    func testCheckUpsGoOldestFirst() {
        let call = Call(minutes: 180)
        let lines = Set(written(call.lines).split(separator: "\n").map(String.init))
        let kept = call.checkUps.filter { !call.opening.contains($0) }.map(lines.contains)

        XCTAssertTrue(kept.contains(false), "the call should have needed a cut")
        XCTAssertFalse(zip(kept, kept.dropFirst()).contains { $0 && !$1 },
                       "a newer check-up was dropped while an older one was kept")
    }

    func testTheLogNeverGrowsPastTheCapByMoreThanALine() {
        var log = ""
        for line in Call(minutes: 600).lines {
            if log.utf8.count > MeetingLogTrim.cap { log = MeetingLogTrim.trimmed(log) }
            log += line + "\n"
            XCTAssertLessThanOrEqual(log.utf8.count, MeetingLogTrim.cap + line.utf8.count + 1)
        }
    }

    // MARK: - The order

    func testALogUnderTheKeepComesBackAsItIs() {
        let text = Call(minutes: 5).lines.joined(separator: "\n") + "\n"
        XCTAssertEqual(MeetingLogTrim.trimmed(text), text)
    }

    func testWithOnlyOrdinaryLinesTheNewestStay() {
        let lines = (0..<400).map { String(format: "10:%02d:%02d  them language watch: en %d/12 lines", $0 / 60, $0 % 60, $0) }
        let cut = MeetingLogTrim.trimmed(lines.joined(separator: "\n"), keep: 2_000)
        let kept = cut.split(separator: "\n").map(String.init)

        XCTAssertEqual(kept.first, MeetingLogTrim.cutNote)
        XCTAssertEqual(Array(kept.dropFirst()), Array(lines.suffix(kept.count - 1)))
        XCTAssertLessThanOrEqual(cut.utf8.count, 2_000)
    }

    func testOpeningsGoLastAndTheOldestCallsFirst() {
        func call(_ app: String, hour: Int) -> [String] {
            ["\(String(format: "%02d", hour)):00:00  call started: \(app)"]
                + (1...70).map { String(format: "%02d:%02d:00  them language watch: ca %d/12 lines", hour, $0 % 60, $0) }
        }
        let first = call("us.zoom.xos", hour: 9), second = call("com.microsoft.teams2", hour: 10)
        let text = (first + second).joined(separator: "\n")
        let note = MeetingLogTrim.cutNote.utf8.count + 1
        let openings = first.prefix(MeetingLogTrim.openingLines) + second.prefix(MeetingLogTrim.openingLines)
        let openingsSize = openings.reduce(0) { $0 + $1.utf8.count + 1 }

        XCTAssertEqual(MeetingLogTrim.trimmed(text, keep: note + openingsSize),
                       ([MeetingLogTrim.cutNote] + openings).joined(separator: "\n") + "\n",
                       "every line outside an opening goes before any opening, newer or not")

        let tighter = MeetingLogTrim.trimmed(text, keep: note + openingsSize - 1)
        XCTAssertFalse(tighter.contains(first[0]), "then the oldest call's first line")
        XCTAssertTrue(tighter.contains(second[0]))
    }

    func testTheTimeCanBeWrittenInAnyClockFormat() {
        let morning = "9:00:04\u{202F}AM  "
        XCTAssertTrue(MeetingLogTrim.starts("\(morning)echo: delay 40 ms (clarity 30.0)", with: MeetingLogTrim.everyMinute))
        XCTAssertTrue(MeetingLogTrim.starts("\(morning)echo: no delay found (clarity 0.0)", with: MeetingLogTrim.everyMinute))
        XCTAssertTrue(MeetingLogTrim.starts("\(morning)call started: us.zoom.xos", with: MeetingLogTrim.openers))
    }

    func testOnlyTheCheckUpsCountAsEveryMinute() {
        XCTAssertFalse(MeetingLogTrim.starts("09:00:04  echo: speakers tap up at 48000 Hz", with: MeetingLogTrim.everyMinute))
        XCTAssertFalse(MeetingLogTrim.starts("09:00:04  echo: off", with: MeetingLogTrim.everyMinute))
        XCTAssertFalse(MeetingLogTrim.starts("09:00:04  words: sides: 2", with: MeetingLogTrim.everyMinute),
                       "matched at the start of the message, never inside it")
        XCTAssertFalse(MeetingLogTrim.starts("sides: no time in front", with: MeetingLogTrim.everyMinute))
    }

    // MARK: - The file

    func testTheFileIsCutInPlaceAndStaysPrivate() throws {
        let url = try scratchFile(written: Call(minutes: 300).lines.joined(separator: "\n") + "\n")
        let before = try XCTUnwrap(size(of: url))
        XCTAssertGreaterThan(before, MeetingLogTrim.cap)

        MeetingLogTrim.trimIfNeeded(at: url)

        XCTAssertLessThanOrEqual(try XCTUnwrap(size(of: url)), MeetingLogTrim.keep)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix(MeetingLogTrim.cutNote + "\n"))
    }

    func testAFileUnderTheCapIsLeftAlone() throws {
        let text = Call(minutes: 30).lines.joined(separator: "\n") + "\n"
        let url = try scratchFile(written: text)

        MeetingLogTrim.trimIfNeeded(at: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func testAMissingFileIsNotCreated() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).log")
        MeetingLogTrim.trimIfNeeded(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    /// A call as the log shows it: how it started, a check-up pair every
    /// minute, now and then something that happened, and how it ended.
    /// Numbers and app names only, like the real log.
    private struct Call {
        var opening: [String] = []
        var events: [String] = []
        var checkUps: [String] = []
        var end: [String] = []
        var lines: [String] = []

        init(minutes: Int, app: String = "us.zoom.xos", startHour: Int = 9) {
            func at(_ minute: Int, _ second: Int) -> String {
                String(format: "%02d:%02d:%02d", (startHour + minute / 60) % 24, minute % 60, second)
            }
            let start = [
                "\(at(0, 0))  call started: \(app)",
                "\(at(0, 3))  notes: new 2026-01-05 09.00 – Call",
                "\(at(0, 4))  speech: en_US (speech) + es_ES (speech), dictation's languages",
                "\(at(0, 4))  echo: speakers tap up at 48000 Hz",
                "\(at(0, 4))  call tap up by bundle ID [\(app)], restore on: \(app) 1 process(es) at 48000 Hz",
                "\(at(0, 5))  mute: button found, not muted (412 elements, 38 ms)",
            ]
            lines = start
            for minute in 1...minutes {
                let echo = "\(at(minute, 30))  echo: delay \(40 + minute % 7) ms (clarity 31.4, \(minute * 60) found, "
                    + "moved 1); speakers played \(minute * 58)s of \(minute * 60)s, mic quieter by 4.6 dB "
                    + "(filter -17.8); unmatched 3; tap \(minute * 5_700) buffers, peak 0.812"
                let sides = "\(at(minute, 30))  sides: yours sound 0s ago, speech 1s ago; theirs from the call tap "
                    + "sound 0s ago, speech 0s ago, call tap peak 0.640; Mac played a voice 0s ago, peak 0.640; "
                    + "words you \(minute * 20), them \(minute * 45)"
                checkUps += [echo, sides]
                lines += [echo, sides]
                if minute % 25 == 0 {
                    let event = "\(at(minute, 41))  mute: \(minute % 50 == 0 ? "unmuted" : "muted") by the call's button"
                    events.append(event)
                    lines.append(event)
                }
            }
            end = [
                "\(at(minutes, 50))  call ended: \(app)",
                "\(at(minutes, 52))  notes: \(minutes * 9) line(s), \(minutes) min",
                "\(at(minutes, 53))  summary: written in en_US",
            ]
            lines += end
            // The notes start a line after the call, and open sixty of their own.
            opening = Array(lines.prefix(1 + MeetingLogTrim.openingLines))
        }
    }

    /// The log as the app leaves it after writing `lines`: each appended,
    /// the cut made before a write once the file is past the cap.
    private func written(_ lines: [String]) -> String {
        var log = ""
        for line in lines {
            if log.utf8.count > MeetingLogTrim.cap { log = MeetingLogTrim.trimmed(log) }
            log += line + "\n"
        }
        return log
    }

    private func scratchFile(written text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-\(UUID().uuidString).log")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }
}
