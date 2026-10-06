import Foundation
import AirlockCore

/// Runs AppleScript **in-process** via `NSAppleScript`, so our app — which
/// carries the `com.apple.security.automation.apple-events` entitlement — is
/// the Apple-event source and TCC attributes the "wants to control X" grant to
/// us. Shelling out to `/usr/bin/osascript` breaks that: the subprocess sends
/// the event, not us, so under the hardened runtime the request is auto-denied
/// with no prompt (the bug that silently broke both Spotify and jump-back).
///
/// Runs on a dedicated serial queue: a first-use TCC prompt blocks that thread,
/// never the UI. Shared by the media widget and terminal jump-back.
enum AppleScriptClient {
    private static let queue = DispatchQueue(label: "com.agenticnotch.applescript")

    /// `errAEEventNotPermitted`, spelled out rather than imported: the constant
    /// lives in CoreServices' `MacErrors.h` and this file has no other reason
    /// to reach for it. It is the refusal TCC returns when the user has not
    /// allowed us to control the target app — the one refusal worth naming a
    /// permission for, as opposed to a script that is simply wrong.
    static let notPermitted = -1743

    /// What happened, as distinct from what came back.
    ///
    /// **`run` cannot tell those apart, and that is what this type is for.** It
    /// hands back nil for a script that was refused AND for a script that
    /// worked but had nothing to say — so a caller that needs to know whether
    /// the thing happened has to find out some other way. The appearance toggle
    /// used to find out by re-reading `NSApp.effectiveAppearance`, which AppKit
    /// updates a beat after the system setting changes; it therefore read the
    /// OLD value and blamed Automation for a press that had just worked.
    enum Outcome: Equatable {
        case ok(String?)
        case failed(code: Int)

        /// The user has not allowed Airlock to control the target app.
        var isNotPermitted: Bool { self == .failed(code: AppleScriptClient.notPermitted) }
    }

    /// The script's result, or nil if it did not run. Use `perform` when nil
    /// would be ambiguous.
    @discardableResult
    static func run(_ source: String) async -> String? {
        guard case .ok(let value) = await perform(source) else { return nil }
        return value
    }

    static func perform(_ source: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                // A source that will not even compile is a failure, not a
                // silent success — `run` reported it as nil, which read as
                // "worked, said nothing" to anyone checking the value.
                guard let script = NSAppleScript(source: source) else {
                    return continuation.resume(returning: .failed(code: 0))
                }
                var error: NSDictionary?
                let descriptor = script.executeAndReturnError(&error)
                if let error {
                    // Private: an AppleScript error quotes the script, and the
                    // scripts this sends name the user's terminal and session.
                    Log.app.error(
                        "applescript error \(String(describing: error["NSAppleScriptErrorBriefMessage"] ?? error), privacy: .private)")
                    let code = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
                    return continuation.resume(returning: .failed(code: code))
                }
                continuation.resume(returning: .ok(descriptor.stringValue))
            }
        }
    }
}
