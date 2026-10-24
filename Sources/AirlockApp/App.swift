import AirlockCore
import AppKit

@main
enum AgenticNotchMain {
    /// Proof that the caller is the app's own launch. Only this file can make
    /// one. A test can reach everything else in the module, so without this it
    /// could switch the owner's logs on (see `OwnerLogs`).
    struct Launch {
        fileprivate init() {}
    }

    @MainActor
    static func main() {
        // First, before anything can log (see `OwnerLogs`).
        OwnerLogs.open(Launch())
        // Next, so a write into a closed pipe cannot end the app from here on.
        BrokenPipeGuard.install(Launch())
        // Asked by the release script, which wants the notes and not the app.
        if WhatsNewLaunch.printHTMLIfAsked(CommandLine.arguments) { return }
        // Before any text is read: Spanish or English for this run.
        AppLanguage.apply()
        // A recording played through the in-person notes, then gone.
        if let recording = RecordingReplay.requested() { RecordingReplay.runAndExit(recording) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Starts as a menu-bar / notch utility: no Dock icon, never steals
        // focus. It becomes an ordinary app only while one of its full windows
        // is open or minimised — see `DockPresence`.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
