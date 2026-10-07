import Foundation

/// Hidden, compact, or expanded — the island's whole visual state.
///
/// This is a **user-set product rule**, not an implementation detail, which is
/// why it lives here with tests rather than as an if-else chain inside the
/// controller: *the island expands on its own ONLY when a user action is
/// required to continue.* Everything else it has to say, it says compact.
///
/// The rule exists because the notch is somewhere the pointer crosses on its
/// way to the menu bar. An island that opened for a finished build, a new
/// track, or a passing cursor is one that is in the way — and this app is
/// pinned to the top of the screen, where being in the way is unforgivable.
///
/// So content NEVER expands. A session running, music playing, a meeting
/// approaching: all compact. Expansion is only ever something a person did
/// (tapped, pressed the hotkey, held the dictation key) or something waiting on
/// them (a blocking gate, an answer on screen).
public enum IslandPresentation: Comparable, Sendable, CaseIterable {
    /// Ordered smallest to largest on purpose: "is the panel about to shrink out
    /// from under the pointer" is then a comparison rather than a pair of
    /// equality checks that a fourth case would silently outgrow.
    case hidden
    case compact
    case expanded

    /// Reasons the panel is currently held open. Any one of them is enough.
    ///
    /// An option set rather than a pile of booleans because "which of these is
    /// true" is never the question — "is any" is. Naming them individually at
    /// the call site is what let a stray one be forgotten from the condition.
    public struct Holds: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Pinned by a tap, the status menu, or an arriving gate. Survives the
        /// pointer leaving.
        public static let pinned = Holds(rawValue: 1 << 0)
        /// A hover peek. Falls away on exit.
        public static let peeked = Holds(rawValue: 1 << 1)
        /// Opened by the clipboard hotkey.
        public static let hotkey = Holds(rawValue: 1 << 2)
        /// A dictation key is down.
        public static let dictating = Holds(rawValue: 1 << 3)
        /// An answer is on screen, outliving the gesture that asked for it.
        public static let answering = Holds(rawValue: 1 << 4)
        /// The media timeline is being dragged. A scrub that overshoots the
        /// panel's edge still reports the pointer as gone, and the 450ms
        /// hover-out grace would then collapse the panel out from under a
        /// gesture still in progress — the bar disappearing mid-drag, and the
        /// seek you were aiming at abandoned rather than made.
        public static let scrubbing = Holds(rawValue: 1 << 5)
        /// First-run setup is running *in* the panel.
        ///
        /// The wizard explains the panel while standing in it, so the collapse
        /// timer would otherwise eat the lesson mid-sentence — and unlike every
        /// hold above it, no gesture is holding it up. It is released only when
        /// setup finishes or is skipped, which is why `NotchController` clears
        /// it on the same paths that set `hasCompletedSetup`.
        ///
        /// It also has to outlast focus leaving the app: the permissions step
        /// raises system dialogs of macOS's own, and a panel that collapsed
        /// behind one would strand the wizard.
        public static let onboarding = Holds(rawValue: 1 << 6)
        /// The guide's own surface is up: the first look's "Looking at your
        /// screen…" panel, the card under the notch (layout B), or the sentence
        /// a guide that ended on its own leaves behind. Like onboarding, no
        /// gesture props it up, and it must survive focus going to the app
        /// being guided — that is where the user is supposed to be looking.
        public static let guiding = Holds(rawValue: 1 << 7)
        /// A new version's "what's new" card is up (`WhatsNew`). The one other
        /// hold no gesture props up: the card opens the panel by itself at
        /// launch, when nobody is pointing at it, and has to stay until it is
        /// read — "Got it" or an explicit collapse releases it.
        public static let notes = Holds(rawValue: 1 << 8)
    }

    /// `hasContent` means there is something worth showing compact — a session,
    /// music, a meeting inside its glance window. It is deliberately NOT a
    /// reason to expand.
    ///
    /// `hasTargetScreen` is false when the lid is shut and the external-display
    /// fallback is off. It outranks everything: there is nowhere to draw.
    /// The island used to hide itself when it had nothing to say, and that was
    /// reported as a crash four times — most sharply when "pause the music"
    /// removed the artwork that was the island's only content, so a command
    /// that worked perfectly made the notch vanish.
    ///
    /// The fix is one rung lower, in `CompactSlot.idle`: the ladder now always
    /// has something to draw, so wherever the island may rest it rests, and
    /// `hasContent` no longer decides whether it exists.
    ///
    /// **Resting became conditional with the external display — the case the
    /// linger was kept for.** `canRest` is false on a monitor without a camera
    /// housing while its menu bar is hidden — a full-screen app in front, or
    /// auto-hide (`VirtualCutout.canRest`) — because there the island would sit
    /// on top of somebody's window. It rests HIDDEN there, and three things
    /// still bring it up: a hold, which expands it as anywhere else;
    /// `awaitingOwner`, a gate or question nobody has answered, which keeps it
    /// compact after its panel is collapsed, since the amber dot is then the
    /// only sign of a blocked agent left on screen; and `linger`, so a panel
    /// that closes lands on the island and fades rather than blinking out.
    ///
    /// Content is deliberately NOT one of them. Agent sessions run all day for
    /// the person this was built for, so "content keeps it up" would mean
    /// "always up", over every full-screen window — the one thing `canRest`
    /// exists to stop.
    public static let linger: TimeInterval = 4

    /// - Parameters:
    ///   - canRest: false where resting would cover a window; see above.
    ///     Defaults to true, the notch, where it always may.
    ///   - awaitingOwner: a gate or a question is still unanswered.
    ///   - pointerAtTop: the pointer is at the top edge where the island cannot
    ///     rest (`TopEdgeReveal`), or on the island itself. Brings it up
    ///     compact, as the menu bar comes down, and never expands it. Not a
    ///     reason `LastShown` records: it goes when the pointer goes, without a
    ///     linger, like the menu bar.
    ///   - lastShown: `LastShown.date` — when the island last had a reason to
    ///     be up where it cannot rest. Nil means it never has, so there is
    ///     nothing to linger from.
    ///   - now: passed in, never read here. Core does not own a clock, and a
    ///     rule that did could not be tested at the boundary.
    public static func resolve(hasTargetScreen: Bool,
                               canRest: Bool = true,
                               holds: Holds,
                               hasContent: Bool,
                               awaitingOwner: Bool = false,
                               pointerAtTop: Bool = false,
                               lastShown: Date? = nil,
                               // `.distantFuture` makes the linger branch false
                               // for callers that do not pass a clock.
                               now: Date = .distantFuture) -> IslandPresentation {
        guard hasTargetScreen else { return .hidden }
        // Even with nothing to show: the status-menu toggle has to be able to
        // open an empty panel, or there is no way back to settings.
        if !holds.isEmpty { return .expanded }
        // Compact whether or not there is anything to say. `hasContent` still
        // decides what the slots DRAW — that distinction is intact and tested —
        // but it does not decide whether the island exists, here or below.
        _ = hasContent
        if canRest || awaitingOwner || pointerAtTop { return .compact }
        if let lastShown, now < lastShown.addingTimeInterval(linger) { return .compact }
        return .hidden
    }

    /// When the island should be re-evaluated because its linger runs out, or
    /// nil when nothing is lingering — it may rest, or it still has a reason.
    ///
    /// Returned rather than scheduled here for the same reason `now` is a
    /// parameter: `apply` is driven by events, so without a wake at this
    /// instant the island would sit in `.compact` until something unrelated
    /// happened to move. Exactly the instant `resolve` turns `.hidden`.
    public static func lingerDeadline(canRest: Bool,
                                      holds: Holds,
                                      awaitingOwner: Bool,
                                      lastShown: Date?) -> Date? {
        guard !canRest, holds.isEmpty, !awaitingOwner, let lastShown else { return nil }
        return lastShown.addingTimeInterval(linger)
    }

    /// When the island last had a reason to be up — a hold, or something
    /// awaiting the owner. The instant `linger` counts from.
    ///
    /// A value with one bit of memory rather than a bare `Date?`, because the
    /// stamp has an edge. `apply` runs on events, not on a clock, so the last
    /// pass that SAW a hold can be long before the pass that sees it gone: a
    /// panel pinned and read in silence for a minute, then closed. Stamped only
    /// while a reason is visible, the linger would count from that old pass and
    /// be over before it began — the panel would close to nothing instead of to
    /// the island. So the first pass WITHOUT a reason stamps as well.
    ///
    /// Content never stamps it, for the reason under `linger`. Nor does a
    /// peek: it is the pointer resting on the island, so it goes when the
    /// pointer goes, like `pointerAtTop`. Lingering after one kept the island
    /// over a full-screen video for four seconds after the owner moved away,
    /// long enough for the next pass near the top to bring it straight back
    /// (2026-10-05).
    public struct LastShown: Equatable, Sendable {
        public private(set) var date: Date?
        private var hadReason = false

        public init() {}

        public mutating func record(holds: Holds, awaitingOwner: Bool, now: Date) {
            let reason = !holds.subtracting(.peeked).isEmpty || awaitingOwner
            if reason || hadReason { date = now }
            hadReason = reason
        }
    }
}
