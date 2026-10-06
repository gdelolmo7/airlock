import AirlockCore
import AppKit
import Carbon.HIToolbox
import IOKit

/// Whether another app has secure event input switched on, and which one.
///
/// **Why this is worth a file.** Secure input is how a password field stops a
/// keylogger, and it works by having macOS withhold key events from every
/// `CGEventTap` in the session — including ours. `HoldKeyMonitor` uses a tap to
/// notice the second key of a chord, which is the whole mechanism by which ⌥⌫
/// stops being a dictation hold and goes back to being "delete a word". With
/// secure input on, that mechanism is not degraded, it is absent: no event, no
/// callback, no cancellation, and no error anywhere to say so.
///
/// The symptom is the panel opening while somebody edits text, which reads as an
/// Airlock bug and is not one. It was diagnosed from an asymmetry in the log —
/// key-press cancellations had fired once in the app's whole history, while the
/// modifier-based ones, which secure input does NOT suppress, had fired eight
/// times.
///
/// Read-only, and nothing here can turn it on or off. `IsSecureEventInputEnabled`
/// is a plain Carbon predicate; the holder comes out of the IO registry, which is
/// the same place `pmset` and Activity Monitor read it from.
@MainActor
enum SecureInput {
    /// The predicate itself. Cheap enough to ask on every hold.
    static var isEnabled: Bool { IsSecureEventInputEnabled() }

    static func state() -> DiagnosticsReport.SecureInputState {
        guard isEnabled else { return .off }
        return .on(holder: holderName())
    }

    /// The app that turned it on, when it can be resolved.
    ///
    /// Nil is a real answer rather than a failure: the holder may have exited
    /// between the two reads, and a process id we cannot name is worse than
    /// nothing in a report somebody is going to read.
    static func holderName() -> String? {
        guard let pid = holderPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// `IOConsoleUsers` hangs off the registry ROOT, not off a path under
    /// `IOService:`.
    ///
    /// Written first as `IORegistryEntryFromPath(_, "IOService:/IOResources/IOConsoleUsers")`,
    /// which returns 0 — and 0 here is indistinguishable from "nothing holds
    /// secure input", so the report would have said "an app that could not be
    /// identified" forever while looking like it had checked. Verified against
    /// the live registry rather than assumed.
    private static func holderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        // One session in practice, but the key is per-session and a zero means
        // "nobody", not "this session has no secure input".
        //
        // `as? Int`, never `as? pid_t`: the value arrives as an `NSNumber`, and
        // bridging one straight to `Int32` fails — silently, and back to
        // "unidentified" again.
        for session in sessions {
            if let pid = session["kCGSSessionSecureInputPID"] as? Int, pid != 0 {
                return pid_t(pid)
            }
        }
        return nil
    }
}
