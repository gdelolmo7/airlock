import XCTest
@testable import AirlockCore

/// The list names what the owner started, not what the kernel scheduled. These
/// are the paths it has to get right, taken from a Mac running a UI-test build,
/// three simulators and Spotlight.
final class ProcessGroupTests: XCTestCase {

    private func owner(_ path: String?, name: String = "") -> ProcessGroup {
        ProcessGroup.owner(path: path, name: name.isEmpty ? ((path ?? "") as NSString).lastPathComponent : name)
    }

    // MARK: - Helpers count toward their app

    func testAChromeRendererIsChrome() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
            + "Versions/140.0.7339.81/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/"
            + "Google Chrome Helper (Renderer)"
        let group = owner(path)
        XCTAssertEqual(group, ProcessGroup(kind: .app, name: "Google Chrome"))
        XCTAssertEqual(group.bundlePath, "/Applications/Google Chrome.app")
    }

    func testASpotifyHelperIsSpotify() {
        let group = owner("/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/Spotify Helper")
        XCTAssertEqual(group, ProcessGroup(kind: .app, name: "Spotify"))
        XCTAssertEqual(group.bundlePath, "/Applications/Spotify.app")
    }

    func testAClaudeHelperIsClaude() {
        let group = owner("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper")
        XCTAssertEqual(group, ProcessGroup(kind: .app, name: "Claude"))
    }

    func testTheMainExecutableAndItsHelpersAreOneRow() {
        let main = owner("/Applications/Claude.app/Contents/MacOS/Claude")
        let helper = owner("/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)")
        let crashpad = owner("/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler")
        XCTAssertEqual(main, helper)
        XCTAssertEqual(main, crashpad)
        XCTAssertEqual(Set([main, helper, crashpad]).count, 1)
    }

    // MARK: - A program inside an app bundle counts toward that app

    func testXcodebuildIsXcode() {
        XCTAssertEqual(owner("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"),
                       ProcessGroup(kind: .app, name: "Xcode"))
    }

    func testTheCompilerInXcodesToolchainIsXcode() {
        let path = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
        XCTAssertEqual(owner(path), ProcessGroup(kind: .app, name: "Xcode"))
    }

    /// A second Xcode is still Xcode — one row, whichever copy the build used.
    func testTheBundlesFileNameIsTheName() {
        let beta = owner("/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild")
        XCTAssertEqual(beta.name, "Xcode-beta")
        XCTAssertEqual(beta.kind, .app)
    }

    // MARK: - The iOS Simulator is one thing

    func testADaemonInsideASimulatorRuntimeIsTheSimulator() {
        let path = "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/"
            + "Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/trustd"
        XCTAssertEqual(owner(path), .simulator)
    }

    func testTheHostSideRendererIsTheSimulator() {
        let path = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/"
            + "SimRenderingServices.simdeviceio/Contents/XPCServices/SimMetalHost.xpc/Contents/MacOS/SimMetalHost"
        XCTAssertEqual(owner(path), .simulator)
    }

    func testTheSimulatorsLaunchdIsTheSimulatorWithOrWithoutAPath() {
        XCTAssertEqual(ProcessGroup.owner(path: nil, name: "launchd_sim"), .simulator)
        let path = "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/"
            + "Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim"
        XCTAssertEqual(owner(path), .simulator)
    }

    /// Simulator.app lives inside Xcode's bundle, and is still the Simulator.
    func testSimulatorAppInsideXcodeIsTheSimulatorNotXcode() {
        let path = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
        XCTAssertEqual(owner(path), .simulator)
    }

    /// An app installed into a simulated device is part of the simulator, not
    /// an app of the owner's Mac.
    func testAnAppRunningInsideADeviceIsTheSimulator() {
        let path = "/Users/someone/Library/Developer/CoreSimulator/Devices/5A1D/data/Containers/Bundle/"
            + "Application/9F2C/Airlock.app/Airlock"
        XCTAssertEqual(owner(path), .simulator)
    }

    // MARK: - The short fixed set of plain names

    func testSpotlightsWorkerIsSpotlight() {
        let path = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/"
            + "Versions/A/Support/mdworker_shared"
        XCTAssertEqual(owner(path), .spotlight)
        XCTAssertEqual(ProcessGroup.spotlight.name, "Spotlight")
    }

    func testSpotlightsOtherIndexersAreSpotlight() {
        let support = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/"
        for tool in ["corespotlightd", "mdbulkimport", "mdworker"] {
            XCTAssertEqual(owner(support + tool), .spotlight, tool)
        }
        XCTAssertEqual(owner("/System/Library/Frameworks/CoreSpotlight.framework/spotlightknowledged"), .spotlight)
        XCTAssertEqual(owner("/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"), .spotlight)
    }

    /// Read with `proc_pidpath` on the owner's Mac while Docker Desktop ran its
    /// Linux VM: a service of the system framework, run by launchd, with
    /// nothing in the path to say it is Docker's.
    func testAVirtualMachineIsVirtualMachines() {
        let path = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
            + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        XCTAssertEqual(owner(path), .virtualMachines)
        XCTAssertEqual(ProcessGroup.virtualMachines.name, "Virtual machines")
        XCTAssertEqual(ProcessGroup.virtualMachines.kind, .system)
    }

    /// The framework's other services are the same machinery. Docker's own
    /// processes are not the VM, and stay Docker.
    func testTheRestOfTheFrameworkIsVirtualMachinesAndDockerIsDocker() {
        let services = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
        let rosetta = services + "com.apple.Virtualization.LinuxRosetta.xpc/Contents/MacOS/com.apple.Virtualization.LinuxRosetta"
        XCTAssertEqual(owner(rosetta), .virtualMachines)
        XCTAssertEqual(owner("/Applications/Docker.app/Contents/MacOS/com.docker.virtualization"),
                       ProcessGroup(kind: .app, name: "Docker"))
    }

    /// A simulated device's own Spotlight is part of the simulator.
    func testASimulatedDevicesSpotlightIsTheSimulator() {
        let path = "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/"
            + "Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/Applications/Spotlight.app/Spotlight"
        XCTAssertEqual(owner(path), .simulator)
    }

    // MARK: - Programs are named for themselves

    /// The terminal does not get the credit for what runs inside it.
    func testACommandLineProgramIsNamedForItselfNotItsTerminal() {
        XCTAssertEqual(owner("/opt/homebrew/bin/node"), ProcessGroup(kind: .program, name: "node"))
        XCTAssertEqual(owner("/bin/zsh"), ProcessGroup(kind: .program, name: "zsh"))
        XCTAssertNil(owner("/opt/homebrew/bin/node").bundlePath)
    }

    func testSeveralProcessesOfOneProgramAreOneGroup() {
        let a = owner("/usr/bin/awk"), b = owner("/usr/bin/awk")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testAnUnknownMacOSJobKeepsItsProcessName() {
        XCTAssertEqual(owner("/usr/libexec/trustd"), ProcessGroup(kind: .program, name: "trustd"))
        XCTAssertEqual(owner("/usr/sbin/cfprefsd"), ProcessGroup(kind: .program, name: "cfprefsd"))
    }

    /// Claude Code's installer runs a file named for its version. "2.1.282"
    /// on a row would mean nothing.
    func testAProgramFileNamedForItsVersionIsNamedForItsFolder() {
        XCTAssertEqual(owner("/Users/someone/.local/share/claude/versions/2.1.282"),
                       ProcessGroup(kind: .program, name: "claude"))
        XCTAssertEqual(owner("/Users/someone/.tools/deno/v2.4.1/bin/2.4.1").name, "deno")
    }

    func testOnlyAVersionLooksLikeOne() {
        for version in ["2.1.282", "v20.11.1", "1.4.0-beta.2", "3.11", "V1.0+build"] {
            XCTAssertTrue(ProcessGroup.isVersion(version), version)
        }
        for name in ["python3.11", "7z", "node", "2", ".1", "x1.2", "1.2a", ""] {
            XCTAssertFalse(ProcessGroup.isVersion(name), name)
        }
    }

    /// Without a path — a process that has exited and not been reaped — the
    /// short name is all there is, and it is used rather than dropped.
    func testNoPathFallsBackToTheShortName() {
        XCTAssertEqual(ProcessGroup.owner(path: nil, name: "swift-frontend"),
                       ProcessGroup(kind: .program, name: "swift-frontend"))
        XCTAssertEqual(ProcessGroup.owner(path: "", name: "cc1"), ProcessGroup(kind: .program, name: "cc1"))
        XCTAssertEqual(ProcessGroup.owner(path: nil, name: ""), ProcessGroup(kind: .program, name: "?"))
    }

    // MARK: - Airlock is an app like any other

    func testAirlockAppearsLikeAnyOtherApp() {
        XCTAssertEqual(owner("/Applications/Airlock.app/Contents/MacOS/Airlock"),
                       ProcessGroup(kind: .app, name: "Airlock"))
        XCTAssertEqual(owner("/Applications/Airlock.app/Contents/MacOS/airlock-hook"),
                       ProcessGroup(kind: .app, name: "Airlock"))
    }

    // MARK: - Identity

    /// Two copies of one app are one row; the path is only for the icon.
    func testIdentityIsKindAndNameNotBundlePath() {
        let installed = ProcessGroup(kind: .app, name: "Xcode", bundlePath: "/Applications/Xcode.app")
        let elsewhere = ProcessGroup(kind: .app, name: "Xcode", bundlePath: "/Volumes/Tools/Xcode.app")
        XCTAssertEqual(installed, elsewhere)
        XCTAssertEqual(Set([installed, elsewhere]).count, 1)
        XCTAssertNotEqual(ProcessGroup(kind: .app, name: "zsh"), ProcessGroup(kind: .program, name: "zsh"))
    }

    func testRenamingKeepsKindAndIcon() {
        let group = owner("/Applications/Xcode.app/Contents/MacOS/Xcode").renamed("Xcode 26")
        XCTAssertEqual(group.kind, .app)
        XCTAssertEqual(group.name, "Xcode 26")
        XCTAssertEqual(group.bundlePath, "/Applications/Xcode.app")
    }
}
