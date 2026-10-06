import Foundation

/// The first run for everyday users (card 3.07, designs 9a–9d): one screen that
/// says what Airlock does, a practice task on the real screen, and the one
/// question that decides whether the coding-agent half of the app exists for
/// this person at all.
///
/// It sits beside `OnboardingPlan` rather than inside it because the two are
/// not the same walk with steps hidden. That one wires hooks and lists
/// features; this one teaches the ring and the bubble on something harmless,
/// and reaches `OnboardingPlan`'s agents step only through "Yes".
///
/// Pure, like `OnboardingPlan`: the two rules worth getting right — who is
/// asked the developer question, and where each answer leads — are here and
/// under test.
public struct WelcomePlan: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        /// 9a. "Stuck on a screen? Ask."
        case welcome
        /// 9c. The window is out of the way while the guide runs for real.
        case practice
        /// 9d. "Do you use AI coding tools like Claude Code?"
        case developer
    }

    public enum Practice: Equatable, Sendable {
        case notTried
        /// The guide reached the goal: the wallpaper changed.
        case reached
        /// Stopped, refused a permission, or could not find its way. The
        /// first run carries on regardless — a practice that blocks setup is a
        /// test, not a practice — and offers another go.
        case notReached
    }

    /// Where the first run goes once the practice is over.
    public enum AfterPractice: Equatable, Sendable {
        case ask
        /// Agent hooks are already installed: this person is a developer and
        /// has shown it, so they are not asked to say so. The agents surface is
        /// already on by `AgentsPresence`'s derived default, and nothing is
        /// written, so that default stays derived.
        case finish
        /// Not asked, and the practice did not get there: back to the welcome,
        /// which says so and offers another go or Done. Closing the window
        /// without a word read as the practice having worked.
        case offerAgain
    }

    public enum Answer: Equatable, Sendable {
        case no, yes
    }

    public enum AfterAnswer: Equatable, Sendable {
        /// Close and show the notch. Developer mode stays off.
        case done
        /// Continue into the existing setup at its agents step (Home Tab 7a).
        case connectAgents
    }

    public private(set) var step: Step = .welcome
    public private(set) var practice: Practice = .notTried
    public let asksDeveloper: Bool

    public init(hookStatuses: [HookInstallStatus]) {
        asksDeveloper = !hookStatuses.contains(.installed)
    }

    /// A first run left halfway picks up where it was left. Only the question
    /// is worth resuming at: a practice cannot carry on after a quit, so a
    /// walk left mid-practice starts again at the welcome, where Try it is.
    /// `stored` is a `resumePoint` raw value, or nil.
    public init(hookStatuses: [HookInstallStatus], resumingAt stored: String?) {
        self.init(hookStatuses: hookStatuses)
        if stored == Step.developer.rawValue, asksDeveloper { step = .developer }
    }

    /// What to save so a quit can be resumed (see `init(hookStatuses:resumingAt:)`).
    public var resumePoint: Step { step == .practice ? .welcome : step }

    /// The page dot lit in the window's footer: welcome, practice, question.
    public var dot: Int { Step.allCases.firstIndex(of: step) ?? 0 }
    public static let dots = Step.allCases.count

    public mutating func startPractice() {
        step = .practice
    }

    public mutating func practiceEnded(reached: Bool) -> AfterPractice {
        practice = reached ? .reached : .notReached
        guard asksDeveloper else {
            guard reached else {
                step = .welcome
                return .offerAgain
            }
            return .finish
        }
        step = .developer
        return .ask
    }

    /// The welcome's Skip: past the practice without trying it. The question
    /// is still asked when it would have been, because its answer decides
    /// whether the agents half of the app is there at all.
    public mutating func skipPractice() -> AfterPractice {
        guard asksDeveloper else { return .finish }
        step = .developer
        return .ask
    }

    /// 9d's Back: to the welcome, where Try it runs the practice again.
    public mutating func back() {
        step = .welcome
    }

    /// There is no default and no third way: the window's red button counts as
    /// finished without an answer, which leaves `AgentsPresence` deriving.
    public static func after(_ answer: Answer) -> AfterAnswer {
        answer == .yes ? .connectAgents : .done
    }

    /// Whether a first run gets this walk rather than the setup wizard. Only
    /// while the guide is on: the practice IS a guided task, and offering one
    /// the app cannot run would teach that the app does not work.
    public static func applies(guideEnabled: Bool) -> Bool { guideEnabled }

    /// How the welcome says to ask, from the ways that would actually work
    /// right now. The welcome used to print "Hold ⌥ Option" whatever key was
    /// set, including none.
    public enum AskWay: Equatable, Sendable {
        /// Hold this key (its display name) and speak.
        case hold(String)
        /// Press this shortcut and type.
        case type(String)
        /// Neither is switched on.
        case notOn

        /// - Parameters:
        ///   - holdKey: the ask key's name while holding it would ask, else nil.
        ///   - typeKey: the typed bar's shortcut while the bar is on, else nil.
        public init(holdKey: String?, typeKey: String?) {
            if let holdKey { self = .hold(holdKey) }
            else if let typeKey { self = .type(typeKey) }
            else { self = .notOn }
        }
    }

    /// The bundled goal the practice hands the guide. In the user's words, as
    /// any goal is, because the guide is the same guide.
    public static let practiceGoal = "Change my desktop wallpaper to a different picture"
}
