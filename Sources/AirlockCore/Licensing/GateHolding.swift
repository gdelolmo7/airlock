import Foundation

/// What happens to a gate the policy has left for a person: held for a card in
/// the notch, or handed straight back to the agent.
///
/// Decided here, from the entitlement alone, so the bridge never has to know
/// what a licence is — the app sets it on `BridgeServer` whenever the
/// entitlement changes.
///
/// **A finished trial used to hold it anyway.** The card that came up could
/// not be answered — its buttons were a subscription ask — while the agent sat
/// in its terminal showing nothing, because Claude Code only puts its own
/// prompt up once the hook lets go. That happened on the card's × or at
/// `ask_timeout`, five minutes later by default. Handed back on arrival, the
/// agent asks in its terminal straight away, as it would without Airlock.
///
/// Only what a person would answer. A deny rule, an allow rule and the risk
/// floor are settled before any card exists, and stay exactly as they were:
/// the floor still never approves anything — it hands back too, which is the
/// agent's own prompt, the place the floor sends things anyway.
///
/// The kind of gate does not change the answer. A command, an edit and a
/// question from any agent whose hooks wait would all sit on a card nobody can
/// answer from the notch.
public enum GateHolding: Equatable, Sendable {
    /// Held until it is answered from the notch, `ask_timeout` runs out, or its
    /// hook goes away.
    case holdForPerson
    /// Sent back on arrival with no decision (`deferToAgent`): no card, so
    /// nothing opens the island.
    case handBack

    /// Tied to `allowsUse` rather than to `.trialExpired` by name, so the one
    /// state that stops the app and the one that stops holding gates cannot
    /// drift apart.
    public init(_ entitlement: Entitlement) {
        self = entitlement.allowsUse ? .holdForPerson : .handBack
    }
}
