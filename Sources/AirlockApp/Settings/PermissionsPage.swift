import AppKit
import AVFAudio
import AirlockCore
import CoreGraphics
import SwiftUI

// MARK: - Permissions

/// Every permission the Permissions page draws, as plain values.
///
/// The page used to read macOS from inside its own body, which made every
/// state it can be in — turned off, refused while switched on, restricted —
/// impossible to draw anywhere but on a Mac actually in that state. Read
/// once here (`read`), drawn from values there (`PermissionsPage`), and the
/// state gallery can show each one without asking macOS anything.
struct PermissionFacts: Equatable {
    var calendar: DiagnosticsReport.PermissionState
    var microphone: DiagnosticsReport.PermissionState
    /// `.notWorking` when macOS has an approval on file and the key it should
    /// watch is still dead: the old approval from an earlier version.
    var inputMonitoring: DiagnosticsReport.PermissionState
    var accessibility: DiagnosticsReport.PermissionState
    /// Nil while the guide is off — nothing else looks at the screen, and a
    /// row for a permission no feature uses reads as something Airlock wants
    /// anyway.
    var screenRecording: DiagnosticsReport.PermissionState?
    /// What the last Calendar request found, when it found something worth
    /// saying (macOS didn't show its question, say).
    var calendarNote: String?

    /// What is still to allow, by name, for the line under "Ask for
    /// everything". Restricted rows are left out: nothing anyone here does
    /// can allow them, and they say so on their own row.
    var missing: [String] {
        var names: [(String, DiagnosticsReport.PermissionState)] = [
            ("Microphone", microphone), ("Calendar", calendar),
            ("Input Monitoring", inputMonitoring),
        ]
        if let screenRecording { names.append(("Screen Recording", screenRecording)) }
        names.append(("Accessibility", accessibility))
        return names.filter { $0.1 != .allowed && $0.1 != .restricted }.map(\.0)
    }

    /// A copy with some facts changed — for the state gallery's fixtures.
    func with(_ change: (inout PermissionFacts) -> Void) -> PermissionFacts {
        var copy = self
        change(&copy)
        return copy
    }

    /// Every read here is a preflight: none of them prompts.
    @MainActor
    static func read(dictation: DictationModel, calendar: CalendarWidgetModel) -> PermissionFacts {
        PermissionFacts(
            calendar: SupportDiagnostics.calendarPermission(),
            microphone: SupportDiagnostics.microphonePermission(),
            inputMonitoring: inputMonitoring(dictation),
            accessibility: TypeService.isTrusted ? .allowed : .notAllowed,
            screenRecording: GuideSwitch.isOn
                ? (CGPreflightScreenCaptureAccess() ? .allowed : .notAllowed) : nil,
            calendarNote: calendar.accessNote)
    }

    /// Measured, not just what macOS has on file: the two disagree exactly
    /// when an old approval is in the way. A live hold key with nothing on
    /// file counts as allowed too — macOS lets an app with no record of its
    /// own lean on its Accessibility approval.
    @MainActor
    private static func inputMonitoring(_ dictation: DictationModel) -> DiagnosticsReport.PermissionState {
        switch dictation.holdKeyFault {
        case .grantIsNotWorking: return .notWorking
        case .notGranted: return .notAllowed
        case nil:
            if InputMonitoring.isGranted { return .allowed }
            return dictation.isEnabled && dictation.readiness.canWatchHoldKey ? .allowed : .notAllowed
        }
    }
}

/// What the page's ask buttons do. Empty in the gallery, which never asks.
struct PermissionActions {
    var askForEverything: @MainActor () -> Void = {}
    var allowCalendar: @MainActor () -> Void = {}
    var allowMicrophone: @MainActor () -> Void = {}
    var allowInputMonitoring: @MainActor () -> Void = {}
    var allowScreenRecording: @MainActor () -> Void = {}
}

/// "Ask for everything", before, during and after. After is not latched as
/// a list: what is still missing is read from the facts, so a switch flipped
/// a minute later updates the sentence instead of contradicting it.
enum PermissionSweepState: Equatable {
    case notRun, asking, ran
}

