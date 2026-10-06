import Synchronization

/// Whether this process may write the owner's diagnostic logs: `dictation.log`,
/// `controls.log`, `wave.log`, `appvolume.log`, `hover.log` and
/// `guide-looks.jsonl`, in
/// `~/Library/Application Support/Airlock/`.
///
/// Only the app itself may. The test bundle links all of this module, and its
/// models log exactly as the app's do: every `swift test` appended 21 lines to
/// the owner's `dictation.log` ("commandBar hotkey ⌥Space → registered",
/// "apps: 91 installed, 0 localized names, …"), and those lines cannot be told
/// apart from the app's own. That file is the one that survives a crash, and
/// it is read afterwards to decide whether a crash fix worked. It is also
/// capped at 256 KB, so every run pushed out real lines too.
///
/// **Shut by default and opened by the app. Tests are not asked to shut it.**
/// An opt-out that every test has to remember is one the next test forgets.
/// So the gate starts shut in every process, and the only thing that opens it
/// is `AgenticNotchMain.main()`, which the test bundle never runs. Opening it
/// takes an `AgenticNotchMain.Launch`, which only `App.swift` can make. A test
/// that tries to open it does not compile.
///
/// `main()` opens it before doing anything else, so no line is lost to a gate
/// that opens late. Nothing in this module runs before `main()`, and the
/// launch lines (`start enabled=…`, `holdMonitor tap health: …`) come later,
/// from the app delegate.
///
/// It gates the files only. The unified-log lines written next to them are
/// unchanged, and so is everything about the files in the app.
enum OwnerLogs {
    /// Set once, by `main()`, before anything that logs has started. Nothing
    /// else is published through it, so relaxed ordering is enough.
    private static let gate = Atomic<Bool>(false)

    static var areOpen: Bool { gate.load(ordering: .relaxed) }

    static func open(_: AgenticNotchMain.Launch) {
        gate.store(true, ordering: .relaxed)
    }
}
