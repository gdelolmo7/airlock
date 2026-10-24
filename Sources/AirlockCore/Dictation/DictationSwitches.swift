import Foundation

/// The three things hold to talk needs from macOS, walked one at a time.
///
/// **Why a walk and not three rows.** Asked in the owner's words after a test
/// install: "how will they take advantage of it if permissions sometimes work
/// and sometimes don't?" Each of the three behaves differently, and that is
/// what made them look random:
///
/// 1. **Microphone** is a real question. macOS asks it once, in a dialog, and
///    Allow there is the whole job.
/// 2. **Input Monitoring** and **Accessibility** are never granted from a
///    dialog. The most macOS ever shows is a note that offers to open System
///    Settings, once per app, and after that nothing at all — so a button that
///    only raised the note looked dead from the second click on. Both are
///    switches in two different lists, and only the list turns them on.
///
/// So setup shows one thing at a time, says which list is about to open and
/// what to do in it, and ticks the step itself when the switch flips. The
/// order is the order the feature fails in: without the microphone nothing is
/// heard, without Input Monitoring the key is not noticed, and without
/// Accessibility the words go to the clipboard instead of being typed.
///
/// The words live here rather than in the two wizards, so the panel and the
/// window cannot describe the same step two ways, and so they can be tested.
public struct DictationSwitches: Equatable, Sendable {
    public enum Step: CaseIterable, Equatable, Sendable {
        case microphone
        case inputMonitoring
        case accessibility
    }

    /// The one of the three that is a question rather than a switch.
    public enum Microphone: Equatable, Sendable {
        /// macOS has not asked yet, so its dialog can still appear.
        case notAsked
        case allowed
        /// Said no, or turned off later. macOS never asks twice, so the way
        /// back is the switch in the list.
        case refused
        /// Turned off for every app by whoever manages the Mac (a school or
        /// company profile, or Screen Time). The switch is greyed out in the
        /// list, so sending the person there would be sending them nowhere.
        case blocked
    }

    public var microphone: Microphone
    /// The hold key is noticed — Input Monitoring is on, or macOS lets the
    /// Accessibility approval stand in for it.
    public var keyNoticed: Bool
    /// Accessibility is on, so the words are typed rather than copied.
    public var canType: Bool
    /// Input Monitoring reads on, yet the key never arrives: macOS kept an old
    /// approval that no longer matches this copy. Switching it on cannot help
    /// (it already is), so the step says to take Airlock out and add it back.
    public var keyApprovalIsOld: Bool

    public init(microphone: Microphone, keyNoticed: Bool, canType: Bool, keyApprovalIsOld: Bool = false) {
        self.microphone = microphone
        self.keyNoticed = keyNoticed
        self.canType = canType
        self.keyApprovalIsOld = keyApprovalIsOld && !keyNoticed
    }

    /// From the states the Permissions page reads, so setup and Settings can
    /// never disagree about a switch. Only a microphone macOS can still ask
    /// about is "not asked"; anything else short of allowed is the list's job.
    public init(microphone: DiagnosticsReport.PermissionState,
                inputMonitoring: DiagnosticsReport.PermissionState,
                accessibility: DiagnosticsReport.PermissionState) {
        let mic: Microphone = switch microphone {
        case .allowed: .allowed
        case .notAsked, .asksOnFirstUse: .notAsked
        case .restricted: .blocked
        case .notAllowed, .notWorking: .refused
        }
        self.init(microphone: mic, keyNoticed: inputMonitoring == .allowed,
                  canType: accessibility == .allowed,
                  keyApprovalIsOld: inputMonitoring == .notWorking)
    }

    public func isDone(_ step: Step) -> Bool {
        switch step {
        case .microphone: microphone == .allowed
        case .inputMonitoring: keyNoticed
        case .accessibility: canType
        }
    }

    /// The first step still to do, in order. Nil once all three are done.
    ///
    /// Strictly in order, even when a later one is already on: a walk that
    /// skips ahead and comes back reads as the app changing its mind.
    public var current: Step? { Step.allCases.first { !isDone($0) } }

    public var isDone: Bool { current == nil }

    public var count: Int { Step.allCases.count }

    /// "2" in "2 of 3": the step on show, counted from one. The count itself
    /// once everything is done.
    public var position: Int {
        guard let current, let index = Step.allCases.firstIndex(of: current) else { return count }
        return index + 1
    }

    /// "2 of 3", or "Ready" once there is nothing left.
    public var progress: String { isDone ? String(localized: "Ready") : String(localized: "\(position) of \(count)") }

    /// "2 of 3 · Input Monitoring": how far along, and the name the list that
    /// opens has. Nil once everything is done.
    public var stepLabel: String? { current.map { "\(progress) · \(Self.name($0))" } }

    /// What macOS calls it, so the name matches the list that opens.
    public static func name(_ step: Step) -> String {
        switch step {
        case .microphone: String(localized: "Microphone")
        case .inputMonitoring: String(localized: "Input Monitoring")
        case .accessibility: String(localized: "Accessibility")
        }
    }

    /// What to do for the step on show, in one or two short sentences.
    /// `key` is the hold key's name as the app prints it ("⌃ Control").
    public func instruction(key: String) -> String {
        switch current {
        case .microphone where microphone == .blocked:
            String(localized: "Whoever manages this Mac has turned the microphone off for apps, so only they can turn it on for Airlock.")
        case .microphone:
            microphone == .refused
                ? String(localized: "The microphone is off for Airlock. Switch Airlock on in the list that opens.")
                : String(localized: "macOS asks once if Airlock may hear you. Say Allow.")
        case .inputMonitoring where keyApprovalIsOld:
            String(localized: "Airlock already looks on, but macOS isn't passing \(key) along. In the list that opens, remove Airlock with –, then add it back with +.")
        case .inputMonitoring:
            String(localized: "Switch Airlock on in the list that opens, so it notices you holding \(key). It sees that key, not what you type.")
        case .accessibility:
            String(localized: "Last one. Switch Airlock on in the list that opens, so your words are typed where you're writing.")
        case nil:
            String(localized: "Hold \(key) and talk. Let go, and your words are typed.")
        }
    }

    /// The button for the step on show. Nil once everything is done.
    ///
    /// "Open the list" rather than "Allow" for the two switches: the button
    /// cannot allow them, and saying it does is how they came to look broken.
    public var button: String? {
        switch current {
        case .microphone where microphone == .blocked: nil
        case .microphone: microphone == .refused ? Self.openList : String(localized: "Ask macOS")
        case .inputMonitoring, .accessibility: Self.openList
        case nil: nil
        }
    }

    /// The button opens a list in System Settings, rather than asking.
    public var opensList: Bool {
        switch current {
        case .microphone: microphone == .refused
        case .inputMonitoring, .accessibility: true
        case nil: false
        }
    }

    /// Under the instruction once its list has been opened: the step finishes
    /// on its own, so the person is told not to look for a button.
    public static let ticksByItself = String(localized: "This ticks by itself when the switch is on. Airlock not in the list? Add it with +.")

    static let openList = String(localized: "Open the list")
}
