import Foundation
import IOKit.pwr_mgt
import AirlockCore

/// Owner-only log of what a rail button did.
///
/// It exists because a press that does nothing leaves no trace anywhere on the
/// Mac. Pressed in anger and reported as "didn't work", four of the six could
/// be settled afterwards from the system's own records — the wake assertion
/// shows in `pmset -g assertions`, the appearance in the system setting, and a
/// screenshot refused for Screen Recording leaves a TCC denial. Two could not:
/// there was no display sleep in `pmset -g log` and no power request in
/// airportd's log, which is consistent both with a press that never reached
/// macOS and with one macOS ignored. Nothing here could tell those apart,
/// because the model kept a `failure` string for the panel and nothing else —
/// and that string is UI state the next press clears, so by the time anybody
/// asks it is gone.
///
/// So every press writes one line for the press and one for what came back:
/// the call that was made, and the code or status it returned. That is enough
/// to separate "Airlock never asked" from "macOS refused" without asking
/// anyone to reproduce anything.
///
/// **Shape, never content** — the same rule `DictationDiagnostics` follows.
/// A capture's destination is a file on the user's Desktop, so the kind of file
/// is recorded and the name is not; a network's name is never read here at all
/// (see `SystemControlsModel.signal`), and it is not read for this either.
/// Owner-only (0600) beside the other logs, and rotated rather than grown: a
/// diagnostic that eventually fills a disk is its own bug.
@MainActor
enum ControlDiagnostics {
    /// Same ceiling as `wave.log`: a few thousand presses, then it starts over.
    private static let sizeLimit = 64 * 1024

    /// Not private so that `OwnerLogsTests` checks this exact file.
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/controls.log")
    }

    /// `<time>  <control>  <what happened>`, which is the shape every other log
    /// in this app already has.
    static func line(_ control: SystemControlsModel.Control, _ message: String, at date: Date) -> String {
        "\(date.formatted(date: .omitted, time: .standard))  \(control.rawValue)  \(message)\n"
    }

    static func log(_ control: SystemControlsModel.Control, _ message: String) {
        // Private, for the same reason as everywhere else: these lines name
        // this Mac's interfaces and the state of its screen.
        Log.app.debug("controls: \(control.rawValue, privacy: .public) \(message, privacy: .private)")
        guard OwnerLogs.areOpen else { return }
        guard let data = line(control, message, at: Date()).data(using: .utf8) else { return }

        let manager = FileManager.default
        // The folder is made by whatever writes first, and on a fresh install
        // that can be this: a rail pressed before a session was ever cached.
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int, size > sizeLimit {
            try? manager.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: - Saying what came back

    /// An `IOReturn` as the system prints it, since that is what anyone looking
    /// it up will search for, plus the only thing a reader needs first: whether
    /// it worked.
    static func describe(ioReturn code: Int32) -> String {
        code == kIOReturnSuccess
            ? "kIOReturnSuccess"
            : "failed, \(String(format: "0x%08x", UInt32(bitPattern: code)))"
    }

    /// How a child process ended. A cancelled screenshot exits non-zero and so
    /// does a refused one, which is why the code is written down rather than
    /// summarised.
    static func describe(exitStatus: Int32, wasSignalled: Bool) -> String {
        wasSignalled ? "killed by signal \(exitStatus)" : "exited \(exitStatus)"
    }

    /// What AppleScript said, with the one code worth naming spelled out —
    /// see `AppleScriptClient.notPermitted`.
    static func describe(appleScript outcome: AppleScriptClient.Outcome) -> String {
        switch outcome {
        case .ok:
            return "ok"
        case .failed(let code):
            return code == AppleScriptClient.notPermitted
                ? "failed, code \(code) (Automation not permitted)"
                : "failed, code \(code)"
        }
    }

    /// The kind of file a capture was pointed at, and the folder in words —
    /// never the file's name, which is a date and the user's own.
    static func destination(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        return "~/\(folder)/*.\(ext.isEmpty ? "?" : ext)"
    }
}
