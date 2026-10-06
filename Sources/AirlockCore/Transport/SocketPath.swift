import Foundation

/// The stable per-user socket path under Application Support (0700 dir, 0600
/// socket). No `/tmp` fallback — the reference's world-traversable legacy path
/// was part of why its IPC channel was a soft target.
public enum SocketPath {
    /// Where every hook connects, and where the app listens outside a demo.
    public static func `default`() -> String {
        directory().appendingPathComponent("bridge.sock").path
    }

    /// Where the app listens. A demo gets a socket of its own, beside the real
    /// one.
    ///
    /// **Why a demo cannot share the real one.** The server unlinks whatever is
    /// at its path before binding, on purpose: that is how a relaunch takes over
    /// from its predecessor. So `AIRLOCK_DEMO=1 swift run AirlockApp`, started
    /// next to an installed Airlock, took the installed app's socket. Every hook
    /// from then on went to the demo instead, real permission gates included,
    /// and once the demo quit they went nowhere — while the installed app sat
    /// there looking healthy until it was restarted.
    ///
    /// **Moved, not switched off.** A demo without a bridge would differ from a
    /// real launch in a way that could hide a bug; this one binds and listens
    /// exactly like the app and differs only in this name. Nor is it a change to
    /// the server's unlink: newest-wins is right for the app itself, see
    /// `UnixSocketServer.stop()`.
    ///
    /// No hook ever connects here. The hook asks for `default()`, so an
    /// installed Airlock keeps receiving everything while a demo runs.
    public static func listening(demo: Bool) -> String {
        demo ? directory().appendingPathComponent("bridge-demo.sock").path : `default`()
    }

    private static func directory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Airlock")
    }
}
