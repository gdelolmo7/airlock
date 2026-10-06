import AppKit
import AVFoundation
import AirlockCore
import CoreGraphics

/// Asks for every permission Airlock uses, one after another, from one click.
///
/// **It cannot grant anything, and the wording everywhere must not suggest it
/// can.** macOS has no "allow this app what it needs" API by design — that is
/// the whole point of TCC — so the most an app can do is raise each request in
/// turn and send you to the right pane for the ones with no request to raise.
/// What this removes is the hunting: five permissions live in four different
/// places under different names, and the one the dictation key needs is not
/// where anybody looks for it.
///
/// **Order is not arbitrary.** macOS shows one TCC dialog at a time, so the two
/// that genuinely wait for an answer go first and are awaited. The two that
/// return before the user has decided go last, and Accessibility goes last of
/// all because its dialog is the only one that navigates away to System
/// Settings — anything queued behind it would be answered in a window the user
/// has already left.
///
/// **This does not violate "never asks on launch".** That rule is about
/// unprompted prompts; this is a button, pressed deliberately, by somebody who
/// has just read what each one is for.
@MainActor
enum PermissionSweep {
    /// One permission's place in the sweep — what to check, and what to ask.
    ///
    /// A list rather than four inline calls so the sweep's shape is visible at a
    /// glance and a fifth permission is one entry, not a fifth branch in a
    /// function that has quietly become a procedure.
    struct Step {
        let name: String
        /// Already granted? Skipped if so: re-asking is at best a no-op and at
        /// worst an Accessibility dialog shown to somebody who already said yes.
        let isSatisfied: () -> Bool
        let ask: () async -> Void
    }

    /// Everything Airlock can ask for, in the order it should be asked.
    ///
    /// Automation is deliberately absent: macOS exposes no way to request it,
    /// and no way to read it short of sending an Apple event — which would raise
    /// the very prompt the row is describing. It asks on first use and says so.
    ///
    /// Screen Recording is in it while the guide is on, because the guide
    /// cannot start without it: a sweep that skipped it and then said
    /// everything was allowed sent people to a guide that would not open (X29).
    static func steps(dictation: DictationModel,
                      calendar: CalendarWidgetModel,
                      guideOn: Bool = GuideSwitch.isOn) -> [Step] {
        var steps: [Step] = [
            // Waits for the answer.
            Step(name: "Microphone",
                 isSatisfied: { AVAudioApplication.shared.recordPermission == .granted },
                 ask: { await dictation.requestMicrophoneAccess() }),
            // Waits for the answer.
            Step(name: "Calendar",
                 isSatisfied: { calendar.authStatus == .fullAccess },
                 ask: { await calendar.requestAccess() }),
            // Returns immediately; macOS queues the dialog itself. Satisfied
            // the way the page reads it, so an old approval that does not
            // work is still named as missing afterwards.
            Step(name: "Input Monitoring",
                 isSatisfied: {
                     PermissionFacts.read(dictation: dictation, calendar: calendar).inputMonitoring == .allowed
                 },
                 ask: { dictation.requestInputMonitoring() }),
        ]
        if guideOn {
            // Returns immediately too; its dialog also offers System Settings,
            // so it goes after the ones that wait and before Accessibility.
            steps.append(Step(name: "Screen Recording",
                              isSatisfied: { CGPreflightScreenCaptureAccess() },
                              ask: { _ = CGRequestScreenCaptureAccess() }))
        }
        // Last: its dialog offers System Settings and takes focus away.
        steps.append(Step(name: "Accessibility",
                          isSatisfied: { TypeService.isTrusted },
                          ask: { PasteService.requestTrust() }))
        return steps
    }

    /// Run the sweep. Returns the names of everything still missing afterwards,
    /// so the caller can say what is left instead of claiming success.
    @discardableResult
    static func run(dictation: DictationModel,
                    calendar: CalendarWidgetModel) async -> [String] {
        for step in steps(dictation: dictation, calendar: calendar) where !step.isSatisfied() {
            await step.ask()
            // A beat between asks. The last two return before the user has
            // answered, so without it their dialogs can land on screen together
            // — two permission requests at once reads as an app grabbing for
            // everything, which is the impression this button most needs to
            // avoid.
            try? await Task.sleep(for: .milliseconds(400))
        }
        return steps(dictation: dictation, calendar: calendar)
            .filter { !$0.isSatisfied() }
            .map(\.name)
    }
}
