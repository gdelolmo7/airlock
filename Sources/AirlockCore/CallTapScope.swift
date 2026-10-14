import Foundation

/// One of the call app's sound processes, as Core Audio lists it.
public struct CallAudioProcess: Equatable, Sendable {
    /// The process's Core Audio object, valid only while it lives.
    public var objectID: UInt32
    public var bundleID: String?

    public init(objectID: UInt32, bundleID: String?) {
        self.objectID = objectID
        self.bundleID = bundleID
    }
}

/// How the call-notes tap names the sound it listens to.
///
/// **By bundle ID when it is safe, by process otherwise.** Since macOS 26 a
/// tap can be described by bundle IDs and told to restore processes, and then
/// it follows a helper that quits and comes back under the same ID. That is
/// how a browser plays a call: from a hidden helper it swaps for another
/// whenever it likes, and a tap pinned to the first one goes quiet mid-call.
///
/// But a bundle ID names every process that carries it, in whatever app.
/// `com.github.Electron.helper` is shared by every Electron app that never
/// renamed its helpers, and `com.apple.WebKit.GPU` by every app with a web
/// view, so a tap described by those would write a song from another app into
/// the notes. So a tap is described by bundle ID only when every process has
/// one that is the call app's by its NAME: the app's own ID, one under it
/// after a dot (`com.google.Chrome.helper`), or one of FaceTime's call
/// daemons for FaceTime. One process that is not, and the whole tap names
/// processes instead, the way it always did. Mixing the two is not offered:
/// restore works by bundle ID, so it would bring a stranger's helper in under
/// the name of the process it replaced.
///
/// Never Airlock either way: the process-ID exclusion the process list relies
/// on means nothing to a tap that names bundle IDs, so a tap that would name
/// one of ours is a process-list tap.
public enum CallTapScope: Equatable, Sendable {
    /// Describe the tap by these bundle IDs, sorted, with restore on.
    case bundleIDs([String])
    /// Describe it by its processes; why it cannot be by bundle ID, for the log.
    case processes(why: String)

    public static func choose(callApp: String, processes: [CallAudioProcess],
                              ownBundleID: String?) -> CallTapScope {
        // The app's own ID too: should its main process start playing, the
        // tap already hears it and no rebuild is needed.
        var names: Set<String> = [callApp]
        for process in processes {
            guard let id = process.bundleID, !id.isEmpty else {
                return .processes(why: "a process has no bundle ID")
            }
            guard isNamed(id, after: callApp) else {
                return .processes(why: "\(id) is not named after \(callApp)")
            }
            names.insert(id)
        }
        let own = ownBundleID?.lowercased()
        if let ours = names.sorted().first(where: { NeverACall.matches($0) || $0.lowercased() == own }) {
            return .processes(why: "\(ours) is never a call")
        }
        return .bundleIDs(names.sorted())
    }

    /// The call app's by name, which is what makes a bundle ID safe to tap by.
    static func isNamed(_ id: String, after callApp: String) -> Bool {
        let lower = id.lowercased(), app = callApp.lowercased()
        return lower == app || lower.hasPrefix(app + ".")
            || CallDetector.callApp(forDaemon: id) == callApp
    }
}

/// What a running call-notes tap hears without being rebuilt, for deciding
/// when the call app has outgrown it.
public struct CallTapCoverage: Equatable, Sendable {
    /// The bundle IDs the tap follows on its own, as Core Audio reported them
    /// back; empty for a tap that names processes.
    public var bundleIDs: Set<String>
    /// The processes it was built with.
    public var processes: Set<UInt32>

    public init(bundleIDs: Set<String> = [], processes: Set<UInt32> = []) {
        self.bundleIDs = bundleIDs
        self.processes = processes
    }

    /// True when the app now has a process this tap cannot hear: one it was
    /// not built with, unless it carries a bundle ID the tap follows. For a
    /// process-list tap that is any new process, as before. For a bundle-ID
    /// tap it is a process under an ID it has never named (FaceTime's daemons
    /// handing the call over, a kind of helper the app had not started yet) or
    /// one with no ID at all. A process that went away is never a reason: it
    /// simply stops contributing, and a rebuild costs a moment of audio.
    ///
    /// IDs are compared exactly, not ignoring case, because that is the only
    /// match it is safe to assume Core Audio makes.
    public func isOutgrown(by now: [CallAudioProcess]) -> Bool {
        now.contains { process in
            guard !processes.contains(process.objectID) else { return false }
            guard let id = process.bundleID else { return true }
            return !bundleIDs.contains(id)
        }
    }
}
