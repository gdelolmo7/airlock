import Foundation

/// What happens to a gate the policy has left for a person: held for a card in
/// the notch, or handed straight back to the agent.
///
/// **Nothing hands gates back today.** It was set from the entitlement, so a
/// finished trial handed every question back to the agent's own terminal,
/// because the card that came up could not be answered. Nothing locks any
/// more, so the app always holds, and a plan change never takes an open card
/// away. The switch stays on `BridgeServer` for a plan limit that needs an
/// agent to ask in its own terminal instead.
///
/// Only what a person would answer. A deny rule, an allow rule and the risk
/// floor are settled before any card exists, and stay exactly as they were:
/// the floor still never approves anything — it hands back too, which is the
/// agent's own prompt, the place the floor sends things anyway.
public enum GateHolding: Equatable, Sendable {
    /// Held until it is answered from the notch, `ask_timeout` runs out, or its
    /// hook goes away.
    case holdForPerson
    /// Sent back on arrival with no decision (`deferToAgent`): no card, so
    /// nothing opens the island.
    case handBack
}
