import Foundation

/// What the notch does with a proposal once the policy engine has spoken.
///
/// Pure, so the interesting combinations — an allow rule under the risk floor,
/// an expired trial holding a perfectly legal action — are decided somewhere a
/// test can reach rather than inside a view that needs a microphone to enter.
public enum VoiceActionOutcome: Sendable, Equatable {
    /// Do it now, no card. The rule is carried for the gate log.
    case perform(rule: String)
    /// Show the card. `risk` is set when the built-in floor triggered, and
    /// `always` is the rule an Always click would write — **nil when the floor
    /// forbids offering one at all**, which is how a card stops promising a
    /// button that would be refused.
    case ask(risk: String?, always: RuleCandidate?)
    /// A deny rule refused it. The card says which, and there is nothing to
    /// click: a denial the user can override with a button is not a denial.
    case refused(rule: String)
    /// A finished trial. Answering questions carries on; performing does not.
    case blocked

    public var performsImmediately: Bool {
        if case .perform = self { return true }
        return false
    }

    /// `offersStandingPermission` is **provenance, not politeness.**
    ///
    /// `VoiceAction.toolName` states why every tool here is `Voice.`-prefixed:
    /// "a standing permission should say on its face that it was granted to a
    /// microphone." A rule written from a keyboard lands in that same namespace
    /// and makes it a lie — `Voice.AudioOutput(Kitchen TV)` would then mean
    /// "somebody typed this once", which is not what anyone reading their
    /// `policy.yaml` will take it to mean.
    ///
    /// So the typed path passes false and simply gets no Always button. It is
    /// the *writing* that is withheld, never the reading: a typed command still
    /// performs immediately under a rule that already exists, because a keyboard
    /// is not a lower-trust channel than a microphone — it is a differently
    /// named one, and only the name is at stake here.
    public static func resolve(verdict: PolicyVerdict,
                               for request: PermissionRequest,
                               isEntitled: Bool,
                               offersStandingPermission: Bool = true) -> VoiceActionOutcome {
        // FIRST, and above even a deny rule, because it is not about this
        // action: an unentitled app performs nothing, and saying so plainly
        // beats a card whose buttons do nothing. `.trialExpired` is the only
        // state that reaches here — every other licence state allows use.
        guard isEntitled else { return .blocked }

        switch verdict {
        case .deny(let rule):
            return .refused(rule: rule)
        case .allow(let rule):
            return .perform(rule: rule)
        case .ask(let risk):
            // The floor and the Always button are the same question asked
            // twice, so they are answered in one place. Offering Always on a
            // floored action would write a rule that `PolicyEngine` then
            // ignores forever — a button that appears to work and does not.
            //
            // Provenance is the second reason a card may withhold it, and the
            // two are deliberately ANDed rather than ranked: the floor is about
            // what the action does, provenance is about who is asking, and
            // either one alone is enough to mean no rule gets written.
            let always = risk == nil && offersStandingPermission
                ? RuleGeneralizer.recommended(for: request) : nil
            return .ask(risk: risk, always: always)
        }
    }
}
