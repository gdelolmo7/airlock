import Foundation
import XCTest
import AirlockTestSupport
@testable import AirlockCore

/// What takes the person out of a crash report (`CrashReportScrubber`).
final class CrashReportScrubberTests: XCTestCase {
    private let scrubber = CrashReportScrubber(
        computerNames: ["Ana's MacBook Pro", "Anas-MacBook-Pro", "Anas-MacBook-Pro.local"],
        userNames: ["anagarcia", "Ana García"])

    func testTheComputerNameIsReplaced() {
        XCTAssertEqual(scrubber.scrub("crashed on Ana's MacBook Pro at noon"),
                       "crashed on <computer> at noon")
        XCTAssertEqual(scrubber.scrub("host Anas-MacBook-Pro.local refused"),
                       "host <computer> refused")
        XCTAssertEqual(scrubber.scrub("ANAS-MACBOOK-PRO"), "<computer>")
    }

    func testTheUserNameAndFullNameAreReplaced() {
        XCTAssertEqual(scrubber.scrub("owner anagarcia"), "owner <user>")
        XCTAssertEqual(scrubber.scrub("signed in as Ana García."), "signed in as <user>.")
    }

    func testHomeFolderPathsLoseTheAccountName() {
        XCTAssertEqual(
            scrubber.scrub("/Users/anagarcia/Applications/Airlock.app/Contents/MacOS/Airlock"),
            "/Users/<user>/Applications/Airlock.app/Contents/MacOS/Airlock")
        // Somebody else's account on the same Mac, which no name list knows.
        XCTAssertEqual(scrubber.scrub("open /Users/jmartinez/Desktop/notes.txt failed"),
                       "open /Users/<user>/Desktop/notes.txt failed")
        // Inside quotes and at the end of a string.
        XCTAssertEqual(scrubber.scrub("path=\"/Users/bob\""), "path=\"/Users/<user>\"")
        XCTAssertEqual(scrubber.scrub("/users/Bob/x"), "/Users/<user>/x")
    }

    /// The shared folder names nobody, and is useful to see in a report.
    func testTheSharedFolderIsKept() {
        XCTAssertEqual(scrubber.scrub("/Users/Shared/Airlock/log"), "/Users/Shared/Airlock/log")
        XCTAssertEqual(scrubber.scrub("/Users/Shared"), "/Users/Shared")
        // A person whose account name only starts with Shared is still a person.
        XCTAssertEqual(scrubber.scrub("/Users/Sharedmind/x"), "/Users/<user>/x")
    }

    /// Short names would take apart the function names a report is for.
    func testShortNamesAreLeftAlone() {
        let short = CrashReportScrubber(computerNames: ["ab"], userNames: ["al", " "])
        XCTAssertEqual(short.scrub("NotchController.alignment ab"), "NotchController.alignment ab")
    }

    /// Whole words only: an account named "notch" must not cut the word out of
    /// `NotchController`.
    func testOnlyWholeWordsAreReplaced() {
        let common = CrashReportScrubber(computerNames: [], userNames: ["notch"])
        XCTAssertEqual(common.scrub("NotchController.show() for notch"), "NotchController.show() for <user>")
        // An underscore is not a letter: a name joined to something with one is
        // still the name, and the person comes before a readable symbol.
        XCTAssertEqual(common.scrub("notch_view"), "<user>_view")
    }

    func testScrubbingTwiceChangesNothingMore() {
        let once = scrubber.scrub("/Users/anagarcia on Ana's MacBook Pro")
        XCTAssertEqual(once, "/Users/<user> on <computer>")
        XCTAssertEqual(scrubber.scrub(once), once)
    }

    func testNestedValuesAreWalkedAndIdentifyingKeysDropped() {
        let value: [String: Any] = [
            "hostname": "Anas-MacBook-Pro",
            "Device_App_Hash": "4f2a",
            "path": "/Users/anagarcia/file",
            "count": 3,
            "list": ["anagarcia", 7, ["email": "a@b.c", "ok": "fine"]],
        ]
        let scrubbed = scrubber.scrub(dictionary: value)
        XCTAssertNil(scrubbed["hostname"])
        XCTAssertNil(scrubbed["Device_App_Hash"])
        XCTAssertEqual(scrubbed["path"] as? String, "/Users/<user>/file")
        XCTAssertEqual(scrubbed["count"] as? Int, 3)
        let list = scrubbed["list"] as? [Any]
        XCTAssertEqual(list?[0] as? String, "<user>")
        XCTAssertEqual(list?[1] as? Int, 7)
        let inner = list?[2] as? [String: Any]
        XCTAssertNil(inner?["email"])
        XCTAssertEqual(inner?["ok"] as? String, "fine")
    }

    /// Contexts are kept by name: version, model and macOS stay, and
    /// everything else goes, including whole contexts nobody listed.
    func testContextsKeepOnlyTheAllowedFacts() throws {
        let contexts: [String: [String: Any]] = [
            "app": ["app_version": "1.0.19", "app_build": "880", "device_app_hash": "4f2a",
                    "app_start_time": "2026-10-08T10:00:00Z"],
            "device": ["model": "Mac15,6", "boot_time": "2026-10-01", "locale": "es_ES",
                       "memory_size": 36_000_000_000],
            "os": ["name": "macOS", "version": "26.5", "build": "25F5"],
            "culture": ["timezone": "Europe/Madrid", "locale": "es_ES"],
            "user info": ["path": "/Users/anagarcia/x"],
        ]
        let kept = try XCTUnwrap(scrubber.scrub(contexts: contexts))
        XCTAssertEqual(Set(kept.keys), ["app", "device", "os"])
        XCTAssertEqual(Set(kept["app"]!.keys), ["app_version", "app_build"])
        XCTAssertEqual(Set(kept["device"]!.keys), ["model", "memory_size"])
        XCTAssertEqual(kept["os"]?["version"] as? String, "26.5")
        XCTAssertNil(scrubber.scrub(contexts: ["culture": ["timezone": "x"]]))
        XCTAssertNil(scrubber.scrub(contexts: nil))
    }
}

