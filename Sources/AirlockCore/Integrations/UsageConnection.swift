import Foundation

/// Whether Claude's status line still carries Airlock's usage bridge, and
/// putting it back when it does not.
///
/// **The 5h/7d figures reach Airlock through exactly one channel.** Claude
/// renders its status line by running a command, and Airlock's is
/// `airlock-hook --statusline`: it caches the `rate_limits` Claude hands it and
/// then runs whatever command was there before (`--chain-b64`), so the user's
/// own status line looks exactly as it did. There is no second source — the
/// desktop app never reports usage at all.
///
/// Claude keeps ONE status line, so any other tool that writes that setting
/// takes the channel away, and nothing here noticed. Found on a real Mac: the
/// status line was a third-party script on its own, the usage cache had never
/// been written, and Settings went on offering a "Claude usage limits" switch
/// for a feature that could not work. The launch path could not fix it either —
/// it re-pointed the status line only when the command was ALREADY ours and
/// still named the pre-rename binary.
///
/// So this compares two facts — are Airlock's Claude hooks installed, and is
/// the status line ours — and makes the file match what the user asked for.
/// It never installs hooks: a Mac that never invited Airlock into Claude's
/// settings is not one to start writing to.
public struct UsageConnection: Sendable {
    /// What the settings file says right now.
    public enum State: Sendable, Equatable {
        /// The status line runs our bridge, so the figures can update.
        case connected
        /// Somebody else's status line, or none at all: nothing will update them.
        case replaced
        /// Claude's hooks are not installed, so there is nothing of ours here
        /// and this is not ours to put back.
        case hooksMissing
    }

    /// What a sync did, for the log and for the pane that offered it.
    public enum Change: Sendable, Equatable {
        case none
        case connected
        case disconnected
        case failed(String)
    }

    private let statusLine: ClaudeStatusLineInstaller
    private let hooks: ClaudeHookInstaller

    /// One settings file, read two ways — the hooks and the status line live in
    /// the same `~/.claude/settings.json`.
    public init(settingsURL: URL? = nil) {
        statusLine = ClaudeStatusLineInstaller(configURL: settingsURL)
        hooks = ClaudeHookInstaller(configURL: settingsURL)
    }

    /// Reads the settings file, so it belongs at launch or on an explicit
    /// refresh — never inside a SwiftUI body.
    public func state() -> State {
        guard hooks.status() == .installed else { return .hooksMissing }
        return statusLine.isInstalled() ? .connected : .replaced
    }

    /// Make the file match `wantsUsage`, and say what that took.
    ///
    /// Idempotent both ways: with the figures on and the bridge already ours,
    /// or off and the status line already somebody else's, nothing is written.
    /// Never throws — this runs at launch, where a settings file that cannot be
    /// read or written costs the figures and nothing else.
    ///
    /// Turning the figures off **unchains**, rather than leaving a bridge
    /// nobody reads: the captured command goes back verbatim, exactly as
    /// uninstalling does. And because the switch is what is read here, the next
    /// launch does not put it back.
    @discardableResult
    public func sync(wantsUsage: Bool, bridgeBinaryPath: String?) -> Change {
        guard hooks.status() == .installed else { return .none }
        do {
            switch (wantsUsage, statusLine.isInstalled()) {
            case (true, false):
                guard let bridgeBinaryPath else {
                    return .failed("Airlock can't find its hook binary.")
                }
                try statusLine.install(bridgeBinaryPath: bridgeBinaryPath)
                return .connected
            case (false, true):
                try statusLine.uninstall()
                return .disconnected
            default:
                return .none
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
