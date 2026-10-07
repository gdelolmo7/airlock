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
        // Asked by the release script, which wants the notes and not the app.
        if WhatsNewLaunch.printHTMLIfAsked(CommandLine.arguments) { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar / notch utility — no Dock icon, never steals focus.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
