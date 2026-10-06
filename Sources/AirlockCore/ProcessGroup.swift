import Foundation

/// Who a process's CPU belongs to, as the System panel's list names it.
///
/// The list answers "which apps are doing it", for someone who does not know
/// what a helper process is. So the unit is the thing they started, never the
/// process: Chrome's renderers, Spotify's helpers and the compilers Xcode runs
/// are one row each, under the name of the app they came from.
///
/// **Decided by the executable's path, and nothing else.** The path is the one
/// fact about a process that says what it is part of — a helper lives inside
/// its app's bundle, a simulator's daemons live inside the runtime, a compiler
/// lives inside Xcode's toolchain. The parent chain was the alternative, and it
/// answers a different question: it would credit every command-line program to
/// the terminal that launched it, and every XPC service to `launchd`.
///
/// Pure, so the rules are a table with fixtures rather than a guess made live.
public struct ProcessGroup: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// An app bundle, with everything inside it: helpers, extensions, and
        /// the command-line tools it ships.
        case app
        /// A program outside any bundle, named for itself.
        case program
        /// The iOS Simulator, as one thing — see `simulatorMarkers`.
        case simulator
        /// A macOS job from the short fixed set with a plain name.
        case system
    }

    public let kind: Kind
    /// What the row says.
    public let name: String
    /// The outermost `.app` a `.app` group's processes live in, so the panel
    /// can draw its icon. Not part of the identity — see `==`.
    public let bundlePath: String?

    public init(kind: Kind, name: String, bundlePath: String? = nil) {
        self.kind = kind
        self.name = name
        self.bundlePath = bundlePath
    }

    /// Stable across readings, which is what the list's ordering remembers.
    public var key: String { "\(kind.rawValue):\(name)" }

    public var description: String { key }

    /// Identity is the kind and the name, not the bundle path: two copies of
    /// one app are one row, not two rows with the same name in them.
    public static func == (lhs: ProcessGroup, rhs: ProcessGroup) -> Bool {
        lhs.kind == rhs.kind && lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(name)
    }

    /// The same group under a better name — the app layer swaps a bundle's file
    /// name for the one macOS shows, which only LaunchServices can read.
    public func renamed(_ newName: String) -> ProcessGroup {
        ProcessGroup(kind: kind, name: newName, bundlePath: bundlePath)
    }

    public static let simulator = ProcessGroup(kind: .simulator, name: "Simulator")
    public static let spotlight = ProcessGroup(kind: .system, name: "Spotlight")
    public static let virtualMachines = ProcessGroup(kind: .system, name: "Virtual machines")

    // MARK: - The rules

    /// Where the iOS Simulator keeps its processes. A booted device is a
    /// hundred-odd daemons out of its runtime image plus the host-side services
    /// that draw it, and the question the owner is asking — "is it the
    /// simulators?" — has one answer for all of them.
    ///
    /// `/Library/Developer/CoreSimulator/` covers both the mounted runtimes
    /// (`/Library/…/Volumes/iOS_…`) and apps installed into a device
    /// (`~/Library/Developer/CoreSimulator/Devices/…`). `Simulator.app` sits
    /// inside Xcode's bundle, and would otherwise be counted as Xcode.
    static let simulatorMarkers = [
        ".simruntime/",
        "/Library/Developer/CoreSimulator/",
        "/CoreSimulator.framework/",
        "/Simulator.app/",
    ]

    /// Spotlight's own frameworks. `mdworker_shared`, `mdbulkimport`,
    /// `corespotlightd` and the rest of the indexers the owner runs live in
    /// `Metadata.framework` or `CoreSpotlight.framework` and nowhere else, and
    /// "mdworker_shared" means nothing to someone whose Mac is indexing. (`mds`
    /// and `mds_stores` are Spotlight too, but they run as other users and
    /// land in the leftover line with the rest of macOS.)
    ///
    /// The fixed set is this and `virtualMachineMarkers`, and it stays that
    /// small on purpose. A plain name is only worth having when it is obviously
    /// right, and everything else keeps its process name — which is at least
    /// never wrong.
    static let spotlightMarkers = [
        "/Metadata.framework/",
        "/CoreSpotlight.framework/",
        "/Spotlight.app/",
    ]

    /// Apple's Virtualization framework, which runs each virtual machine on
    /// the Mac in an XPC service of its own — Docker's Linux VM among them.
    /// Measured with Docker running on the owner's Mac, `proc_pidpath` reads
    ///
    ///     /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/
    ///         com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
    ///
    /// and its parent is launchd, not Docker — so neither the path nor the
    /// parent chain can say whose VM it is, and the process name is not a row
    /// anyone should have to read. The framework's other services (installing
    /// a macOS VM, Rosetta for Linux, the VM's input) are the same machinery,
    /// and are named the same.
    static let virtualMachineMarkers = [
        "/Virtualization.framework/",
    ]

    /// The simulator's own `launchd`, the parent of everything in a device. Its
    /// path already matches `.simruntime/`; the name is for when the path is
    /// not there to read — measured, `proc_pidpath` refuses a process that has
    /// exited and not yet been reaped, and the short name is all that is left.
    static let simulatorProcessNames: Set<String> = ["launchd_sim"]

    /// The group a process belongs to, from its executable's path — `nil` when
    /// the path could not be read — and its short name, which stands in for it.
    public static func owner(path: String?, name: String) -> ProcessGroup {
        if simulatorProcessNames.contains(name) { return .simulator }
        guard let path, path.hasPrefix("/") else { return program(named: name) }
        if simulatorMarkers.contains(where: { path.contains($0) }) { return .simulator }
        if spotlightMarkers.contains(where: { path.contains($0) }) { return .spotlight }
        if virtualMachineMarkers.contains(where: { path.contains($0) }) { return .virtualMachines }
        if let bundle = outermostApp(in: path) {
            return ProcessGroup(kind: .app, name: bundle.name, bundlePath: bundle.path)
        }
        return program(named: programName(atPath: path) ?? name)
    }

    /// A program outside any bundle is named for its file — except a file
    /// named for its version. Claude Code's own installer keeps
    /// `~/.local/share/claude/versions/2.1.282` and runs exactly that, so the
    /// kernel's name for it is "2.1.282" too (measured: a process started
    /// through a symlink is named for the file the link points at). The folder
    /// that holds the versions is the program's name.
    static func programName(atPath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last else { return nil }
        guard isVersion(last) else { return last }
        for folder in components.dropLast().reversed()
        where !isVersion(folder) && !versionFolders.contains(folder.lowercased()) {
            return folder
        }
        return last
    }

    static let versionFolders: Set<String> = ["versions", "version", "bin", "current"]

    /// "2.1.282", "v20.11.1", "1.4.0-beta.2" — a leading run of digits and
    /// dots with at least one dot, and nothing but a suffix after it.
    static func isVersion(_ name: String) -> Bool {
        var core = Substring(name)
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        if let suffix = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = core[..<suffix] }
        guard let first = core.first, first.isASCII, first.isNumber, core.contains(".") else { return false }
        return core.allSatisfy { $0 == "." || ($0.isASCII && $0.isNumber) }
    }

    /// The OUTERMOST bundle, because helpers are apps too: Chrome's renderer is
    /// `Google Chrome Helper (Renderer).app` inside `Google Chrome.app`, and it
    /// is the outer one the owner started.
    static func outermostApp(in path: String) -> (name: String, path: String)? {
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            guard component.hasSuffix(".app") else { continue }
            let name = String(component.dropLast(4))
            guard !name.isEmpty else { continue }
            return (name, prefix)
        }
        return nil
    }

    private static func program(named name: String) -> ProcessGroup {
        ProcessGroup(kind: .program, name: name.isEmpty ? "?" : name)
    }
}
