import XCTest
@testable import AirlockCore

/// Three states, not two — and the third is the whole point.
///
/// A health page that prints a fault for something macOS simply has not been
/// asked about sends people to fix nothing, and a page that cries wolf is a page
/// nobody reads on the day something is actually wrong. These pin the cases
/// that must NOT be amber as hard as the ones that must.
final class DiagnosticsHealthTests: XCTestCase {
    private func report(permissions: [DiagnosticsReport.Permission] = [],
                        hooks: [DiagnosticsReport.Hook] = [],
                        updater: DiagnosticsReport.UpdaterState = .notBundled)
    -> DiagnosticsReport {
        DiagnosticsReport(version: "1.4.0", macOS: "26.0", hardware: "Mac16,7",
                          hasNotch: true, displayCount: 1,
                          permissions: permissions, hooks: hooks,
                          updater: updater, license: .trial(daysRemaining: 3),
                          widgets: [], secureInput: .off)
    }

    private func health(_ report: DiagnosticsReport) -> DiagnosticsHealth {
        DiagnosticsHealth.from(report)
    }

    // MARK: - The honest unknowns

    /// macOS exposes no way to read Automation without sending the request that
    /// raises the prompt. Nothing is broken, so nothing is amber.
    func testAsksOnFirstUseIsUnknownNotAFault() {
        let result = health(report(permissions: [.init("Automation", .asksOnFirstUse)]))
        XCTAssertEqual(result.rows.first?.severity, .unknown)
        XCTAssertNil(result.rows.first?.remedy, "there is nothing to go and fix")
        XCTAssertTrue(result.isHealthy)
    }

    /// Running from source. There is nothing to update, which is not the same
    /// as updates being broken.
    func testRunningFromSourceIsUnknownNotAFault() {
        let result = health(report(updater: .notBundled))
        XCTAssertEqual(result.rows.last?.severity, .unknown)
        XCTAssertTrue(result.isHealthy)
    }

    func testNotAskedIsUnknownToo() {
        let result = health(report(permissions: [.init("Microphone", .notAsked)]))
        XCTAssertEqual(result.rows.first?.severity, .unknown)
    }

    // MARK: - Real faults

    func testARefusedPermissionIsAFaultAndKnowsWhereTheFixIs() {
        let result = health(report(permissions: [.init("Accessibility", .notAllowed)]))
        XCTAssertEqual(result.rows.first?.severity, .fault)
        XCTAssertEqual(result.rows.first?.remedy, .permissionsSettings)
        XCTAssertFalse(result.isHealthy)
    }

    func testRestrictedIsAFault() {
        XCTAssertEqual(health(report(permissions: [.init("Microphone", .restricted)]))
            .rows.first?.severity, .fault)
    }

    /// A conflict is the hook fault: the config names us outside our managed
    /// block, so uninstall cannot find it and install would duplicate it.
    func testAHookConflictIsAFault() {
        let result = health(report(hooks: [.init("Claude Code", .conflict)]))
        XCTAssertEqual(result.rows.first?.severity, .fault)
        XCTAssertEqual(result.rows.first?.remedy, .agentsSettings)
    }

    /// A Codex nobody uses is a choice, not something to fix (X5).
    func testAnAgentNobodyConnectedIsNotAFault() {
        let result = health(report(hooks: [.init("Codex", .notInstalled)]))
        XCTAssertEqual(result.rows.first?.severity, .unknown)
        XCTAssertNil(result.rows.first?.remedy)
        XCTAssertTrue(result.isHealthy)
    }

    /// Switched on and still refused: the old approval from an earlier build.
    /// It used to read "allowed" while the dictation key was dead (X5).
    func testAnOldApprovalThatDoesNotWorkIsAFault() {
        let result = health(report(permissions: [.init("Input monitoring", .notWorking)]))
        XCTAssertEqual(result.rows.first?.severity, .fault)
        XCTAssertEqual(result.rows.first?.remedy, .permissionsSettings)
        XCTAssertEqual(result.rows.first?.detail, "on, but not working")
    }

    // MARK: - The summary sentence

    func testTheSummaryCountsItsReassurance() {
        XCTAssertEqual(DiagnosticsHealth(rows: []).healthySummary, "Everything checked out.")
        let one = health(report(permissions: [.init("Calendar", .notAsked)], updater: .configured(automaticChecks: true)))
        XCTAssertEqual(one.healthySummary, "Calendar: not asked. That is not a problem.")
        let two = health(report(permissions: [.init("Calendar", .notAsked)]))
        XCTAssertTrue(two.healthySummary.hasSuffix("Neither is a problem."), two.healthySummary)
        let three = health(report(permissions: [.init("Calendar", .notAsked)],
                                  hooks: [.init("Codex", .notInstalled)]))
        XCTAssertTrue(three.healthySummary.hasPrefix("Codex: not connected; "), three.healthySummary)
        XCTAssertTrue(three.healthySummary.hasSuffix("None of these is a problem."), three.healthySummary)
    }

    func testInstalledHooksAreAFact() {
        let result = health(report(hooks: [.init("Claude Code", .installed)]))
        XCTAssertEqual(result.rows.first?.severity, .fact)
        XCTAssertTrue(result.isHealthy)
    }

    // MARK: - The boring case

    /// The state the pane spends most of its life in, and the one it must not
    /// dramatise.
    func testAHealthyInstallReportsNoFaults() {
        let result = health(report(
            permissions: [.init("Microphone", .allowed), .init("Automation", .asksOnFirstUse)],
            hooks: [.init("Claude Code", .installed)],
            updater: .configured(automaticChecks: false)))
        XCTAssertTrue(result.isHealthy)
        XCTAssertTrue(result.faults.isEmpty)
        XCTAssertEqual(result.rows.count, 4, "every subsystem still gets a row")
    }

    func testFaultsAreOnlyTheAmberRows() {
        let result = health(report(
            permissions: [.init("Accessibility", .notAllowed),
                          .init("Automation", .asksOnFirstUse)],
            hooks: [.init("Claude Code", .installed)]))
        XCTAssertEqual(result.faults.map(\.title), ["Accessibility"])
    }
}
