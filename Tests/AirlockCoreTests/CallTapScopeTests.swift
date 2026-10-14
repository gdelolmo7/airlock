import XCTest
@testable import AirlockCore

final class CallTapScopeTests: XCTestCase {
    private let chrome = "com.google.Chrome"

    private func process(_ id: UInt32, _ bundleID: String?) -> CallAudioProcess {
        CallAudioProcess(objectID: id, bundleID: bundleID)
    }

    // MARK: - Choosing

    func testABrowsersOwnHelpersAreTappedByBundleID() {
        let scope = CallTapScope.choose(
            callApp: chrome,
            processes: [process(1, "com.google.Chrome.helper"), process(2, "com.google.Chrome.helper")],
            ownBundleID: "com.airlock.app")
        XCTAssertEqual(scope, .bundleIDs(["com.google.Chrome", "com.google.Chrome.helper"]),
                       "the app's own ID too, so its main process is heard without a rebuild")
    }

    func testFaceTimesDaemonsAreTappedByBundleID() {
        let scope = CallTapScope.choose(
            callApp: CallDetector.faceTime,
            processes: [process(1, "com.apple.avconferenced"),
                        process(2, "com.apple.TelephonyUtilities.callservicesd")],
            ownBundleID: "com.airlock.app")
        XCTAssertEqual(scope, .bundleIDs(["com.apple.FaceTime", "com.apple.TelephonyUtilities.callservicesd",
                                          "com.apple.avconferenced"]))
    }

    func testASharedHelperIDKeepsTheProcessList() {
        // Every Electron app that never renamed its helpers plays from this ID;
        // a tap described by it would hear all of them.
        let scope = CallTapScope.choose(
            callApp: "com.tinyspeck.slackmacgap",
            processes: [process(1, "com.tinyspeck.slackmacgap"), process(2, "com.github.Electron.helper")],
            ownBundleID: "com.airlock.app")
        guard case .processes(let why) = scope else { return XCTFail("expected a process-list tap") }
        XCTAssertTrue(why.contains("com.github.Electron.helper"), why)
    }

    func testAWebViewHelperKeepsTheProcessList() {
        // Safari's sound comes from a WebKit process every web view shares.
        let scope = CallTapScope.choose(
            callApp: "com.apple.Safari",
            processes: [process(1, "com.apple.WebKit.GPU")],
            ownBundleID: "com.airlock.app")
        guard case .processes = scope else { return XCTFail("expected a process-list tap") }
    }

    func testAProcessWithNoBundleIDKeepsTheProcessList() {
        for missing in [nil, ""] as [String?] {
            let scope = CallTapScope.choose(
                callApp: chrome,
                processes: [process(1, "com.google.Chrome.helper"), process(2, missing)],
                ownBundleID: "com.airlock.app")
            guard case .processes = scope else { return XCTFail("expected a process-list tap") }
        }
    }

    func testOnlyADotMakesAnIDTheAppsOwn() {
        let scope = CallTapScope.choose(
            callApp: chrome,
            processes: [process(1, "com.google.ChromeRemoteDesktop")],
            ownBundleID: "com.airlock.app")
        guard case .processes = scope else { return XCTFail("expected a process-list tap") }
    }

    func testNamingIgnoresCaseButKeepsTheSpellingCoreAudioGave() {
        let scope = CallTapScope.choose(
            callApp: chrome,
            processes: [process(1, "com.google.chrome.Helper")],
            ownBundleID: "com.airlock.app")
        XCTAssertEqual(scope, .bundleIDs(["com.google.Chrome", "com.google.chrome.Helper"]))
    }

    func testNeverAirlock() {
        // A call app under Airlock's own name can only be a test copy, but a
        // bundle-ID tap must never be able to name it.
        let ours = CallTapScope.choose(
            callApp: "com.airlock.app",
            processes: [process(1, "com.airlock.app")],
            ownBundleID: "com.airlock.app")
        guard case .processes = ours else { return XCTFail("expected a process-list tap") }

        let preview = CallTapScope.choose(
            callApp: "com.example.preview",
            processes: [process(1, "com.example.preview")],
            ownBundleID: "com.example.preview")
        guard case .processes = preview else { return XCTFail("our own ID, whatever it is, is never named") }
    }

    func testTheListIsSortedWithNoRepeats() {
        let scope = CallTapScope.choose(
            callApp: chrome,
            processes: [process(3, "com.google.Chrome.helper.renderer"),
                        process(1, "com.google.Chrome.helper"),
                        process(2, "com.google.Chrome.helper"),
                        process(4, "com.google.Chrome")],
            ownBundleID: nil)
        XCTAssertEqual(scope, .bundleIDs(["com.google.Chrome", "com.google.Chrome.helper",
                                          "com.google.Chrome.helper.renderer"]))
    }

    // MARK: - When the tap is outgrown

    func testAProcessListTapIsOutgrownByAnyNewProcess() {
        let coverage = CallTapCoverage(processes: [1, 2])
        XCTAssertFalse(coverage.isOutgrown(by: [process(1, "com.google.Chrome.helper")]),
                       "one going away is not a reason to rebuild")
        XCTAssertFalse(coverage.isOutgrown(by: []))
        XCTAssertTrue(coverage.isOutgrown(by: [process(1, nil), process(3, "com.google.Chrome.helper")]))
    }

    func testABundleIDTapFollowsANewHelperOnItsOwn() {
        let coverage = CallTapCoverage(bundleIDs: ["com.google.Chrome", "com.google.Chrome.helper"],
                                       processes: [1])
        XCTAssertFalse(coverage.isOutgrown(by: [process(7, "com.google.Chrome.helper")]),
                       "the helper the browser swapped in is already heard")
        XCTAssertFalse(coverage.isOutgrown(by: [process(8, "com.google.Chrome")]))
    }

    func testABundleIDTapIsOutgrownByAnIDItNeverNamed() {
        let coverage = CallTapCoverage(bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"],
                                       processes: [1])
        XCTAssertTrue(coverage.isOutgrown(by: [process(1, "com.apple.avconferenced"),
                                               process(2, "com.apple.TelephonyUtilities.callservicesd")]),
                      "the call handed to another daemon")
        XCTAssertTrue(coverage.isOutgrown(by: [process(3, nil)]), "a process with no ID cannot be followed")
        XCTAssertTrue(coverage.isOutgrown(by: [process(4, "com.apple.FACETIME")]),
                      "compared exactly: a different spelling might not be followed")
    }
}
