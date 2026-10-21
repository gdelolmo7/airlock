import AppKit
import AirlockCore

/// Asks before this Mac keeps the owner's mark (`OwnerMark`). Any web page
/// can open an `airlock://` link, so nothing is kept without a yes here.
enum OwnerMarkQuestion {
    @MainActor
    static func ask(keeping mark: String, in counts: UsageCounts) {
        let question = OwnerMark.question(new: mark, current: counts.ownerMark,
                                          sendsCounts: counts.isEnabled)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        // First, so it is the default and takes Return; "Cancel" takes Escape.
        if let keep = question.keep { alert.addButton(withTitle: keep) }
        alert.addButton(withTitle: question.done)
        // The link comes from a browser, so Airlock is not the active app,
        // and a question behind the browser would read as nothing happening.
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        guard question.keep != nil, answer == .alertFirstButtonReturn else { return }
        let kept = counts.keepOwnerMark(mark)
        Log.app.info("owner mark: \(kept ? "kept" : "could not be written", privacy: .public)")
    }
}
