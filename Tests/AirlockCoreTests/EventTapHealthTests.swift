import XCTest
@testable import AirlockCore

/// The check that replaces a success signal which was never a signal.
///
/// `HoldKeyMonitor` treated `CGEvent.tapCreate` returning a port as proof the
/// hotkey worked, logged `ok`, and told Settings every permission was granted —
/// while the user held the key and nothing happened. The numbers in these tests
/// are the ones measured on the Mac where that was finally caught, not invented
/// ones, so a refactor that breaks the real case breaks a test.
final class EventTapHealthTests: XCTestCase {

    /// What `HoldKeyMonitor` asks for: flagsChanged, keyDown, three mouse
    /// buttons and scroll.
    private let requested: UInt64 = 0x240140a
    /// What came back when Input Monitoring was refused — the same mask with
    /// `keyDown` (0x400) removed by WindowServer.
    private let narrowed: UInt64 = 0x240100a

    // MARK: - The case that was shipping

    /// Disabled AND stripped of keyDown. Neither fact reached any surface.
    func testTheRealFailureIsInert() {
        let health = EventTapCheck.health(
            of: [EventTapFacts(isEnabled: false, eventsOfInterest: narrowed)],
            requested: requested)
        XCTAssertEqual(health, .inert(isEnabled: false, missingEvents: 0x400),
                       "keyDown is exactly what WindowServer removes")
        XCTAssertFalse(health.isLive)
    }

    /// The proof the fix worked: same tap, enabled, mask intact.
    func testAfterTheGrantItIsLive() {
        let health = EventTapCheck.health(
            of: [EventTapFacts(isEnabled: true, eventsOfInterest: requested)],
            requested: requested)
        XCTAssertEqual(health, .live)
        XCTAssertTrue(health.isLive)
    }

    // MARK: - The two failures told apart

    /// Enabled but narrowed. Separate from disabled because the tap is running
    /// and still cannot see a key going down.
    func testNarrowedWhileEnabledIsStillInert() {
        XCTAssertEqual(
            EventTapCheck.health(of: [EventTapFacts(isEnabled: true, eventsOfInterest: narrowed)],
                                 requested: requested),
            .inert(isEnabled: true, missingEvents: 0x400))
    }

    /// Full mask, switched off — what `tapDisabledByTimeout` leaves behind
    /// before the callback re-enables it.
    func testDisabledWithTheFullMaskIsInertWithNothingMissing() {
        XCTAssertEqual(
            EventTapCheck.health(of: [EventTapFacts(isEnabled: false, eventsOfInterest: requested)],
                                 requested: requested),
            .inert(isEnabled: false, missingEvents: 0))
    }

    func testNoTapsAtAllIsAbsent() {
        XCTAssertEqual(EventTapCheck.health(of: [], requested: requested), .absent)
    }

    // MARK: - Two taps, one permission

    /// Dictation and the ask key are two taps in one process, and event
    /// listening is granted per process. One healthy tap proves the permission,
    /// so a second one caught mid-`tapDisabledByTimeout` must not be reported as
    /// a permission failure — that would put a System Settings button on screen
    /// for something that fixes itself in microseconds.
    func testOneLiveTapIsEnough() {
        XCTAssertEqual(
            EventTapCheck.health(of: [EventTapFacts(isEnabled: false, eventsOfInterest: requested),
                                      EventTapFacts(isEnabled: true, eventsOfInterest: requested)],
                                 requested: requested),
            .live)
    }

    /// Both dead is the permission being missing, which hits every tap at once.
    func testBothTapsInertReportsTheBestOne() {
        let health = EventTapCheck.health(
            of: [EventTapFacts(isEnabled: false, eventsOfInterest: 0x40000000),
                 EventTapFacts(isEnabled: false, eventsOfInterest: narrowed)],
            requested: requested)
        XCTAssertEqual(health, .inert(isEnabled: false, missingEvents: 0x400),
                       "the closest thing to working is what the message should describe")
    }

    /// Enabled beats a wider mask when ranking which failure to describe: a tap
    /// that is running is nearer to working than one that is not.
    func testEnabledOutranksMaskCoverage() {
        let health = EventTapCheck.health(
            of: [EventTapFacts(isEnabled: false, eventsOfInterest: requested),
                 EventTapFacts(isEnabled: true, eventsOfInterest: narrowed)],
            requested: requested)
        XCTAssertEqual(health, .inert(isEnabled: true, missingEvents: 0x400))
    }

    // MARK: - Taps we did not create

    /// A tap sharing not one bit with ours belongs to something else. Counting
    /// it would report a permission failure caused by an unrelated subsystem —
    /// and a warning that fires for someone else's tap is a warning people learn
    /// to ignore.
    func testUnrelatedTapsAreIgnored() {
        let unrelated = EventTapFacts(isEnabled: false, eventsOfInterest: 1 << 29)
        XCTAssertEqual(EventTapCheck.health(of: [unrelated], requested: requested), .absent)
        XCTAssertEqual(
            EventTapCheck.health(of: [unrelated,
                                      EventTapFacts(isEnabled: true, eventsOfInterest: requested)],
                                 requested: requested),
            .live)
    }

    /// A tap watching MORE than we asked for still satisfies us. Nothing creates
    /// one today, but "covers the request" is the rule, not "equals" — and the
    /// difference is a silent false alarm if the mask ever grows a bit we did
    /// not think to compare.
    func testASupersetMaskIsLive() {
        XCTAssertEqual(
            EventTapCheck.health(
                of: [EventTapFacts(isEnabled: true, eventsOfInterest: requested | (1 << 29))],
                requested: requested),
            .live)
    }

    // MARK: - Which fault, and therefore which advice

    private var inert: EventTapHealth { .inert(isEnabled: false, missingEvents: 0x400) }

    func testAWorkingHotkeyHasNoFault() {
        XCTAssertNil(EventTapCheck.fault(health: .live, isListenEventGranted: true))
        // Granted is not what makes it fine — events arriving is. A live tap in
        // a process TCC has no record for is still a working hotkey.
        XCTAssertNil(EventTapCheck.fault(health: .live, isListenEventGranted: false))
    }

    func testNoGrantIsTheOrdinaryCase() {
        XCTAssertEqual(EventTapCheck.fault(health: inert, isListenEventGranted: false), .notGranted)
        XCTAssertEqual(EventTapCheck.fault(health: .absent, isListenEventGranted: false), .notGranted)
    }

    /// **The day-long one.** System Settings showed Airlock ticked under Input
    /// Monitoring while every tap came back disabled with `keyDown` stripped,
    /// because the stored requirement was pinned to a self-signed development
    /// certificate the shipped app no longer carries. Re-granting cannot help —
    /// the switch is attached to a rule no signature Airlock can produce will
    /// satisfy — so this case must never be told to grant the permission.
    func testGrantedButDeadIsItsOwnFault() {
        XCTAssertEqual(EventTapCheck.fault(health: inert, isListenEventGranted: true),
                       .grantIsNotWorking)
        XCTAssertNotEqual(EventTapCheck.fault(health: inert, isListenEventGranted: true),
                          .notGranted,
                          "advising 'allow it' to somebody looking at it already allowed is the "
                          + "wrong half of this bug")
    }
}
