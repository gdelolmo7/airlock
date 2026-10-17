import Foundation

/// One thing that happened, as a usage count: a name and a few numbers,
/// switches and short code words. Never what anybody typed, said, copied or
/// saw.
///
/// That is enforced by shape rather than by care. The only way to build an
/// event from outside Core is one of the named factories below, and their
/// parameters are enums, numbers and switches. The few that take a code word
/// from the app (a widget's id, a Settings page) put it through `word(_:)`,
/// which keeps a short identifier and turns anything else into "other": a
/// sentence, a path or a pasted command has a space, a slash or a length
/// that no identifier has.
///
/// Counted so the owner can see where setup loses people, which features get
/// used and who keeps using Airlock. Only for people who said yes
/// (`UsagePolicy`).
public struct UsageEvent: Equatable, Sendable {
    public let name: String
    public let properties: [String: UsageValue]

    init(_ name: String, _ properties: [String: UsageValue] = [:]) {
        self.name = name
        self.properties = properties
    }

    // MARK: - The app

    /// Airlock started.
    public static let appOpened = UsageEvent("app_opened")

    /// Where a yes came from.
    public enum Origin: String, Sendable, CaseIterable { case setup, question, settings }

    /// The person said yes: the first event this copy sends.
    public static func countsStarted(from origin: Origin) -> UsageEvent {
        UsageEvent("counts_started", ["from": .word(origin.rawValue)])
    }

    /// Once a day while Airlock runs, so a Mac that stays awake for a week
    /// still counts as using it every day of it. Carries what is set up
    /// rather than what was done, which is what the other events are for.
    public static func dayActive(plan: AirlockPlan, widgetsOn: Int, agentsConnected: Int,
                                 dictationOn: Bool, callNotesOn: Bool,
                                 crashReportsOn: Bool) -> UsageEvent {
        UsageEvent("day_active", [
            "plan": .word(plan.rawValue),
            "widgets_on": .int(widgetsOn),
            "agents_connected": .int(agentsConnected),
            "dictation_on": .bool(dictationOn),
            "call_notes_on": .bool(callNotesOn),
            "crash_reports_on": .bool(crashReportsOn),
        ])
    }

    // MARK: - Setup

    /// A setup step came on screen. `secondsBefore` is how long the step
    /// before it was up, nil for the first.
    public static func setupStep(_ step: OnboardingPlan.Step, position: Int,
                                 secondsBefore: Int?) -> UsageEvent {
        var properties: [String: UsageValue] = ["step": .word(step.rawValue), "position": .int(position)]
        if let secondsBefore { properties["seconds_before"] = .int(max(0, secondsBefore)) }
        return UsageEvent("setup_step", properties)
    }

    public enum SetupEnd: String, Sendable { case done, skipped }

    /// Setup ended, on `step`, after `seconds` in all.
    public static func setupEnded(_ how: SetupEnd, at step: OnboardingPlan.Step,
                                  seconds: Int) -> UsageEvent {
        UsageEvent("setup_ended", ["how": .word(how.rawValue), "step": .word(step.rawValue),
                                   "seconds": .int(max(0, seconds))])
    }

    /// "I don't use coding agents", in setup.
    public static let agentsDeclined = UsageEvent("agents_declined")

    // MARK: - Agents

    /// An agent was connected or disconnected. `inSetup` when setup did it.
    public static func agentConnection(_ agent: AgentKind, connected: Bool, inSetup: Bool) -> UsageEvent {
        UsageEvent("agent_connection", ["agent": .word(agent.rawValue), "connected": .bool(connected),
                                        "in_setup": .bool(inSetup)])
    }

    /// An agent started a session the notch can see.
    public static func agentSession(_ agent: AgentKind) -> UsageEvent {
        UsageEvent("agent_session", ["agent": .word(agent.rawValue)])
    }

    public enum Answer: String, Sendable { case allow, deny, always }

    /// A request answered in the notch. `risky` when Airlock's risk floor
    /// marked it.
    public static func approval(_ agent: AgentKind, _ answer: Answer, risky: Bool) -> UsageEvent {
        UsageEvent("approval", ["agent": .word(agent.rawValue), "answer": .word(answer.rawValue),
                                "risky": .bool(risky)])
    }

