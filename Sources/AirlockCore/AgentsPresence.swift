import Foundation

/// Whether the agent surfaces — the Agents tab, the session glyphs in the
/// compact island, the Claude usage KPI — belong on this Mac at all.
///
/// The product is an agent driver, but the app around it grew a clipboard, a
/// file shelf, dictation, a calendar and media, and plenty of people who want
/// those have never run a coding agent. For them the Agents tab is a
/// permanently empty room and the usage strip is a "set up" pill advertising
/// something they did not come for.
///
/// So the surfaces are optional. What keeps that from being one more switch
/// nobody finds is the **default**: a hook wired into an agent's own config
/// file is the one honest signal that somebody drives agents, so it decides —
/// right up until the user says otherwise, at which point what they said is the
/// whole answer and no later install or uninstall overrides it.
///
/// Pure and value-typed like `OnboardingPlan`, and for the same reason: this is
/// a handful of lines that would otherwise be verified by installing hooks and
/// watching a tab appear.
public struct AgentsPresence: Equatable, Sendable {
    /// Why the answer is what it is.
    ///
    /// Carried rather than reduced straight to a `Bool` because the settings
    /// pane has to say it out loud. A switch that quietly defaulted itself is
    /// one the user will assume they set — and then be surprised by on the Mac
    /// where it landed the other way.
    public enum Basis: Equatable, Sendable {
        /// The user set the switch. Nothing else gets a vote.
        case chosen(Bool)
        /// Never asked, and an agent's config points at us.
        case hooksInstalled
        /// Never asked, and no agent config mentions us.
        case noHooksInstalled

        public var showsAgents: Bool {
            switch self {
            case .chosen(let on): return on
            case .hooksInstalled: return true
            case .noHooksInstalled: return false
            }
        }

        /// True while a hook install or uninstall can still move the switch.
        public var isDerived: Bool {
            if case .chosen = self { return false }
            return true
        }
    }

    /// `choice` is nil until the user touches the switch.
    ///
    /// That tri-state is the whole reason a plain stored `Bool` would not do:
    /// it cannot tell "off because they said so" from "off because nobody has
    /// been asked yet", and only the second one should follow the hooks.
    /// `UserDefaults.object(forKey:) as? Bool` gives exactly this for free.
    public static func basis(choice: Bool?, hookStatuses: [HookInstallStatus]) -> Basis {
        if let choice { return .chosen(choice) }
        return hookStatuses.contains(where: isWiredUp) ? .hooksInstalled : .noHooksInstalled
    }

    public static func resolve(choice: Bool?, hookStatuses: [HookInstallStatus]) -> Bool {
        basis(choice: choice, hookStatuses: hookStatuses).showsAgents
    }

    /// A conflict counts as wired up.
    ///
    /// It means the agent's config already names us *without* our managed block
    /// around it, which only happens to somebody who has been wiring an agent
    /// up. Hiding the tab over it would hide the one screen that explains how to
    /// fix it — the same call `OnboardingPlan.shouldPresent` makes, for the same
    /// reason.
    private static func isWiredUp(_ status: HookInstallStatus) -> Bool {
        switch status {
        case .installed, .conflict: return true
        case .notInstalled: return false
        }
    }
}
