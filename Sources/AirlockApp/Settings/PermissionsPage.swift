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
    /// The screen half of "Screen & System Audio Recording", which macOS
    /// lets an app read without asking.
    var screenRecording = false
    /// The audio half, which it doesn't: what the last call found
    /// (`OtherSideHistory`). Nil before any call has tried.
    var otherSide: OtherSideHistory?
    /// What the last Calendar request found, when it found something worth
    /// saying (macOS didn't show its question, say).
    var calendarNote: String?

    /// What is still to allow, by name, for the line under "Ask for
    /// everything". Restricted rows are left out: nothing anyone here does
    /// can allow them, and they say so on their own row.
    var missing: [String] {
        let names: [(String, DiagnosticsReport.PermissionState)] = [
            (String(localized: "Microphone"), microphone), (String(localized: "Calendar"), calendar),
            (String(localized: "Input Monitoring"), inputMonitoring), (String(localized: "Accessibility"), accessibility),
        ]
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
            screenRecording: CGPreflightScreenCaptureAccess(),
            otherSide: OtherSideHistory.read(),
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
    var allowAccessibility: @MainActor () -> Void = {}
    var allowInputMonitoring: @MainActor () -> Void = {}
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
    /// Whether Allow has been pressed here, for Accessibility and Input
    /// Monitoring. It opens the list in System Settings (`PermissionSwitch`),
    /// and after it the row says what to do in that list rather than why the
    /// permission matters.
    var askedForAccessibility = false
    var askedForInputMonitoring = false
    var actions = PermissionActions()
    @State var moreOptions = false

    var body: some View {
        LookPage(String(localized: "Permissions"), subtitle: String(localized: "What macOS lets Airlock do. Nothing here is required."),
                 moreOptions: $moreOptions) {
            sweepRow
            calendarRows
            microphoneRows
            inputMonitoringRows
            accessibilityRows
            screenAudioRow
            automationRow
        } more: {
            LookGroupLabel("About permissions")
            // The promise that makes every row safe to refuse. An app that
            // asks for four permissions on launch is asking before it has
            // earned any of them, and a refusal then costs features the person
            // had not met yet.
            LookNote("Airlock never asks for a permission on launch. Each one is asked for the first time the feature that needs it is used, so saying no only ever costs you that one feature.")
            LookNote("macOS gives these to an app, not to a person, so each one has to be allowed once. Every feature that needs one simply stays off until you turn it on.")
            LookNote("Ask for everything asks for each in turn, one at a time. Accessibility and Input Monitoring can only be switched on by you, in System Settings — it takes you there.")

            LookGroupLabel("What each one is for")
            LookNote("Calendar shows your next meetings in the notch, with one-click join links. Read-only, and only the calendars you pick.")
            LookNote("Microphone: hold your dictation key and speak. Audio is turned into text on this Mac and never leaves it.")
            // Its own row, because it is its own permission. The Accessibility
            // row used to claim both jobs, and a user whose hold key did
            // nothing was sent to a pane where Airlock was already allowed.
            LookNote("Input Monitoring lets Airlock notice the dictation key you hold. It reads that a key went down and nothing else — nothing you type.")
            LookNote("Accessibility types your dictation into whatever app you are in, and reads where the cursor is so it knows there is somewhere to type. It also lets the notch tell when an app is full screen, so it can step aside.")
            LookNote("Automation: jumping back to your terminal, and playing or pausing Spotify or Music, need macOS's permission to control that app. macOS asks the first time each one happens — say OK and it works from then on. Airlock can't see the answer until then, so there is no tick.")
        }
    }

    // MARK: Ask for everything

    // One click for the hunting, which is the part that is actually tedious:
    // five permissions across four panes under different names, and the one
    // the dictation key needs is not where anyone looks for it.
    //
    // It ASKS. It cannot allow anything — macOS has no way to, by design — so
    // the label says "Ask for" and the line under it says what you will still
    // have to do by hand.
    //
    // With nothing left to ask for, the bright button would be asking you to
    // press something that does nothing, so the row says it is all set.
    private var sweepRow: some View {
        LookRow("Ask for everything Airlock uses", subtitle: sweepSubtitle) {
            if allSet {
                LookStatus(ok: true, text: String(localized: "All allowed"))
            } else {
                LookButton(sweep == .asking ? "Asking…" : "Ask", prominent: true) {
                    actions.askForEverything()
                }
                .disabled(sweep == .asking)
            }
        }
    }

    private var allSet: Bool { sweep != .asking && facts.missing.isEmpty }

    private var sweepSubtitle: String {
        if allSet { return String(localized: "Nothing left to ask for") }
        guard sweep == .ran else { return String(localized: "One at a time, each in turn") }
        // Named, because "some permissions are still missing" is the kind of
        // message that sends somebody back through every row to find out which.
        return String(localized: "Still to allow by hand: \(facts.missing.formatted(.list(type: .and))).")
    }

    // The first row on the page with a Fix, top to bottom. It carries the
    // whole explanation; the ones below it only ask the question, so three
    // refused permissions don't print the same paragraph three times.
    private var firstFix: PermissionKind? {
        if facts.calendar == .notAllowed { return .calendar }
        if facts.microphone == .notAllowed { return .microphone }
        if facts.inputMonitoring != .allowed, facts.inputMonitoring != .notWorking { return .inputMonitoring }
        if facts.accessibility != .allowed { return .accessibility }
        return nil
    }

    // MARK: Calendar

    @ViewBuilder private var calendarRows: some View {
        if facts.calendar == .restricted {
            RestrictedRow(what: String(localized: "Calendar"), cost: String(localized: "so your meetings stay out of the notch"))
                .settingsAnchor(.permissionCalendar)
        } else {
            PermissionStatusRow(name: String(localized: "Calendar"), purpose: String(localized: "Your next meetings, with join links"),
                                state: facts.calendar, canTellTurnedOff: true) {
                if ![.allowed, .notAllowed].contains(facts.calendar) {
                    LookButton("Allow", prominent: true) { actions.allowCalendar() }
                }
            }
            .settingsAnchor(.permissionCalendar)
            switch facts.calendar {
            case .allowed:
                // Allowed is where the next question starts — which calendars
                // — and that answer is on another page.
                PaneReference(String(localized: "Which calendars show is up to you"), to: SettingsAnchor.calendars, label: String(localized: "Pick calendars"))
            case .notAllowed:
                TurnedOffCard(kind: .calendar, cost: String(localized: "so your meetings don't show in the notch"))
                PermissionFixRow(kind: .calendar, brief: firstFix != .calendar)
            default:
                if let note = facts.calendarNote {
                    LookNote(note)
                }
            }
        }
    }

    // MARK: Microphone

    @ViewBuilder private var microphoneRows: some View {
        if facts.microphone == .restricted {
            RestrictedRow(what: String(localized: "Microphone"),
                          cost: String(localized: "so hold-to-talk is off and nothing here can turn it on"))
                .settingsAnchor(.permissionMicrophone)
        } else {
            PermissionStatusRow(name: String(localized: "Microphone"), purpose: String(localized: "Your side of calls, and dictation"),
                                state: facts.microphone, canTellTurnedOff: true) {
                if ![.allowed, .notAllowed].contains(facts.microphone) {
                    LookButton("Allow", prominent: true) { actions.allowMicrophone() }
                }
            }
            .settingsAnchor(.permissionMicrophone)
            if facts.microphone == .notAllowed {
                TurnedOffCard(kind: .microphone, cost: String(localized: "so holding your dictation key records nothing"))
                PermissionFixRow(kind: .microphone, brief: firstFix != .microphone)
            }
        }
    }

    // MARK: Input Monitoring

    @ViewBuilder private var inputMonitoringRows: some View {
        PermissionStatusRow(name: String(localized: "Input Monitoring"), purpose: String(localized: "Notices the dictation key you hold, nothing you type"),
                            state: facts.inputMonitoring, canTellTurnedOff: false) {
            if facts.inputMonitoring != .allowed && facts.inputMonitoring != .notWorking {
                LookButton("Allow", prominent: true) { actions.allowInputMonitoring() }
            }
        }
        .settingsAnchor(.permissionInputMonitoring)
        switch facts.inputMonitoring {
        case .allowed:
            EmptyView()
        case .notWorking:
            // The row says "On, but not working" while System Settings says
            // on, and that contradiction is the finding. Asking again cannot
            // fix it; clearing the old approval does.
            PermissionFixRow(kind: .inputMonitoring, knownOldApproval: true)
        default:
            if askedForInputMonitoring {
                LookNote(Self.switchItOn)
            } else {
                LookNote("Until it is allowed, holding your dictation key does nothing at all — nothing records, and nothing tells you why. Allow opens the list in System Settings.")
            }
            PermissionFixRow(kind: .inputMonitoring, brief: firstFix != .inputMonitoring)
        }
    }

    /// Under a row whose Allow has opened its list. Every word of it is
    /// about the list, because that is where the person now is.
    static let switchItOn = String(localized: "In the list that opened, switch Airlock on — this page ticks it within a second. Not in the list? Add it with +.")

    // MARK: Accessibility

    @ViewBuilder private var accessibilityRows: some View {
        PermissionStatusRow(name: String(localized: "Accessibility"), purpose: String(localized: "Types your dictation, and steps aside for full screen"),
                            state: facts.accessibility, canTellTurnedOff: false) {
            if facts.accessibility != .allowed {
                // Allow as on the row above: it asks, which puts Airlock in
                // the list, then opens the list, which is the only place
                // macOS turns this one on.
                LookButton("Allow", prominent: true) { actions.allowAccessibility() }
            }
        }
        .settingsAnchor(.permissionAccessibility)
        if facts.accessibility != .allowed {
            if askedForAccessibility {
                LookNote(Self.switchItOn)
            } else {
                // What refusing COSTS, which is the half a permission row
                // usually leaves out. This one degrades rather than breaks.
                LookNote("Without it, dictation still listens — it just puts your words on the clipboard instead of typing them. And the notch stays on top of full-screen apps. Allow opens the list in System Settings.")
            }
            PermissionFixRow(kind: .accessibility, brief: firstFix != .accessibility)
        }
    }

    // MARK: Screen & System Audio Recording

    // One switch in System Settings that covers two things macOS answers
    // differently. The screen half can be read; the audio half cannot be
    // read at all, only seen working or not on a call. So the row has a
    // line for each and never a single tick that would be half a guess.
    private var screenAudioRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen & System Audio Recording")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                Text("Hears the other side of calls, and makes Screenshot and Record work")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    otherSideLine
                    screenLine
                }
                .font(Theme.chrome(11))
                .padding(.top, 4)
            }
            Spacer(minLength: 8)
            LookButton(PermissionPage.button) { PermissionPage.permission(.screenRecording).open() }
        }
        .lookRowBox()
        .settingsAnchor(.permissionScreenAudio)
    }

    @ViewBuilder private var otherSideLine: some View {
        switch facts.otherSide {
        case .worked:
            Label("Other side of calls: worked on your last call", systemImage: "checkmark")
                .foregroundStyle(Theme.done)
        case .refused:
            Label("Other side of calls: refused on your last call", systemImage: "xmark")
                .foregroundStyle(Theme.needs)
        case nil:
            Label("Other side of calls: not tried yet", systemImage: "circle.dashed")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var screenLine: some View {
        if facts.screenRecording {
            Label("Screenshot & Record: allowed", systemImage: "checkmark")
                .foregroundStyle(Theme.done)
        } else {
            Label("Screenshot & Record: not allowed yet", systemImage: "circle.dashed")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Automation

    // No tick, and the row says why: macOS has no way to read this without
    // asking, and asking to find out would raise the very question this row
    // is describing.
    private var automationRow: some View {
        LookRow("Automation", subtitle: String(localized: "Jumping to your terminal; Spotify and Music")) {
            HStack(spacing: 10) {
                Label("Asked the first time", systemImage: "clock")
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                LookButton(PermissionPage.button) { PermissionPage.automation.open() }
            }
        }
        .settingsAnchor(.permissionAutomation)
    }
}

/// One permission: its name, what it is for, its state and what to do.
private struct PermissionStatusRow<Action: View>: View {
    let name: String
    let purpose: String
    let state: DiagnosticsReport.PermissionState
    /// Calendar and Microphone know a "no" from a "not yet"; the others read
    /// false for both, and calling that "turned off" would be a guess.
    let canTellTurnedOff: Bool
    @ViewBuilder var action: () -> Action

    var body: some View {
        LookRow(name, subtitle: purpose) {
            HStack(spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(colour)
                    .fixedSize()
                action()
            }
        }
    }

    private var title: String {
        switch state {
        case .allowed: return String(localized: "Allowed")
        case .notWorking: return String(localized: "On, but not working")
        case .notAllowed: return canTellTurnedOff ? String(localized: "Turned off") : String(localized: "Not allowed")
        case .notAsked, .asksOnFirstUse: return String(localized: "Not allowed yet")
        case .restricted: return String(localized: "Not allowed")
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

    private var colour: Color {
        switch state {
        case .allowed: return Theme.done
        case .notWorking: return Theme.needs
        case .notAllowed where canTellTurnedOff: return Theme.needs
        default: return Theme.textSecondary
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
        ProblemCard(sentence: String(localized: "Airlock is switched off under \(kind.systemName) in System Settings, \(cost)."),
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
        LookRow(what, subtitle: String(localized: "A profile on this Mac blocks \(what.lowercased()) access, \(cost). Nothing here can change it — ask whoever manages the Mac.")) {
            Label("Your organisation decides", systemImage: "building.2.fill")
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
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
    @State private var askedForAccessibility = false
    @State private var askedForInputMonitoring = false
    @State private var sweep: PermissionSweepState = .notRun

    var body: some View {
        // Read in the body so `refreshTick` and the models' observed state
        // both redraw it.
        let _ = refreshTick
        PermissionsPage(
            facts: PermissionFacts.read(dictation: dictation, calendar: calendar),
            sweep: sweep,
            askedForAccessibility: askedForAccessibility,
            askedForInputMonitoring: askedForInputMonitoring,
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
                allowAccessibility: {
                    askedForAccessibility = true
                    PermissionSwitch.allowAccessibility()
                },
                allowInputMonitoring: {
                    askedForInputMonitoring = true
                    PermissionSwitch.allowInputMonitoring(dictation)
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
