import XCTest
@testable import AirlockCore

/// Where CPU went between two sweeps. The half that is easy is processes alive
/// at both ends; these tests are mostly about the half that is not — the
/// compilers of a parallel build, which start and finish between readings — and
/// about every way a process table changes under the reader: starts, ends, pid
/// reuse, reaping mid-sweep.
///
/// The standing rule under all of it: a race may lose CPU, never invent it.
final class CPUAttributionTests: XCTestCase {

    private let xcode = ProcessGroup(kind: .app, name: "Xcode")
    private let chrome = ProcessGroup(kind: .app, name: "Google Chrome")
    private let zsh = ProcessGroup(kind: .program, name: "zsh")
    private let awk = ProcessGroup(kind: .program, name: "awk")
    private let node = ProcessGroup(kind: .program, name: "node")

    /// launchd: in every sweep, never ours to read.
    private let launchd = ProcessRecord(identity: .init(pid: 1, started: 1), parent: 0, group: nil, reading: .unreadable)

    private func record(_ pid: Int32, parent: Int32 = 1, started: UInt64 = 7, _ group: ProcessGroup,
                        own: Double, reaped: Double = 0, reapedAtEnd: Double? = nil,
                        startedAt: Double = 0, folded: Bool = false) -> ProcessRecord {
        ProcessRecord(identity: .init(pid: pid, started: started), parent: parent, group: group,
                      reading: .read(ProcessCPU(own: own, reaped: reaped, reapedAtEnd: reapedAtEnd, startedAt: startedAt)),
                      foldedIntoParent: folded)
    }

    private func sweep(at time: Double, _ records: [ProcessRecord]) -> ProcessSweep {
        ProcessSweep(takenAt: time, records: [launchd] + records)
    }

    private func attribute(_ old: ProcessSweep, _ new: ProcessSweep) -> [ProcessGroup: Double] {
        CPUAttribution.attribute(from: old, to: new).seconds
    }

