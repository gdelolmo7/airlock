import Foundation

/// Something else the person did while the dictation key was held: a scroll,
/// a key or a click, or a second modifier joining the first.
///
/// **This used to end every hold, and it threw the words away.** Each of
/// these was read as "that was a chord, not speech", so the hold was
/// discarded: the notch closed and everything said so far was gone, not
/// typed and not copied. Live, 2026-10-15, that was a sentence lost to a
/// two-finger scroll on the trackpad while talking.
///
/// The chord reading is still right for a hold that has heard nothing — ⌃C,
/// ⌥⌫ to delete a word, ⌃-click for the context menu — and wrong for one that
/// has: somebody who has been talking for ten seconds is dictating, whatever
/// their other hand does. What decides it is whether there are words yet.
public enum HoldInterruption: String, Equatable, Sendable, CaseIterable {
    /// The trackpad or the wheel. Never a reason to stop: it moves the view,
    /// not the cursor, so where the words will be typed has not changed.
    case scroll
    /// A key went down, or a mouse button. Either can move the cursor or
    /// open something, so words heard before it are copied, never typed.
    case keyOrClick
    /// Another of ⌃⌥⌘⇧ joined the held key — a shortcut, if nothing was said.
    case modifier

    /// What one interruption does to the hold.
    public enum Verdict: Equatable, Sendable {
        /// Keep listening as if nothing happened.
        case carryOn
        /// Keep listening, and put the words on the clipboard at the end
        /// instead of typing them: the key or click may have moved where
        /// typing would land, or opened a menu that would swallow it.
        case carryOnThenCopy
        /// It was a chord. End the hold and keep nothing — there is nothing
        /// to keep, and typing a stray word into the shortcut's target is the
        /// bug the chord check was written for.
        case discard
    }

    /// How long the second half of a chord follows the first. ⌃C, ⌥⌫ and
    /// ⌃-click come within a moment of the modifier going down; a key after
    /// this, with a voice on the microphone, comes from somebody talking.
    public static let chordWindow: TimeInterval = 1.5
    /// A peak above room noise and below anyone speaking at the Mac. Chosen,
    /// not measured on many microphones: it only has to tell a silent hold
    /// from a spoken one.
    public static let voiceLevel: Float = 0.02

    /// Whether the hold should count as dictation when something interrupts
    /// it. Words are the best sign, but the recogniser is a beat behind the
    /// voice, and on a slower Mac more than a beat: a key pressed two
    /// seconds into a sentence used to land before the first word and throw
    /// the whole hold away, with no message. Its words now go to the
    /// clipboard, which is the safe side for a key that was a shortcut after
    /// all.
    public static func soundsLikeTalking(heardWords: Bool, heldFor: TimeInterval, peak: Float) -> Bool {
        heardWords || (heldFor >= chordWindow && peak >= voiceLevel)
    }

    public func verdict(heardWords: Bool) -> Verdict {
        switch self {
        case .scroll:
            return .carryOn
        case .keyOrClick, .modifier:
            return heardWords ? .carryOnThenCopy : .discard
        }
    }
}

/// What the interruptions of one hold add up to.
///
/// A value per hold, captured when the hold finishes, so a delivery that runs
/// after the next hold has started still reads its own.
public struct HoldInterruptions: Equatable, Sendable {
    /// A scroll came during the hold.
    public private(set) var scrolled = false
    /// A key, click or modifier came after words were heard: the words go to
    /// the clipboard, not to the cursor.
    public private(set) var copiesInstead = false

    public init() {}

    /// Note one interruption and say what it does.
    public mutating func note(_ input: HoldInterruption, heardWords: Bool) -> HoldInterruption.Verdict {
        let verdict = input.verdict(heardWords: heardWords)
        switch verdict {
        case .carryOn: break
        case .carryOnThenCopy: copiesInstead = true
        case .discard: return verdict
        }
        if input == .scroll { scrolled = true }
        return verdict
    }

    /// A hold that scrolled and heard nothing ends without a card.
    ///
    /// ⌃-scroll is the screen zoom, and a scroll no longer ends a hold, so
    /// zooming with the dictation key held now runs a hold to its release.
    /// Answering every zoom with "Didn't catch anything" would be nagging
    /// about a gesture that was never meant as dictation.
    public var endsQuietlyWhenSilent: Bool { scrolled }
}
