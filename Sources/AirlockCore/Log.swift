import os

/// The app's unified-log channels, in one place.
///
/// **Why not stderr.** It is `/dev/null` in an `LSUIElement` bundle launched
/// with `open` — and `open` is the only supported way to launch this app, for
/// TCC reasons CLAUDE.md spells out. So every diagnostic written to stderr from
/// the app or from Core-running-inside-the-app is invisible in the shipping
/// product. That includes the ones gated behind `AIRLOCK_DEBUG`, which is the
/// worse half: turning debugging ON produced nothing at all, so the switch read
/// as broken rather than as absent.
///
/// **Why not NSLog.** It was tried and did not reach the unified log for this
/// process — `DictationModel`'s own note records that first-hand. `Logger` does;
/// `LicenseModel` has been using it since the licensing work.
///
/// Read it all with:
/// ```
/// log stream --predicate 'subsystem == "com.airlock.app"' --level debug
/// ```
///
/// **Privacy.** `os.Logger` already treats interpolations as private by default;
/// every call site here states it anyway, because a redaction that is invisible
/// at the call site is one somebody deletes without noticing. The rule:
///
/// - `.public` — counts, durations, booleans, our own enum cases, fixed
///   messages. Things that describe the app's behaviour.
/// - `.private` — session ids, file paths, commands, policy rule text, and any
///   error string that might carry one of those inside it.
///
/// The licence `ref` is never logged at any level, public or private: it can be
/// exchanged for a working licence, so the only safe amount is none.
///
/// The CLI targets (`airlock-hook`, `airlock-setup`, `LicenseTool`,
/// `PromptProbe`) keep writing to stderr, deliberately — they are run from a
/// terminal by someone watching, which is exactly the case stderr is for. The
/// hook additionally must never write to STDOUT, and this does not: the unified
/// log is a separate channel, so its fail-open contract is untouched.
public enum Log {
    private static let subsystem = "com.airlock.app"

    /// Socket, envelopes, gates.
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    /// Session state, liveness, persistence.
    public static let session = Logger(subsystem: subsystem, category: "session")
    /// Rule parsing and evaluation.
    public static let policy = Logger(subsystem: subsystem, category: "policy")
    /// Copying the old identity's state forward. Runs once, before anything else.
    public static let migration = Logger(subsystem: subsystem, category: "migration")
    /// Clipboard, tray, calendar, media — the non-agent widgets.
    public static let widgets = Logger(subsystem: subsystem, category: "widgets")
    /// The panel: geometry, hover, drop routing.
    public static let notch = Logger(subsystem: subsystem, category: "notch")
    /// App lifecycle, hook installation, updates.
    public static let app = Logger(subsystem: subsystem, category: "app")
}
