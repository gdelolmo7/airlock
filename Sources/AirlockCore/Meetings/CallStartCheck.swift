import Foundation

/// How the other side of the last call went, kept between calls so that
/// Settings › Permissions can say it and the next call can expect it.
///
/// **Why a memory rather than a check.** The other side of a call comes
/// through "System Audio Recording", and macOS has no public way to ask
/// whether that is allowed. A refusal does not fail: the call's sound keeps
/// arriving and every sample of it is zero. So the only honest answer is
/// what happened the last time sound was asked for, and before any call it
/// is "not tried yet" rather than a guess.
public enum OtherSideHistory: String, Equatable, Sendable {
    /// The call's sound carried something: the permission is on.
    case worked
    /// The call's sound was all zeros for `CallChannelHealth.permissionLimit`.
    case refused

    public static let key = "callNotes.otherSide"

    /// Nil before any call has tried.
    public static func read(_ defaults: UserDefaults = .standard) -> OtherSideHistory? {
        defaults.string(forKey: key).flatMap(OtherSideHistory.init(rawValue:))
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }
}

/// The short check at the top of the call card when notes start: whether
/// your side and the other side are both being written down.
///
/// All good, it shows two ticks for `allGoodFor` and goes. A refusal stays
/// until it is fixed, because a half-written call is what it
/// prevents. Nothing heard either way after `giveUpAfter` (nobody has talked
/// yet) and it goes quietly: the call card's own lines still say a side is
/// missing once the other one talks (`CallChannelHealth`).
///
/// It never opens the notch: it lives inside a card that is already there.
/// Pure, and fed on each look by the model.
public struct CallStartCheck: Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        case waiting
        case heard
        case refused
    }

    public static let allGoodFor: TimeInterval = 5
    public static let giveUpAfter: TimeInterval = 30

    public private(set) var you: Mark = .waiting
    /// Nil in the room, where the microphone is everybody.
    public private(set) var them: Mark?
    public private(set) var isShowing = true

    private var startedAt: Date?
    private var allGoodAt: Date?
    /// Done showing, for good unless a refusal brings it back.
    private var finished = false

    public init(inPerson: Bool = false) {
        them = inPerson ? nil : .waiting
    }

    public var hasRefusal: Bool { you == .refused || them == .refused }

    /// One look.
    /// - `lastCallRefused`: the last call's other side was refused
    ///   (`OtherSideHistory`), so until this call's sound proves otherwise
    ///   it is expected to be refused again, and said at once rather than
    ///   after 45 seconds of silence.
    public mutating func update(micHeard: Bool, micRefused: Bool,
                                theirsHeard: Bool, theirsNotAllowed: Bool,
                                lastCallRefused: Bool, now: Date) {
        let start = startedAt ?? now
        startedAt = start
        you = micRefused ? .refused : micHeard ? .heard : .waiting
        if them != nil {
            them = theirsHeard ? .heard
                : (theirsNotAllowed || lastCallRefused) ? .refused : .waiting
        }
        if hasRefusal {
            allGoodAt = nil
            isShowing = true
            return
        }
        if you == .heard, them ?? .heard == .heard {
            let at = allGoodAt ?? now
            allGoodAt = at
            if now.timeIntervalSince(at) >= Self.allGoodFor { finished = true }
        } else if now.timeIntervalSince(start) >= Self.giveUpAfter {
            finished = true
        }
        isShowing = !finished
    }
}
