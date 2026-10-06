import XCTest
@testable import AirlockCore

final class DiagnosticsReportTests: XCTestCase {

    private func report(
        version: String = "v1.2.0 (34)",
        macOS: String = "15.3.1 (24D70)",
        hardware: String = "Mac16,7",
        hasNotch: Bool = true,
        displayCount: Int = 1,
        permissions: [DiagnosticsReport.Permission] = [.init("Calendar", .allowed)],
        hooks: [DiagnosticsReport.Hook] = [.init("Claude Code", .installed)],
        updater: DiagnosticsReport.UpdaterState = .configured(automaticChecks: false),
        license: DiagnosticsReport.LicenseState = .trial(daysRemaining: 9),
        widgets: [DiagnosticsReport.WidgetState] = [.init("Media", isEnabled: true)],
        secureInput: DiagnosticsReport.SecureInputState = .off
    ) -> DiagnosticsReport {
        DiagnosticsReport(version: version, macOS: macOS, hardware: hardware,
                          hasNotch: hasNotch, displayCount: displayCount,
                          permissions: permissions, hooks: hooks, updater: updater,
                          license: license, widgets: widgets, secureInput: secureInput)
    }

    // MARK: - Secure input

    /// The report is eight lines and the comment on the formatter says a ninth
    /// has to earn itself. This one earns it by not being there: secure input is
    /// off almost always, and a row for "off" would spend the line every time to
    /// say nothing.
    func testSecureInputOffAddsNoLine() {
        XCTAssertFalse(text(report()).contains("Secure input"))
    }

    /// And when it IS on, the paste has to name it — this is the state that
    /// makes a bare-modifier hold un-cancellable, and without the line a
    /// "dictation fired on its own" report is unattributable.
    func testSecureInputOnIsNamedInThePaste() {
        let line = text(report(secureInput: .on(holder: "Claude")))
        XCTAssertTrue(line.contains("Secure input"))
        XCTAssertTrue(line.contains("Claude"), "the holder is the actionable half")
        XCTAssertTrue(line.contains("key chords"), "and what it costs")
    }

    /// The holder cannot always be resolved. Saying so beats printing "on" and
    /// leaving the reader to guess whether we looked.
    func testUnidentifiedHolderSaysSo() {
        let line = text(report(secureInput: .on(holder: nil)))
        XCTAssertTrue(line.contains("Secure input"))
        XCTAssertTrue(line.contains("could not be identified"))
    }

    private func text(_ report: DiagnosticsReport) -> String {
        DiagnosticsFormatter.text(report)
    }

    // MARK: - Nothing secret

    /// The rule the whole type exists to keep. A licence carries an email, a
    /// vendor id and — worst — `ref`, which can be exchanged for a working
    /// licence. The state word is the only part that survives the trip.
    func testTheLicenceItselfNeverReachesThePage() {
        let license = License(id: "lic_9f3", email: "someone@example.com",
                              product: "airlock", period: .yearly,
                              issued: Date(timeIntervalSince1970: 1_800_000_000),
                              renewsAt: Date(timeIntervalSince1970: 1_830_000_000),
                              checkBy: Date(timeIntervalSince1970: 1_831_000_000),
                              ref: "ls_key_SECRET")
        let printed = text(report(license: .init(.licensed(license))))

        XCTAssertFalse(printed.contains("lic_9f3"))
        XCTAssertFalse(printed.contains("someone@example.com"))
        XCTAssertFalse(printed.contains("ls_key_SECRET"))
        XCTAssertTrue(printed.contains("Licence"))
        XCTAssertTrue(printed.contains("subscribed"))
    }

    /// A conflict message names the config file it found unmanaged entries in,
    /// and that path has a home directory in it. Settings shows it; this must
    /// not.
    func testAHookConflictLosesThePathItNames() {
        let status = HookInstallStatus.conflict(
            "unmanaged Airlock entries in /Users/rosa/.codex/config.toml")
        let printed = text(report(hooks: [.init("Codex", .init(status))]))

        XCTAssertFalse(printed.contains("/Users/rosa"))
        XCTAssertFalse(printed.contains("config.toml"))
        XCTAssertTrue(printed.contains("Codex conflict"))
    }

    // MARK: - Licence states

    func testEveryEntitlementHasAWordAndNoneOfThemIsBlank() {
        let license = License(id: "lic_1", email: "a@b.com", product: "airlock",
                              period: .monthly, issued: Date(), renewsAt: Date(),
                              checkBy: Date())
        let cases: [(Entitlement, DiagnosticsReport.LicenseState)] = [
            (.trialing(daysRemaining: 3), .trial(daysRemaining: 3)),
            (.trialExpired, .trialExpired),
            (.licensed(license), .subscribed),
            (.grace(license), .grace),
            (.overdue(license), .overdue),
        ]
        for (entitlement, expected) in cases {
            let state = DiagnosticsReport.LicenseState(entitlement)
            XCTAssertEqual(state, expected)
            XCTAssertFalse(state.label.isEmpty)
        }
    }

