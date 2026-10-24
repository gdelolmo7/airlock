import AppKit
import AirlockCore

/// Allow, for the two permissions macOS never grants from a dialog: Input
/// Monitoring and Accessibility.
///
/// **One click always ends at the switch.** Allow used to raise macOS's own
/// request and nothing else. For these two that request is at most a note
/// offering to open System Settings, shown once per app — and on a test
/// install it had already been used up at launch, so Allow did nothing at all
/// and holding the key did nothing either (2026-10-23). Nothing on screen said
/// that a switch in a list was the only way.
///
/// So each click does both halves: it asks, which puts Airlock in the list
/// (the first time, macOS may show its note as well, and both of its buttons
/// leave the list where it is), and then it opens the list. Never the list
/// alone: without the ask Airlock may not be in it, and "add it with +" is a
/// step most people never find.
///
/// The microphone, the calendar and Automation are not here: the first two
/// are real questions that Allow answers, and the third has no ask at all.
@MainActor
enum PermissionSwitch {
    static func allowInputMonitoring(_ dictation: DictationModel) {
        guard !dictation.requestInputMonitoring() else { return }
        openList(.inputMonitoring) { InputMonitoring.isGranted }
    }

    static func allowAccessibility() {
        PasteService.requestTrust()
        openList(.accessibility) { TypeService.isTrusted }
    }

    /// After a beat, so the record the ask just made is there when the list
    /// draws, and so a note macOS shows lands before the list rather than
    /// fighting it for the front. Not if the switch came on in between.
    private static func openList(_ kind: PermissionKind, unlessOn isOn: @escaping @MainActor () -> Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !isOn() else { return }
            PermissionPage.permission(kind).open()
        }
    }
}