    /// An agent's question answered in the notch.
    public static func questionAnswered(_ agent: AgentKind) -> UsageEvent {
        UsageEvent("question_answered", ["agent": .word(agent.rawValue)])
    }

    // MARK: - Features

    /// The things people do that are not about agents. One event with the
    /// feature named, so a new one is a case here and nothing else.
    public enum Feature: String, Sendable, CaseIterable {
        case clipboardOpened = "clipboard_opened"
        case clipboardPasted = "clipboard_pasted"
        case shelfDropped = "shelf_dropped"
        case dictation
        case askedAQuestion = "asked_a_question"
        case quickPrompt = "quick_prompt"
        case outputSwitched = "output_switched"
        case meetingJoined = "meeting_joined"
        case terminalJump = "terminal_jump"
        case callNotesOpened = "call_notes_opened"
    }

    public static func used(_ feature: Feature) -> UsageEvent {
        UsageEvent("feature_used", ["feature": .word(feature.rawValue)])
    }

    public enum NotesWritten: String, Sendable {
        /// On the Worker, online.
        case online
        /// On this Mac.
        case mac
        /// Not yet: they wait for the network or next month.
        case later
        /// None: too short, or nothing worth writing.
        case none
    }

    /// A call's notes ended. Minutes rounded, and nothing about the call
    /// beyond its length and where its notes were written.
    public static func callEnded(minutes: Int, notes: NotesWritten, inPerson: Bool) -> UsageEvent {
        UsageEvent("call_ended", ["minutes": .int(max(0, minutes)), "notes": .word(notes.rawValue),
                                  "in_person": .bool(inPerson)])
    }

    /// A widget switched on or off. `widget` is its id in code.
    public static func widgetSwitched(_ widget: String, on: Bool) -> UsageEvent {
        UsageEvent("widget_switched", ["widget": .word(word(widget)), "on": .bool(on)])
    }

    /// A Settings page opened. `page` is its id in code.
    public static func settingsOpened(_ page: String) -> UsageEvent {
        UsageEvent("settings_opened", ["page": .word(word(page))])
    }

    // MARK: - Plans

    /// Settings › Plans opened. `from` names the button that opened it.
    public static func plansOpened(from: String) -> UsageEvent {
        UsageEvent("plans_opened", ["from": .word(word(from))])
    }

    /// Something Free leaves out was asked for. `limit` names the row in
    /// `PlanLimits`.
    public static func freeLimitHit(_ limit: String) -> UsageEvent {
        UsageEvent("free_limit_hit", ["limit": .word(word(limit))])
    }

    public static func planChanged(from: AirlockPlan, to: AirlockPlan) -> UsageEvent {
        UsageEvent("plan_changed", ["from": .word(from.rawValue), "to": .word(to.rawValue)])
    }

    // MARK: - Problems

    /// Something in the way that the person can see, like a permission
    /// macOS has not given. `problem` is a code word for it.
    public static func problemSeen(_ problem: String) -> UsageEvent {
        UsageEvent("problem_seen", ["problem": .word(word(problem))])
    }

    // MARK: - Code words

    /// The longest code word kept.
    public static let wordLimit = 40

    /// A short identifier, kept as it is; anything else, "other".
    ///
    /// Letters, digits and `_ . , -` only, at most `wordLimit` long. That
    /// admits every id in the code and every version or Mac model string
    /// ("1.0.24", "Mac16,1") and refuses everything a person writes: a space,
    /// a slash, a colon, a quote or a length is enough to stop it.
    public static func word(_ raw: String) -> String {
        guard !raw.isEmpty, raw.count <= wordLimit,
              raw.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return "other" }
        return raw
    }

    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.,-")
}

/// A property's value: a switch, a number or a code word.
///
/// `word` is only ever built inside Core, from an enum's raw value or through
/// `UsageEvent.word(_:)`; there is no way in for free text.
public enum UsageValue: Equatable, Sendable, Codable {
    case bool(Bool)
    case int(Int)
    case word(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            // Read back from the queue file, which this app wrote, but a word
            // goes through the same door as one built here.
            self = .word(UsageEvent.word(try container.decode(String.self)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .word(let value): try container.encode(value)
        }
    }
}