    /// One day left is a day, not "1 days left" — the report is read by people.
    func testTheLastDayOfATrialReadsAsOneDay() {
        XCTAssertEqual(DiagnosticsReport.LicenseState.trial(daysRemaining: 1).label,
                       "trial, 1 day left")
        XCTAssertEqual(DiagnosticsReport.LicenseState.trial(daysRemaining: 2).label,
                       "trial, 2 days left")
    }

    // MARK: - The three updater answers

    /// "Updates are broken" and "this build never had an update feed" are the
    /// same symptom, and telling them apart is most of the answer.
    func testUpdaterDistinguishesUnbuiltFromUnconfigured() {
        XCTAssertNotEqual(DiagnosticsReport.UpdaterState.notBundled.label,
                          DiagnosticsReport.UpdaterState.notConfigured.label)
        XCTAssertTrue(DiagnosticsReport.UpdaterState.configured(automaticChecks: true)
            .label.contains("on"))
        XCTAssertTrue(DiagnosticsReport.UpdaterState.configured(automaticChecks: false)
            .label.contains("off"))
    }

    // MARK: - The machine

    func testOneDisplayIsSingularAndTheNotchIsStated() {
        XCTAssertTrue(text(report(hasNotch: true, displayCount: 1))
            .contains("Mac16,7 · notch yes · 1 display"))
        XCTAssertTrue(text(report(hasNotch: false, displayCount: 2))
            .contains("notch no · 2 displays"))
    }

    // MARK: - Widgets

    func testWidgetsListTheEnabledOnesAndGatherTheRest() {
        let line = text(report(widgets: [
            .init("Media", isEnabled: true),
            .init("Sound", isEnabled: false),
            .init("Calendar", isEnabled: true),
            .init("Battery", isEnabled: false),
        ]))
        XCTAssertTrue(line.contains("Media, Calendar · off: Sound, Battery"))
    }

    /// Everything switched off is a state worth seeing rather than an empty
    /// space that reads as a bug in the report.
    func testEverythingOffSaysSo() {
        let line = text(report(widgets: [
            .init("Media", isEnabled: false),
            .init("Sound", isEnabled: false),
        ]))
        XCTAssertTrue(line.contains("none on · off: Media, Sound"))
    }

    func testEverythingOnNamesThemWithNoEmptyOffList() {
        let line = text(report(widgets: [
            .init("Media", isEnabled: true),
            .init("Sound", isEnabled: true),
        ]))
        XCTAssertTrue(line.contains("Widgets") && line.contains("Media, Sound"))
        XCTAssertFalse(line.contains("off:"))
    }

    // MARK: - Shape

    /// Short enough to paste into an issue without a fold. The count is the
    /// constraint, so it is the thing asserted — a tenth line has to be argued
    /// for here before it can be added.
    func testTheWholeReportIsNineLines() {
        let lines = text(report()).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(String(lines[0]), DiagnosticsFormatter.header)
    }

    func testLabelsAreAlignedSoValuesReadAsAColumn() {
        let lines = text(report()).split(separator: "\n").dropFirst()
        let valueStarts = Set(lines.map { line -> Int in
            // Label, then padding, then the separator — one unbroken run of
            // spaces however long the label was. The value starts where it ends.
            let afterIndent = String(line.drop(while: { $0 == " " }))
            let afterLabel = String(afterIndent.drop(while: { $0 != " " }))
            let value = String(afterLabel.drop(while: { $0 == " " }))  // padding + separator
            return line.count - value.count
        })
        XCTAssertEqual(valueStarts.count, 1, "labels pad to a single column")
    }

    /// Every permission carries its own answer, including the two macOS will
    /// not tell us about without asking.
    func testPermissionsPrintTheirOwnState() {
        let printed = text(report(permissions: [
            .init("Calendar", .allowed),
            .init("Microphone", .notAsked),
            .init("Accessibility", .notAllowed),
            .init("Automation", .asksOnFirstUse),
        ]))
        XCTAssertTrue(printed.contains("Calendar allowed"))
        XCTAssertTrue(printed.contains("Microphone not asked"))
        XCTAssertTrue(printed.contains("Accessibility not allowed"))
        XCTAssertTrue(printed.contains("Automation asks on first use"))
    }

    func testNothingInstalledStillPrintsARow() {
        XCTAssertTrue(text(report(hooks: [])).contains("Hooks"))
        XCTAssertTrue(text(report(hooks: [])).contains("none"))
    }
}