    /// Same groups, same figures to within floating-point noise.
    private func assertCredits(_ actual: [ProcessGroup: Double], _ expected: [ProcessGroup: Double],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), file: file, line: line)
        for (group, seconds) in expected {
            XCTAssertEqual(actual[group] ?? .nan, seconds, accuracy: 1e-9, "\(group)", file: file, line: line)
        }
    }

    // MARK: - Alive at both ends

    func testASurvivorIsCreditedWithWhatItUsedInTheWindow() {
        let old = sweep(at: 10, [record(100, xcode, own: 10)])
        let new = sweep(at: 13, [record(100, xcode, own: 12.5)])
        let result = CPUAttribution.attribute(from: old, to: new)
        assertCredits(result.seconds, [xcode: 2.5])
        XCTAssertEqual(result.window, 3)
    }

    func testSeveralProcessesOfOneAppAreOneFigure() {
        let old = sweep(at: 0, [record(100, chrome, own: 1), record(101, parent: 100, chrome, own: 4)])
        let new = sweep(at: 3, [record(100, chrome, own: 1.5), record(101, parent: 100, chrome, own: 5)])
        assertCredits(attribute(old, new), [chrome: 1.5])
    }

    func testAnIdleProcessIsNotInTheResult() {
        let old = sweep(at: 0, [record(100, zsh, own: 3)])
        let new = sweep(at: 3, [record(100, zsh, own: 3)])
        assertCredits(attribute(old, new), [:])
    }

    // MARK: - Starting inside the window

    func testAProcessBornInTheWindowIsCreditedWithEverythingItUsed() {
        let old = sweep(at: 10, [])
        let new = sweep(at: 13, [record(200, node, own: 1.2, reaped: 0.3, startedAt: 11)])
        assertCredits(attribute(old, new), [node: 1.5])
    }

    /// Missing from the first sweep but older than it: everything it used so far
    /// has no known start, so none of it is counted — never a guess.
    func testAProcessOlderThanTheFirstSweepButMissingFromItIsNotGuessed() {
        let old = sweep(at: 10, [])
        let new = sweep(at: 13, [record(200, node, own: 400, startedAt: 2)])
        assertCredits(attribute(old, new), [:])
    }

    // MARK: - Ending inside the window

    /// The case the whole attribution exists for: a build's compilers live a
    /// second or two, start and finish between readings, and are never seen by
    /// a sweep. Their CPU reaches their parent's "children" counter when they
    /// are reaped, and is credited to whatever started them.
    func testAParallelBuildsShortLivedCompilersShowUnderWhatStartedThem() {
        let buildService = record(100, xcode, own: 5, reaped: 20)
        let old = sweep(at: 0, [buildService])
        // 300 compilers, 0.4 s of CPU each, all started and reaped in the window.
        let new = sweep(at: 3, [record(100, xcode, own: 5.5, reaped: 20 + 300 * 0.4)])
        assertCredits(attribute(old, new), [xcode: 0.5 + 120])
    }

    func testABurstFromAShellIsTheShellsNotTheLeftovers() {
        let old = sweep(at: 0, [record(500, zsh, own: 0.1)])
        let new = sweep(at: 2, [record(500, zsh, own: 0.12, reaped: 50 * 0.05)])
        assertCredits(attribute(old, new), [zsh: 0.02 + 2.5])
    }

    /// A child seen at the first sweep had its CPU up to then counted already.
    /// Reaping moves that same CPU into the parent's counter, and it must not
    /// be counted a second time there.
    func testAChildSeenAliveThenReapedIsNotCountedTwice() {
        let old = sweep(at: 0, [record(100, zsh, own: 1),
                                record(101, parent: 100, awk, own: 3)])
        // The child used two more seconds, then died and was reaped.
        let new = sweep(at: 3, [record(100, zsh, own: 1, reaped: 5)])
        assertCredits(attribute(old, new), [zsh: 2])
    }

    /// A reaped parent carries its reaped children up with it, so what was
    /// already counted for both comes out of the grandparent's growth.
    func testGrandchildrenReapedThroughADeadParentAreCountedOnce() {
        let old = sweep(at: 0, [record(100, xcode, own: 0),
                                record(101, parent: 100, xcode, own: 2, reaped: 1),
                                record(102, parent: 101, xcode, own: 3)])
        // 102 uses 1 more and is reaped by 101 (101.reaped = 1 + 4); 101 uses
        // 1 more and is reaped by 100 (100.reaped = 3 + 5).
        let new = sweep(at: 3, [record(100, xcode, own: 0, reaped: 8)])
        assertCredits(attribute(old, new), [xcode: 2])
    }

    /// When the middle process dies first, its child is reparented to launchd
    /// and reaped there, where it is not ours to read. That CPU is lost, and
    /// the grandparent's figure comes out low — never negative, never more
    /// than was used.
    func testAnOrphansLastSecondsAreLostNotInvented() {
        let old = sweep(at: 0, [record(100, zsh, own: 0),
                                record(101, parent: 100, awk, own: 1),
                                record(102, parent: 101, awk, own: 2)])
        // 101 used 0.5 more and was reaped by 100; 102 went to launchd.
        let new = sweep(at: 3, [record(100, zsh, own: 0, reaped: 1.5)])
        let result = attribute(old, new)
        XCTAssertEqual(result[zsh] ?? 0, 0)
        XCTAssertTrue(result.values.allSatisfy { $0 >= 0 })
    }

    /// Reaped after its own read and before its parent's end-of-sweep re-read:
    /// its whole life is already inside the parent's baseline, so taking it out
    /// again would swallow real CPU from the next window.
    func testAChildFoldedIntoItsParentsBaselineIsNotTakenOutAgain() {
        let old = sweep(at: 0, [record(100, zsh, own: 1, reaped: 0, reapedAtEnd: 4),
                                record(101, parent: 100, awk, own: 4, folded: true)])
        // In the window another child used 2 s and was reaped.
        let new = sweep(at: 3, [record(100, zsh, own: 1, reaped: 6)])
        assertCredits(attribute(old, new), [zsh: 2])
    }

    /// Listed, then gone before it could be read: reaped during the first
    /// sweep, so inside its parent's end-of-sweep baseline already.
    func testAVanishedRecordIsNeitherCreditedNorTakenOut() {
        let vanished = ProcessRecord(identity: .init(pid: 101, started: 9), parent: 100, group: nil, reading: .vanished)
        let old = sweep(at: 0, [record(100, zsh, own: 1, reaped: 0, reapedAtEnd: 3), vanished])
        let new = sweep(at: 3, [record(100, zsh, own: 1, reaped: 5)])
        assertCredits(attribute(old, new), [zsh: 2])
    }

    /// A child nobody could read (another user's, like `sudo`) dies with an
    /// unknown amount of CPU. The reaper's growth cannot be split into "that"
    /// and "this window", so it gets no reaped credit rather than a guess.
    func testAReaperOfAnUnreadableChildGetsNoReapedCredit() {
        let sudo = ProcessRecord(identity: .init(pid: 101, started: 9), parent: 100, group: nil, reading: .unreadable)
        let old = sweep(at: 0, [record(100, zsh, own: 1), sudo])
        let new = sweep(at: 3, [record(100, zsh, own: 1.5, reaped: 7)])
        assertCredits(attribute(old, new), [zsh: 0.5])
    }

    // MARK: - pid reuse

    /// The same pid with a different start time is a different process. Matched
    /// on pid alone, this is a 50-second counter "going" to 0.2 — a negative
    /// figure — or, the other way round, a spike.
    func testPIDReuseIsTwoProcessesNotOneThatWentBackwards() {
        let old = sweep(at: 0, [record(300, started: 1, awk, own: 50)])
        let new = sweep(at: 3, [record(300, started: 2, node, own: 0.2, startedAt: 1)])
        assertCredits(attribute(old, new), [node: 0.2])
    }

    func testPIDReuseTheOtherWayRoundIsNotASpike() {
        let old = sweep(at: 0, [record(300, started: 1, node, own: 0.2)])
        let new = sweep(at: 3, [record(300, started: 2, awk, own: 50, startedAt: -100)])
        // The new process claims to predate the window; with no baseline for it
        // nothing is credited, and certainly not 49.8 seconds in three.
        assertCredits(attribute(old, new), [:])
    }

    /// The dead parent's pid handed to a newcomer is not a survivor to credit.
    func testAReapersReusedPIDIsNotTheReaper() {
        let old = sweep(at: 0, [record(100, started: 1, zsh, own: 1),
                                record(101, parent: 100, awk, own: 3)])
        let new = sweep(at: 3, [record(100, started: 2, node, own: 0.1, reaped: 30, startedAt: 2)])
        // The newcomer's children were born after it: all of it is its own.
        assertCredits(attribute(old, new), [node: 30.1])
    }

    // MARK: - Never negative, never a ghost

    func testCountersThatGoBackwardsAreZeroNotNegative() {
        let old = sweep(at: 0, [record(100, zsh, own: 5, reaped: 5)])
        let new = sweep(at: 3, [record(100, zsh, own: 4, reaped: 4)])
        assertCredits(attribute(old, new), [:])
    }

    /// A process that ended is not a row: nothing is credited to a group that
    /// has no process left to have used it, unless a survivor reaped it.
    func testAProcessThatEndedLeavesNoGhostRow() {
        let old = sweep(at: 0, [record(300, awk, own: 9)])
        let new = sweep(at: 3, [])
        assertCredits(attribute(old, new), [:])
    }

    func testAnEmptyOrBackwardsWindowCreditsNothing() {
        let old = sweep(at: 10, [record(100, zsh, own: 1)])
        let same = sweep(at: 10, [record(100, zsh, own: 3)])
        let earlier = sweep(at: 7, [record(100, zsh, own: 3)])
        XCTAssertEqual(CPUAttribution.attribute(from: old, to: same).seconds, [:])
        XCTAssertEqual(CPUAttribution.attribute(from: old, to: earlier).window, 0)
    }

    /// A table that lists a cycle of parents ends the walk rather than hanging.
    func testAParentCycleEndsTheWalk() {
        let old = sweep(at: 0, [record(100, parent: 101, zsh, own: 1),
                                record(101, parent: 100, zsh, own: 1)])
        let new = sweep(at: 3, [])
        assertCredits(attribute(old, new), [:])
    }

    func testDuplicateListingsDoNotDoubleCount() {
        let twice = record(100, zsh, own: 4)
        let old = ProcessSweep(takenAt: 0, records: [launchd, record(100, zsh, own: 1), record(100, zsh, own: 1)])
        let new = ProcessSweep(takenAt: 3, records: [launchd, twice, twice])
        assertCredits(attribute(old, new), [zsh: 3])
    }

    // MARK: - Taking a sweep

    /// The kernel lists processes in no promised order, and a child before its
    /// parent is common. Whatever the listing, each is read once, after its
    /// parent.
    func testEveryProcessIsReadOnceAndAfterItsParent() {
        // 1 ← 100 ← 101 ← 102, and 1 ← 200 ← 201, listed children first.
        let pids: [Int32] = [102, 201, 101, 1, 200, 100]
        let parents: [Int32] = [101, 200, 100, 0, 1, 1]
        let order = ProcessSweep.readingOrder(pids: pids, parents: parents)
        XCTAssertEqual(order.sorted(), Array(pids.indices))
        let place = Dictionary(uniqueKeysWithValues: order.enumerated().map { (pids[$1], $0) })
        for (pid, parent) in zip(pids, parents) where place[parent] != nil {
            XCTAssertLessThan(place[parent]!, place[pid]!, "\(pid) read before its parent \(parent)")
        }
    }

    /// A process whose parent is not listed — launchd's parent, or a parent
    /// that exited while the listing was made — starts a tree of its own.
    func testProcessesWithoutAListedParentAreReadFirstInListingOrder() {
        let order = ProcessSweep.readingOrder(pids: [300, 5, 301], parents: [9_999, 8_888, 300])
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testAListedCycleIsStillReadLastRatherThanDropped() {
        let order = ProcessSweep.readingOrder(pids: [1, 100, 101], parents: [0, 101, 100])
        XCTAssertEqual(order, [0, 1, 2])
    }

    private func folded(_ records: [ProcessRecord], alive: [ProcessRecord], reRead: Set<Int32>) -> [Int32: Bool] {
        var records = records
        ProcessSweep.markFolded(&records, alive: Set(alive.map(\.identity)), reRead: reRead)
        return Dictionary(uniqueKeysWithValues: records.map { ($0.identity.pid, $0.foldedIntoParent) })
    }

    /// Gone by the second listing means reaped before any re-read, so a parent
    /// that was re-read afterwards already holds all of it.
    func testAChildGoneByTheSecondListingIsInsideItsParentsReRead() {
        let parent = record(100, zsh, own: 1), child = record(101, parent: 100, awk, own: 2)
        XCTAssertEqual(folded([parent, child], alive: [parent], reRead: [100]), [100: false, 101: true])
    }

    /// A parent whose re-read failed has no end-of-sweep baseline to be inside.
    func testAChildIsNotFoldedIntoAParentThatWasNotReRead() {
        let parent = record(100, zsh, own: 1), child = record(101, parent: 100, awk, own: 2)
        XCTAssertEqual(folded([parent, child], alive: [parent], reRead: []), [100: false, 101: false])
    }

    /// Still listed at the second listing: if it died after that, it may have
    /// died after its parent's re-read too, so it is not known to be inside it.
    func testAChildAliveAtTheSecondListingIsNotFolded() {
        let parent = record(100, zsh, own: 1), child = record(101, parent: 100, awk, own: 2)
        XCTAssertEqual(folded([parent, child], alive: [parent, child], reRead: [100]), [100: false, 101: false])
    }

    /// A chain that died together is inside the re-read of the first survivor.
    func testAChainGoneTogetherIsInsideTheFirstSurvivorsReRead() {
        let top = record(100, xcode, own: 0)
        let middle = record(101, parent: 100, xcode, own: 1)
        let bottom = record(102, parent: 101, xcode, own: 1)
        XCTAssertEqual(folded([top, middle, bottom], alive: [top], reRead: [100]),
                       [100: false, 101: true, 102: true])
    }

    /// Its pid is back, as somebody else: the process that was read is gone.
    func testAReusedPIDAtTheSecondListingIsStillGone() {
        let parent = record(100, zsh, own: 1)
        let child = record(101, parent: 100, started: 1, awk, own: 2)
        let newcomer = record(101, parent: 100, started: 2, node, own: 0)
        XCTAssertEqual(folded([parent, child], alive: [parent, newcomer], reRead: [100]), [100: false, 101: true])
    }

    func testOnlyReadRecordsAreEverFolded() {
        let parent = record(100, zsh, own: 1)
        let vanished = ProcessRecord(identity: .init(pid: 101, started: 9), parent: 100, group: nil, reading: .vanished)
        let unreadable = ProcessRecord(identity: .init(pid: 102, started: 9), parent: 100, group: nil, reading: .unreadable)
        XCTAssertEqual(folded([parent, vanished, unreadable], alive: [parent], reRead: [100]),
                       [100: false, 101: false, 102: false])
    }
}
