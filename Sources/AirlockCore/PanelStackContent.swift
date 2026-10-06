import Foundation

/// How much of the selected tab the expanded panel draws, when something else
/// is claiming the panel.
///
/// The widget region normally holds the whole tab. Two things take it away: a
/// dictation hold, which owns the panel for the seconds a key is physically
/// down, and an ANSWER, which owns it for as long as it is up — 45s, or until
/// Escape. The answer's case DROPS the region rather than emptying it, and that
/// is load-bearing: a ScrollView is greedy vertically, so an emptied one still
/// claims the whole height budget, which measured as a two-line answer with a
/// screen of black underneath it.
///
/// `.attentionOnly` is why this is a tested rule rather than a condition inside
/// the view. It is a SAFETY rule, not a layout one: **a widget holding
/// something blocking is drawn whatever else owns the panel.** That is what
/// `NotchWidget.demandsAttention` promises — "switching a widget off is a
/// statement about clutter, not consent to hang" — and an answer sitting on top
/// of a permission gate broke it from a direction the widget contract could not
/// see. The card was not hidden by a toggle; it was not drawn at all. Not by
/// the gate hotkey either: `focusPendingGate` selects the Agents tab and
/// expands, and the tab it selected was suppressed too. The agent waited out
/// its `ask_timeout` behind an answer nobody had dismissed.
///
/// The answer is never destroyed to make room, because that is a worse bug than
/// the one being fixed: somebody asks a question, reads half the reply, and an
/// unrelated agent hitting a permission check deletes it. So the two share the
/// panel — the gate ABOVE, because it is the one with a deadline, and because
/// anything that will not fit is clipped from the bottom.
///
/// Dictation is the one deliberate exception. The key is physically held, the
/// window is a second or two, and the transcript is the only feedback the
/// gesture has anywhere on screen. Nothing is lost by waiting: releasing the
/// key runs `AssistantModel.ask`, which sets `isPresenting` synchronously, so
/// the very next evaluation lands on `.attentionOnly` and the card appears.
public enum PanelStackContent: Equatable, Sendable, CaseIterable {
    /// The selected tab's widgets, in full.
    case tab
    /// Only the widgets holding something blocking, drawn above the answer that
    /// owns the rest of the panel.
    case attentionOnly
    /// Nothing: something else owns the panel and nothing is blocking.
    case none

    /// - Parameter onboarding: first-run setup is running *in* the panel.
    ///   It takes the tab outright — the wizard is drawn where the widgets
    ///   would be, and a stack underneath it would be competing with the thing
    ///   it is explaining, in a height budget that does not stretch to both.
    ///
    ///   Checked FIRST, and deliberately still subject to the attention rule
    ///   above: a widget holding something blocking is drawn whatever else owns
    ///   the panel, and "whatever else" now includes setup. That case is rare
    ///   by construction — the hooks that produce gates are what the agents
    ///   step installs — but a rare way to strand a waiting agent is still a
    ///   way to strand one, and this is the rule that promised it would not
    ///   happen.
    public static func resolve(dictating: Bool,
                               answering: Bool,
                               demandsAttention: Bool,
                               onboarding: Bool = false,
                               guiding: Bool = false,
                               typing: Bool = false,
                               askingYou: Bool = false) -> PanelStackContent {
        // The guide takes the panel the way setup does, and yields to a gate
        // the same way: an agent stopped behind a card outranks a DNS record.
        if onboarding || guiding { return demandsAttention ? .attentionOnly : .none }
        // The transcript owns the panel outright — see the exception above.
        // `.none`, not an emptied `.tab`: the emptied region was kept so the
        // panel would not resize as you spoke, and the cost was the biggest
        // dark panel the app draws for a two-second hold. Since 2026-10-01 the
        // panel is the transcript and nothing else, growing a line at a time.
        if dictating { return .none }
        // The typing bar summoned by its hotkey opens an EMPTY notch: a text
        // field and nothing under it. The owner's words on seeing it drawn over
        // the whole Home tab (2026-10-01): "it opens the entire thing … it
        // should open an empty notch." A gate still outranks it, as always.
        if typing || answering { return demandsAttention ? .attentionOnly : .none }
        // The panel opened BECAUSE an agent is asking, so the question is the
        // whole panel: the other sessions, the branch row and the prompt bar
        // are a tab's worth of reading between you and the card. The owner's
        // call, 2026-10-01: "instead of showing everything from the tab, show
        // only the question(s)". Opening the tab yourself still draws all of
        // it — `askingYou` is only ever set by the gate's own arrival.
        //
        // `.tab` once nothing is blocking, never `.none`: the flag outliving its
        // gate by one evaluation must cost a full tab, not an empty panel.
        if askingYou { return demandsAttention ? .attentionOnly : .tab }
        return .tab
    }
}
