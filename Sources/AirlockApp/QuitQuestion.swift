import AppKit
import AirlockCore
import Carbon.HIToolbox
import Synchronization

/// The one place a quit is asked about: every route — ⌘Q, Quit in the
/// menu-bar icon's menu, the Dock's Quit, a script — arrives at
/// `applicationShouldTerminate`, which asks here. What to decide is
/// `QuitCheck`'s; this reads the facts off AppKit and shows the question.
enum QuitQuestion {
    /// Raised just before Airlock quits itself on purpose — an update
    /// relaunching it — so that quit goes through without a question.
    /// Atomic rather than main-actor state: Sparkle calls its delegate as
    /// plain Objective-C, and this has to be set before the quit arrives,
    /// not on a later turn.
    private static let onPurpose = Atomic<Bool>(false)

    static func quittingOnPurpose() {
        onPurpose.store(true, ordering: .relaxed)
    }

    /// Asks, if `takingNotes` is a call or meeting being written down and the
    /// quit is one a person asked for; otherwise lets it through.
    @MainActor
    static func reply(takingNotes: OngoingCall?) -> NSApplication.TerminateReply {
        let reason = QuitCheck.reason(quitReasonCode: quitReasonCode(),
                                      onPurpose: onPurpose.load(ordering: .relaxed))
        guard let call = takingNotes, QuitCheck.asks(takingNotes: true, reason: reason) else {
            return .terminateNow
        }
        let quit = ask(QuitCheck.question(inPerson: call.isInPerson))
        Log.app.info("quit during notes: \(quit ? "quit anyway" : "kept taking notes", privacy: .public)")
        return quit ? .terminateNow : .terminateCancel
    }

    /// The reason the system gave, when the quit came as an Apple event that
    /// carries one: log out, restart and shut down do.
    @MainActor
    private static func quitReasonCode() -> UInt32? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else { return nil }
        // Sent as an enumeration in practice; read as a type code as well,
        // since either holds the same four letters and the other reads as 0.
        let code = why.enumCodeValue
        return code != 0 ? code : why.typeCodeValue
    }

    /// True for "Quit anyway". Return and Escape both keep the notes.
    @MainActor
    private static func ask(_ question: QuitCheck.Question) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        // First, so it is the default and takes Return.
        alert.addButton(withTitle: question.keep)
        alert.addButton(withTitle: question.quit)
        // NSAlert gives Escape only to a button titled "Cancel", and there is
        // none here; without this, Escape would do nothing at all.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Int(event.keyCode) == kVK_Escape else { return event }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        // From the menu-bar icon Airlock is not the active app, and a
        // question behind the call's window would read as a quit that hung.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
