import Foundation

/// Notices the call's own sound going dead while the Mac is still playing a
/// voice, and says what to do about it.
///
/// The call tap (`CallAudioTap`) listens only to the call app's processes,
/// and on a FaceTime call it once went quiet a minute in and stayed quiet:
/// no error, no rebuild, the other side simply gone from the notes. Nothing
/// on the call tap's side can tell that from the other side falling silent.
/// The speakers can: a second tap hears everything the Mac plays
/// (`SpeakersTap`), so a voice coming out of the Mac while the call tap reads
/// nothing is the call tap's fault.
///
/// Looked at once a second. Two steps, each only while it holds:
/// 1. **Start the call tap again** from scratch, once the Mac has played a
///    voice for half of the last `window` looks and the call tap has heard
///    nothing for `quietLimit`.
/// 2. **Listen to the speakers instead**, if it holds again `retryAfter`
///    later. Everything the Mac plays is a worse source than the call app
///    alone (a song in another app would be written down too) and a far
///    better one than nothing, which is what the other side gets otherwise,
///    since the microphone has the speakers taken out of it. It lasts for
///    the rest of the notes.
///
/// The call tap hearing anything puts the count back to the start.
public struct CallTapWatch: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case restartCallTap
        case useSpeakers
    }

    /// Looks remembered, and how many of them must have had the Mac playing
    /// a voice.
    public static let window = 10
    public static let speakingLooks = 5
    /// How long the call tap must have heard nothing.
    public static let quietLimit: TimeInterval = 10
    /// After a restart, how long before the next step may be taken: the tap
    /// gets time to come back.
    public static let retryAfter: TimeInterval = 20

    private var speaking: [Bool] = []
    private var restartedAt: Date?
    public private(set) var restarts = 0
    public private(set) var usingSpeakers = false

    public init() {}

    /// `callTapSince`: when the call tap started (or last restarted);
    /// `callTapLastSound`: the last time it delivered a sample above zero;
    /// `speakersSpeaking`: whether the Mac played a voice since the last look.
    public mutating func look(now: Date, callTapSince: Date, callTapLastSound: Date?,
                              speakersSpeaking: Bool) -> Action {
        speaking.append(speakersSpeaking)
        if speaking.count > Self.window { speaking.removeFirst(speaking.count - Self.window) }
        guard !usingSpeakers else { return .none }

        let heard = max(callTapLastSound ?? callTapSince, callTapSince)
        let quiet = now.timeIntervalSince(heard) >= Self.quietLimit
        if callTapLastSound.map({ now.timeIntervalSince($0) < Self.quietLimit }) == true {
            // Sound again: whatever happened before is over.
            restarts = 0
            restartedAt = nil
        }
        guard quiet, speaking.filter({ $0 }).count >= Self.speakingLooks else { return .none }
        if let restartedAt, now.timeIntervalSince(restartedAt) < Self.retryAfter { return .none }
        if restarts == 0 {
            restarts += 1
            restartedAt = now
            return .restartCallTap
        }
        usingSpeakers = true
        return .useSpeakers
    }
}
