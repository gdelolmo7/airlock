import Foundation

/// How much of the selected tab the expanded panel draws, when something else
/// is claiming the panel.
///
/// The widget region normally holds the whole tab. Three things take it away:
/// a dictation hold, which owns the panel for the seconds a key is physically
/// down; first-run setup, drawn where the widgets would be; and a gate's own
/// arrival, which narrows the Agents tab to the question. Taking the region
/// DROPS it rather than emptying it, and that is load-bearing: a ScrollView is
/// greedy vertically, so an emptied one still claims the whole height budget,
/// which measured as a few lines of content with a screen of black under them.
///
/// `.attentionOnly` is why this is a tested rule rather than a condition inside
/// the view. It is a SAFETY rule, not a layout one: **a widget holding
/// something blocking is drawn whatever else owns the panel.** That is what
/// `NotchWidget.demandsAttention` promises — "switching a widget off is a
/// statement about clutter, not consent to hang". A card that is not drawn at
/// all strands its agent until `ask_timeout`, and the gate hotkey cannot help:
/// `focusPendingGate` selects the Agents tab and expands, and a suppressed tab
/// stays suppressed.
///
/// Dictation is the one deliberate exception. The key is physically held, the
/// window is a second or two, and the transcript is the only feedback the
/// gesture has anywhere on screen. Nothing is lost by waiting: the moment the
/// key comes up the next evaluation lands on `.tab` and the card is drawn.
public enum PanelStackContent: Equatable, Sendable, CaseIterable {
    /// The selected tab's widgets, in full.
    case tab
    /// Only the widgets holding something blocking, drawn above whatever owns
    /// the rest of the panel.
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
                               demandsAttention: Bool,
                               onboarding: Bool = false,
                               askingYou: Bool = false) -> PanelStackContent {
        if onboarding { return demandsAttention ? .attentionOnly : .none }
        // The transcript owns the panel outright — see the exception above.
        // `.none`, not an emptied `.tab`: the emptied region was kept so the
        // panel would not resize as you spoke, and the cost was the biggest
        // dark panel the app draws for a two-second hold. Since 2026-10-01 the
        // panel is the transcript and nothing else, growing a line at a time.
        if dictating { return .none }
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