/// Every macOS permission Airlock depends on, in one place, with its real state.
///
/// It exists because of the rename. Changing the bundle identifier reset all
/// four at once, and the app's answer was to scatter the fixes: calendar access
/// under Widgets, the microphone under Dictation, accessibility mentioned in a
/// dictation error string, automation nowhere at all. The permission notice then
/// said "re-grant them in Settings" and dropped people on General with nothing
/// to act on — reported, accurately, as "I don't know what to toggle or where to
/// go".
///
/// Each row says what the permission is FOR, because "Accessibility" means
/// nothing on its own and "so Airlock can type what you dictate" means
/// everything.
///
/// Drawn from values only (`PermissionFacts`): the live page is
/// `PermissionsPane`, which reads macOS and passes them in.
///
/// **A row that was on and is now off says so, with the button that turns it
/// back on.** Calendar and Microphone can tell "turned off" from "never
/// asked"; the others cannot, so they read "Not allowed" either way and offer
/// the same way back. "Allow" is the one name for asking, everywhere here.
struct PermissionsPage: View {
    let facts: PermissionFacts
    var sweep: PermissionSweepState = .notRun
    /// Whether macOS's one-time dialog has been asked for from here. The
    /// System Settings route appears only after it, because macOS shows the
    /// dialog once per app and offering both at once teaches people to skip
    /// the one that works.
    var askedForInputMonitoring = false
    var askedForScreenRecording = false
    var actions = PermissionActions()

