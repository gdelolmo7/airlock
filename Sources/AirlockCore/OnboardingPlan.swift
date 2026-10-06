import Foundation

/// What a fresh install still has to be walked through, and — the part actually
/// worth testing — whether to interrupt at all.
///
/// This exists because of `LSUIElement`. The app has no dock icon and opens no
/// window, so a first launch shows the user precisely nothing: indistinguishable
/// from a launch that failed. Worse, the one step that makes the product a
/// product rather than a clock — wiring the agent hooks — is a row inside a
/// settings window they have no reason to open.
///
/// Pure and value-typed, like `GutterBudget` and `NotchMetrics`: the navigation
/// bounds and the suppression rule are the two things here that can be wrong in
/// a way nobody notices, so they are the two things under test.
public struct OnboardingPlan: Equatable, Sendable {
    public enum Step: String, CaseIterable, Identifiable, Sendable {
        /// What the app is and *where* it is. A notch app is invisible until you
        /// hover over it, so being told is the only way to find out.
        case welcome
        /// Hook installation. Nominally skippable, in spirit not: without it
        /// there are no agent events, no approvals, and nothing to drive.
        case agents
        /// The parts that are not about agents at all — dictation, clipboard
        /// history, approval policy — and the keys that reach them.
        ///
        /// It earns a step of its own because these are off, or invisible, or
        /// both. Dictation ships disabled and its hold key is a bare modifier
        /// nobody would try on a hunch; the clipboard hotkey opens a panel that
        /// otherwise looks like a widget you have to hover for. A feature you
        /// cannot discover is one you did not ship.
        case features
        /// Calendar, plus a warning about the Automation prompt that would
        /// otherwise appear out of nowhere the first time you jump to a terminal.
        case permissions
        case finish

        public var id: String { rawValue }
    }

    public private(set) var index: Int

    public init(index: Int = 0) {
        self.index = Self.clamp(index)
    }

    /// A setup left halfway — Airlock quit, the Mac restarted — picks up at
    /// the step it was left on, not at the welcome again.
    ///
    /// `stored` is a step's raw value as last saved. Anything that does not
    /// name a step (nothing saved, a step renamed since) starts at the
    /// beginning: a resume that guesses is worse than one that starts over.
    public init(resumingAt stored: String?) {
        let step = stored.flatMap(Step.init(rawValue:)) ?? .welcome
        self.init(index: Step.allCases.firstIndex(of: step) ?? 0)
    }

    public var step: Step { Step.allCases[index] }
    /// 1-based, for the "setup · 2 of 5" counter the in-panel wizard prints.
    ///
    /// Derived rather than stored, and here rather than in the view, because
    /// the panel and the window both print it and an off-by-one that only one
    /// of them has is exactly the kind of thing nobody notices twice.
    public var position: Int { index + 1 }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { index == Step.allCases.count - 1 }
    public var stepCount: Int { Step.allCases.count }

    /// Clamped rather than trapping. These are driven by buttons whose disabled
    /// state is derived from `isFirst`/`isLast`, and a disabled-state bug should
    /// not be a crash.
    public mutating func advance() { index = Self.clamp(index + 1) }
    public mutating func retreat() { index = Self.clamp(index - 1) }

    public mutating func jump(to step: Step) {
        guard let target = Step.allCases.firstIndex(of: step) else { return }
        index = target
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(0, value), Step.allCases.count - 1)
    }

    /// Whether a launch should interrupt with setup.
    ///
    /// An already-`installed` hook suppresses it outright: that user wired
    /// themselves up through `agentic-notch-setup` or an earlier version, and
    /// greeting a working install with a setup wizard is worse than not greeting
    /// it at all.
    ///
    /// A `conflict` deliberately does **not** suppress. That install is broken —
    /// something in the agent's config file is in the way — and the agents step
    /// is exactly where there is room to say so.
    ///
    /// `leftHalfway` — a step was saved by a setup that never finished — also
    /// outranks an installed hook: connecting an agent is step two, so the
    /// person who did that and then quit is exactly the one to pick up again,
    /// not one to treat as having set themselves up some other way.
    public static func shouldPresent(hasCompletedSetup: Bool,
                                     hookStatuses: [HookInstallStatus],
                                     leftHalfway: Bool = false) -> Bool {
        if hasCompletedSetup { return false }
        if leftHalfway { return true }
        return !hookStatuses.contains(.installed)
    }
}
