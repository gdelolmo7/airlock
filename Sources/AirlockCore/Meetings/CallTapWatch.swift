import Foundation

/// Notices the call's own sound going dead while the call goes on, and says
/// what to do about it.
///
/// The call tap (`CallAudioTap`) listens only to the call app's processes,
/// and on a FaceTime call it once went quiet a minute in and stayed quiet:
/// no error, no rebuild, the other side simply gone from the notes. Nothing
/// on the call tap's side can tell that from the other side falling silent.
/// Two things can:
/// - **The speakers.** A second tap hears everything the Mac plays
///   (`SpeakersTap`), so a voice coming out of the Mac while the call tap
///   reads nothing is the call tap's fault.
/// - **The call app still playing.** On a WhatsApp call both taps went deaf
///   to the call at once, after a hiccup in the Mac's sound, while WhatsApp
///   played on for half an hour. A live call is never pure digital silence
///   (a working call tap hears something every second, even between words),
///   so the call app playing while the call tap reads nothing for
///   `quietLimit` is the call tap's fault too, and the speakers tap's, which
///   heard no voice either.
///
/// Looked at once a second. Each step only while it holds:
/// 1. **Start the call tap again** from scratch, once the call tap has heard
///    nothing for `quietLimit` and either the Mac has played a voice for
///    half of the last `window` looks or the call app is playing. The
///    speakers tap is started again with it when it heard no voice either
///    (`restartBoth`).
/// 2. **Listen to the speakers instead**, if the call tap is still quiet
///    `retryAfter` later while the speakers hear a voice. Everything the Mac
///    plays is a worse source than the call app alone (a song in another app
///    would be written down too) and a far better one than nothing, which is
///    what the other side gets otherwise, since the microphone has the
///    speakers taken out of it. It lasts for the rest of the notes.
/// 3. **Start both again**, `retryAfter` later and then every `retryEvery`,
///    while neither hears the call and the call app plays on: there is
///    nothing better to switch to, and a restart costs a moment of a call
///    that is already lost.
///
/// The call tap hearing anything puts the count back to the start.
public struct CallTapWatch: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case restartCallTap
        /// The call tap and the speakers tap, both deaf to the call.
        case restartBoth
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
    /// How often both taps are started again once two restarts brought
    /// nothing back.
    public static let retryEvery: TimeInterval = 60

    private var speaking: [Bool] = []
    private var restartedAt: Date?
    public private(set) var restarts = 0
    public private(set) var usingSpeakers = false

    public init() {}

    /// `callTapSince`: when the call tap started (or last restarted);
    /// `callTapLastSound`: the last time it delivered a sample above zero;
    /// `speakersSpeaking`: whether the Mac played a voice since the last look;
    /// `callAppPlaying`: whether the call app is playing sound now, asked
    /// only once the call tap has been quiet for `quietLimit`.
    public mutating func look(now: Date, callTapSince: Date, callTapLastSound: Date?,
                              speakersSpeaking: Bool, callAppPlaying: () -> Bool) -> Action {
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
        guard quiet else { return .none }
        let voice = speaking.filter({ $0 }).count >= Self.speakingLooks
        guard voice || callAppPlaying() else { return .none }
        if let restartedAt {
            // Switching to the speakers never waits longer than the first
            // retry; only the blind restarts slow down.
            let wait = voice || restarts < 2 ? Self.retryAfter : Self.retryEvery
            if now.timeIntervalSince(restartedAt) < wait { return .none }
        }
        if voice && restarts > 0 {
            usingSpeakers = true
            return .useSpeakers
        }
        restarts += 1
        restartedAt = now
        return voice ? .restartCallTap : .restartBoth
    }
}