    var body: some View {
        Form {
            sweepSection
            calendarSection
            microphoneSection
            inputMonitoringSection
            accessibilitySection
            if let screenRecording = facts.screenRecording {
                screenRecordingSection(screenRecording)
            }
            automationSection

            Section {
                // The promise that makes every row above safe to refuse.
                // An app that asks for four permissions on launch is asking
                // before it has earned any of them, and a refusal then costs
                // features the person had not met yet.
                Text("Airlock never asks for a permission on launch. Each one is asked for the first time the feature that needs it is used, so saying no only ever costs you that one feature.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Ask for everything

    @ViewBuilder private var sweepSection: some View {
        Section {
            Text("macOS gives these to an app, not to a person, so each one has to be allowed once. Nothing here is required — every feature that needs one simply stays off until you turn it on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // One click for the hunting, which is the part that is actually
            // tedious: five permissions across four panes under different
            // names, and the one the dictation key needs is not where anyone
            // looks for it.
            //
            // It ASKS. It cannot allow anything — macOS has no way to, by
            // design — so the label says "Ask for" and the sentence under it
            // says what you will still have to do by hand.
            Button(sweep == .asking ? "Asking…" : "Ask for everything Airlock uses") {
                actions.askForEverything()
            }
            .buttonStyle(.borderedProminent)
            .disabled(sweep == .asking)

            switch sweep {
            case .ran:
                let missing = facts.missing
                if missing.isEmpty {
                    Label("All allowed.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    // Named, because "some permissions are still missing" is
                    // the kind of message that sends somebody back through
                    // every row to find out which.
                    Text("Still to allow by hand: \(missing.formatted(.list(type: .and))). The sections below have the buttons.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .notRun, .asking:
                Text("Asks for each in turn, one at a time. Accessibility and Input Monitoring can only be switched on by you, in System Settings — this takes you there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Calendar

    @ViewBuilder private var calendarSection: some View {
        Section("Calendar") {
            if facts.calendar == .restricted {
                RestrictedRow(what: "Calendar", cost: "so your meetings stay out of the notch")
                    .settingsAnchor(.permissionCalendar)
            } else {
                PermissionStatusRow(state: facts.calendar, canTellTurnedOff: true,
                                    detail: "Shows your next meetings in the notch, with one-click join links. Read-only, and only the calendars you pick.")
                    .settingsAnchor(.permissionCalendar)
                switch facts.calendar {
                case .allowed:
                    // Allowed is where the next question starts — which
                    // calendars — and that answer is on another page.
                    PaneReference(to: SettingsAnchor.calendars, label: "Pick calendars")
                case .notAllowed:
                    TurnedOffCard(kind: .calendar, cost: "so your meetings don't show in the notch")
                    PermissionFixRow(kind: .calendar)
                default:
                    Button("Allow Calendar") { actions.allowCalendar() }
                        .buttonStyle(.borderedProminent)
                    if let note = facts.calendarNote {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Microphone

    @ViewBuilder private var microphoneSection: some View {
        Section("Microphone") {
            if facts.microphone == .restricted {
                RestrictedRow(what: "Microphone",
                              cost: "so hold-to-talk is off and nothing here can turn it on")
                    .settingsAnchor(.permissionMicrophone)
            } else {
                PermissionStatusRow(state: facts.microphone, canTellTurnedOff: true,
                                    detail: "Hold your dictation key and speak. Audio is turned into text on this Mac and never leaves it.")
                    .settingsAnchor(.permissionMicrophone)
                switch facts.microphone {
                case .allowed:
                    EmptyView()
                case .notAllowed:
                    TurnedOffCard(kind: .microphone, cost: "so holding your dictation key records nothing")
                    PermissionFixRow(kind: .microphone)
                default:
                    Button("Allow Microphone") { actions.allowMicrophone() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Input Monitoring

    // Its own section, because it is its own permission.
    //
    // The Accessibility row below used to claim both jobs — "typing your
    // dictation into whatever app you are in, and watching for the hold
    // key you press" — and only the first is true. Watching the keyboard
    // is a different permission, switched on in a different pane, and the
    // app neither asked for it nor read it. A user whose hold key did
    // nothing was sent to Accessibility, found Airlock already allowed,
    // and reasonably concluded the app was broken.
    @ViewBuilder private var inputMonitoringSection: some View {
        Section("Input Monitoring") {
            PermissionStatusRow(state: facts.inputMonitoring, canTellTurnedOff: false,
                                detail: "Lets Airlock notice the dictation key you hold. It reads that a key went down and nothing else — nothing you type.")
                .settingsAnchor(.permissionInputMonitoring)
            switch facts.inputMonitoring {
            case .allowed:
                EmptyView()
            case .notWorking:
                // The row says "On, but not working" while System Settings says
                // on, and that contradiction is the finding. Asking again
                // cannot fix it; clearing the old approval does.
                PermissionFixRow(kind: .inputMonitoring, knownOldApproval: true)
            default:
                Text("Until it is allowed, holding your dictation key does nothing at all — nothing records, and nothing tells you why.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Input Monitoring") { actions.allowInputMonitoring() }
                    .buttonStyle(.borderedProminent)
                if askedForInputMonitoring {
                    Button(PermissionPage.button) { PermissionPage.permission(.inputMonitoring).open() }
                    Text("macOS asks only once per app. If nothing came up, switch Airlock on under Input Monitoring there, or add it with + — this page notices within a second.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PermissionFixRow(kind: .inputMonitoring)
            }
        }
    }

    // MARK: Accessibility

    @ViewBuilder private var accessibilitySection: some View {
        Section("Accessibility") {
            PermissionStatusRow(state: facts.accessibility, canTellTurnedOff: false,
                                detail: "Types your dictation into whatever app you are in, and reads where the cursor is so it knows there is somewhere to type. It also lets the notch tell when an app is full screen, so it can step aside.")
                .settingsAnchor(.permissionAccessibility)
            if facts.accessibility != .allowed {
                // What refusing COSTS, which is the half a permission row
                // usually leaves out. This one degrades rather than breaks.
                Text("Without it, dictation still listens — it just puts your words on the clipboard instead of typing them. And the notch stays on top of full-screen apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // macOS only offers this one in System Settings, so a button
                // that claimed to allow it would lie.
                Button(PermissionPage.button) { PermissionPage.permission(.accessibility).open() }
                    .buttonStyle(.borderedProminent)
                Text("Switch Airlock on in the list there, or add it with + — this page notices within a second.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionFixRow(kind: .accessibility)
            }
        }
    }

    // MARK: Screen Recording

    @ViewBuilder private func screenRecordingSection(_ state: DiagnosticsReport.PermissionState) -> some View {
        Section("Screen Recording") {
            PermissionStatusRow(state: state, canTellTurnedOff: false,
                                detail: "Lets the guide see your screen when you ask it for help, so it can point at the next button. It looks only while it is guiding you.")
                .settingsAnchor(.permissionScreenRecording)
            if state != .allowed {
                Text("Without it, the guide cannot start: it has nothing to point at.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Screen Recording") { actions.allowScreenRecording() }
                    .buttonStyle(.borderedProminent)
                if askedForScreenRecording {
                    // macOS shows its question once per app; after that the
                    // list is the only way.
                    Button(PermissionPage.button) { PermissionPage.permission(.screenRecording).open() }
                }
                Text("macOS applies it after Airlock reopens, and offers Quit & Reopen itself when you switch it on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionFixRow(kind: .screenRecording)
            }
        }
    }

    // MARK: Automation

    @ViewBuilder private var automationSection: some View {
        Section("Automation") {
            // No tick, and the row says why: macOS has no way to read this
            // without asking, and asking to find out would raise the very
            // question this row is describing.
            Label("macOS asks the first time", systemImage: "clock")
                .settingsAnchor(.permissionAutomation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Jumping back to your terminal, and playing or pausing Spotify or Music, need macOS's permission to control that app. macOS asks the first time each one happens — say OK and it works from then on. Airlock can't see the answer until then, so there is no tick here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(PermissionPage.button) { PermissionPage.automation.open() }
        }
    }
}

/// The status line at the top of a permission row, and what the permission
/// is for under it.
private struct PermissionStatusRow: View {
    let state: DiagnosticsReport.PermissionState
    /// Calendar and Microphone know a "no" from a "not yet"; the others read
    /// false for both, and calling that "turned off" would be a guess.
    let canTellTurnedOff: Bool
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .foregroundStyle(colour)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch state {
        case .allowed: return "Allowed"
        case .notWorking: return "On, but not working"
        case .notAllowed: return canTellTurnedOff ? "Turned off" : "Not allowed"
        case .notAsked, .asksOnFirstUse: return "Not allowed yet"
        case .restricted: return "Not allowed"
        }
    }

    private var symbol: String {
        switch state {
        case .allowed: return "checkmark.circle.fill"
        case .notWorking: return "exclamationmark.triangle.fill"
        case .notAllowed where canTellTurnedOff: return "xmark.circle.fill"
        default: return "circle.dashed"
        }
    }

    private var colour: AnyShapeStyle {
        switch state {
        case .allowed: return AnyShapeStyle(Color.green)
        case .notWorking: return AnyShapeStyle(Color.orange)
        case .notAllowed where canTellTurnedOff: return AnyShapeStyle(Color.orange)
        default: return AnyShapeStyle(.secondary)
        }
    }
}

/// A permission that was answered and is now off — said no to, or switched
/// off later in System Settings. macOS will not ask a second time, so the
/// one button is the way back: the list where Airlock's switch is.
private struct TurnedOffCard: View {
    let kind: PermissionKind
    let cost: String

    var body: some View {
        ProblemCard(sentence: "Airlock is switched off under \(kind.systemName) in System Settings, \(cost).",
                    button: PermissionPage.button,
                    action: { PermissionPage.permission(kind).open() })
    }
}

/// A permission an administrator has decided, not the user.
///
/// **No button, deliberately.** A profile on the Mac blocks this, so every
/// control this app could offer would fail silently — and an Allow button that
/// cannot allow is worse than none, because it turns somebody else's policy
/// into what looks like a bug in Airlock. It says who owns the decision and
/// what it costs, and stops.
struct RestrictedRow: View {
    let what: String
    let cost: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Your organisation decides this one", systemImage: "building.2.fill")
                .foregroundStyle(.secondary)
            Text("A profile on this Mac blocks \(what.lowercased()) access, \(cost). Nothing here can change it — ask whoever manages the Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The live Permissions page: reads macOS, keeps reading while it is on
/// screen, and hands the values to `PermissionsPage`.
struct PermissionsPane: View {
    @Environment(CalendarWidgetModel.self) private var calendar
    @Environment(DictationModel.self) private var dictation
    /// Trust is read live rather than stored: it changes in System Settings,
    /// outside this process, with no notification worth observing.
    @State private var refreshTick = 0
    @State private var askedForInputMonitoring = false
    @State private var askedForScreenRecording = false
    @State private var sweep: PermissionSweepState = .notRun

    var body: some View {
        // Read in the body so `refreshTick` and the models' observed state
        // both redraw it.
        let _ = refreshTick
        PermissionsPage(
            facts: PermissionFacts.read(dictation: dictation, calendar: calendar),
            sweep: sweep,
            askedForInputMonitoring: askedForInputMonitoring,
            askedForScreenRecording: askedForScreenRecording,
            actions: PermissionActions(
                askForEverything: {
                    sweep = .asking
                    Task {
                        await PermissionSweep.run(dictation: dictation, calendar: calendar)
                        sweep = .ran
                        refreshTick += 1
                    }
                },
                allowCalendar: { Task { await calendar.requestAccess(); refreshTick += 1 } },
                allowMicrophone: { Task { await dictation.requestMicrophoneAccess(); refreshTick += 1 } },
                allowInputMonitoring: {
                    askedForInputMonitoring = true
                    dictation.requestInputMonitoring()
                },
                allowScreenRecording: {
                    askedForScreenRecording = true
                    _ = CGRequestScreenCaptureAccess()
                    refreshTick += 1
                }))
        // Notices a switch flipped in System Settings while this page is
        // beside it, not only once Airlock is clicked again.
        .watchingPermissions { _ in
            refreshTick += 1
            calendar.recheckAuthorization()
            dictation.recheckHoldKey()
        }
        // Re-read on return from System Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTick += 1
            // Input Monitoring needs more than a re-read: a tap WindowServer
            // narrowed under the old refusal stays narrowed for its whole life,
            // so the taps have to be rebuilt before the answer changes.
            dictation.recheckHoldKey()
        }
    }
}