/// Whether the last run ended the way a run should (`CleanExitMarker`).
final class CleanExitMarkerTests: XCTestCase {
    private let scratch = TestScratch("exit")

    func testAFirstRunIsNotUnexpected() {
        let marker = CleanExitMarker(url: scratch.file("nested/running"))
        XCTAssertFalse(marker.beginRun())
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.url.path))
    }

    func testARunThatEndedNormallyIsNotUnexpected() {
        let marker = CleanExitMarker(url: scratch.file("running"))
        marker.beginRun()
        marker.endRun()
        XCTAssertFalse(marker.beginRun())
    }

    func testARunThatNeverMarkedItsEndIs() {
        let marker = CleanExitMarker(url: scratch.file("running"))
        marker.beginRun()
        // No endRun: the app crashed, or was force-quit.
        XCTAssertTrue(marker.beginRun())
        // And the run after a clean exit from that one is fine again.
        marker.endRun()
        XCTAssertFalse(marker.beginRun())
    }
}

/// When crash reports may be sent, and when to ask (`CrashReportPolicy`).
final class CrashReportPolicyTests: XCTestCase {
    private let dsn = "https://0123abcd@o12345.ingest.de.sentry.io/678"

    func testADSNIsOnlyTakenFromABundleAndOnlyWhenWellFormed() {
        XCTAssertEqual(CrashReportPolicy.usableDSN(dsn, isBundled: true), dsn)
        XCTAssertEqual(CrashReportPolicy.usableDSN("  \(dsn)\n", isBundled: true), dsn)
        XCTAssertNil(CrashReportPolicy.usableDSN(dsn, isBundled: false))
        XCTAssertNil(CrashReportPolicy.usableDSN(nil, isBundled: true))
        XCTAssertNil(CrashReportPolicy.usableDSN("", isBundled: true))
        XCTAssertNil(CrashReportPolicy.usableDSN(42, isBundled: true))
        XCTAssertNil(CrashReportPolicy.usableDSN("http://key@o1.ingest.sentry.io/1", isBundled: true))
        XCTAssertNil(CrashReportPolicy.usableDSN("https://o1.ingest.sentry.io/1", isBundled: true))
        XCTAssertNil(CrashReportPolicy.usableDSN("https://key@o1.ingest.sentry.io/", isBundled: true))
        XCTAssertNil(CrashReportPolicy.usableDSN("https://key@o1.ingest.sentry.io", isBundled: true))
    }

    func testNothingRunsWithoutADSNOrWithoutAYes() {
        XCTAssertFalse(CrashReportPolicy.shouldRun(dsn: nil, consent: true))
        XCTAssertFalse(CrashReportPolicy.shouldRun(dsn: dsn, consent: false))
        XCTAssertFalse(CrashReportPolicy.shouldRun(dsn: nil, consent: false))
        XCTAssertTrue(CrashReportPolicy.shouldRun(dsn: dsn, consent: true))
    }

    func testTheQuestionIsAskedOnceAfterAnUnexpectedQuitWhileStillOff() {
        func asks(available: Bool = true, consent: Bool = false, asked: Bool = false,
                  unexpected: Bool = true) -> Bool {
            CrashReportPolicy.asksAfterUnexpectedQuit(available: available, consent: consent,
                                                      alreadyAsked: asked,
                                                      lastRunEndedUnexpectedly: unexpected)
        }
        XCTAssertTrue(asks())
        XCTAssertFalse(asks(available: false))
        XCTAssertFalse(asks(consent: true))
        XCTAssertFalse(asks(asked: true))
        XCTAssertFalse(asks(unexpected: false))
    }
}

/// At most a few reports a day from one Mac (`CrashReportAllowance`).
final class CrashReportAllowanceTests: XCTestCase {
    private var store: TestDefaults!
    private let noon = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

    override func setUp() {
        store = TestDefaults("com.airlock.test.crashallowance")
    }

    override func tearDown() {
        store.remove()
    }

    func testFiveADayThenNothing() {
        let allowance = CrashReportAllowance(suiteName: store.name)
        for _ in 1...5 { XCTAssertTrue(allowance.take(on: noon)) }
        XCTAssertFalse(allowance.take(on: noon))
        XCTAssertFalse(allowance.take(on: noon.addingTimeInterval(3_600)))
    }

    func testTheNextDayStartsAgain() {
        let allowance = CrashReportAllowance(suiteName: store.name)
        for _ in 1...5 { _ = allowance.take(on: noon) }
        XCTAssertTrue(allowance.take(on: noon.addingTimeInterval(86_400)))
    }

    /// A crash ends the app, so the count has to outlive it.
    func testTheCountSurvivesARelaunch() {
        for _ in 1...5 { _ = CrashReportAllowance(suiteName: store.name).take(on: noon) }
        XCTAssertFalse(CrashReportAllowance(suiteName: store.name).take(on: noon))
    }
}
