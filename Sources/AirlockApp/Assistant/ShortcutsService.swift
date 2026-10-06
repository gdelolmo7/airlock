import Foundation
import AirlockCore

/// The two things Airlock asks of the Shortcuts CLI: what exists, and run one.
///
/// Stateless and free-standing so `AssistantModel` can hold a cached list
/// without also holding a process. Both members fail silently to a safe value —
/// an empty library, or false — because every failure here has the same honest
/// meaning: we could not find out, so propose nothing.
///
/// **`/usr/bin/shortcuts` and not the `shortcuts://` URL scheme.** The URL
/// scheme works under App Sandbox and this does not, which would matter if
/// Airlock were sandboxed; it is not, and says why in
/// `Configuration/airlock.entitlements`. What the CLI buys is the half the URL
/// scheme cannot do at all: `shortcuts list` enumerates the library, and
/// enumeration is what lets `VoiceShortcutAction.propose` refuse a name that
/// does not exist. Without it every misheard word would become a card for a
/// Shortcut that was never there.
enum ShortcutsService {

    /// Where the CLI lives. A constant rather than a `which` lookup: this is a
    /// system binary at a fixed path, and searching `PATH` in a GUI app finds a
    /// different `PATH` than the one the user has in their shell anyway.
    private static let executable = "/usr/bin/shortcuts"

    /// Every Shortcut the user has, by name. Empty on any failure.
    ///
    /// `nonisolated` and `async` so the caller hops off the main actor: this
    /// spawns a process and reads a pipe, and a library of a few hundred takes
    /// long enough that doing it inline would be felt as the notch hesitating.
    nonisolated static func names(timeout: TimeInterval = 5) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            guard let output = run(arguments: ["list"], timeout: timeout) else { return [] }
            return output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.value
    }

    /// Start a Shortcut. True means STARTED — see `VoicePerformer.runShortcut`.
    ///
    /// Deliberately does not wait: a Shortcut may take minutes, and blocking the
    /// main actor on one would freeze the notch. The card has already been
    /// approved by the time this runs, so there is nothing left on screen for a
    /// later exit code to correct.
    @discardableResult
    static func launch(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Passed as an argv element, never interpolated into a shell command —
        // a Shortcut is named by its author and "Back up; rm -rf ~" is a legal
        // name. There is no shell here for it to reach.
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            Log.widgets.error("shortcuts run failed to start — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Run the CLI and return stdout, or nil on any failure.
    ///
    /// The timeout shape is `ProcessSnapshot.capture`'s, deliberately: killing
    /// the process closes the pipe, which is what actually unblocks the read —
    /// so this bounds both waits and not just `waitUntilExit`.
    private static func run(arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

        // `readToEnd()` throws where `readDataToEndOfFile()` raised an
        // Objective-C exception, which Swift cannot catch. This runs inside
        // `names`' `Task.detached`, where an exception does worse than end the
        // process: unwinding through a Swift job corrupts the concurrency
        // runtime's state for that thread, so the crash lands later in
        // unrelated code — how 1.0.12 died from AVFAudio. A read error is now
        // one more "could not find out".
        let data: Data?
        do {
            data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            data = nil
        }
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationStatus == 0, let data else { return nil }
        // `String(decoding:)` rather than the failable initialiser: one
        // non-UTF-8 byte in one Shortcut's name must not discard the library.
        return String(decoding: data, as: UTF8.self)
    }
}
