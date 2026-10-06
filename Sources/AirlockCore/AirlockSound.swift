import Foundation

/// Airlock's four sounds (card D1), and which moments get them (card D2).
///
/// One family, made for this app: the files are `Resources/Sounds/<name>.wav`
/// and `SOURCE.md` beside them says where they come from. Which moment plays
/// which is decided here, where it can be tested; playing them is the app's.
public enum AirlockSound: String, CaseIterable, Sendable {
    /// A request or a question waiting on you. The most recognisable of the
    /// four, and the one sound that may be swapped for a Mac sound.
    case needsYou
    /// An agent finished, or the guide reached the goal.
    case done
    /// You approved a request. Heard often, so almost nothing.
    case approved
    /// Something stopped and needs you: the guide gave up.
    case wentWrong

    /// The file name in the app's resources, without the extension.
    public var resourceName: String {
        switch self {
        case .needsYou: "AirlockNeedsYou"
        case .done: "AirlockDone"
        case .approved: "AirlockApproved"
        case .wentWrong: "AirlockWentWrong"
        }
    }

    /// "Only important" plays these two and nothing else.
    public var isImportant: Bool {
        switch self {
        case .needsYou, .done: true
        case .approved, .wentWrong: false
        }
    }

    /// Which one wins when two land together. Needs you first: it is the one
    /// with somebody waiting behind it. Approved last: you just did it.
    public var rank: Int {
        switch self {
        case .needsYou: 3
        case .wentWrong: 2
        case .done: 1
        case .approved: 0
        }
    }
}

extension Moment {
    /// The sound this moment plays, if any. Everything not named here is
    /// silent at every level: copying, tabs, the island opening — things you
    /// did, or saw, a moment ago. Touch covers some of those (`tick`).
    public var sound: AirlockSound? {
        switch self {
        case .gateArrived: .needsYou
        case .agentFinished, .guideDone: .done
        case .approved: .approved
        case .agentFailed, .guideEnded: .wentWrong
        case .denied,
             .guideStep, .guideLost,
             .pointerArrived, .islandOpened, .islandClosed, .tabChanged,
             .listeningStarted, .listeningStopped,
             .copied, .pastedFromHistory,
             .fileOver, .fileDropped, .dropRefused,
             .permissionNeeded, .permissionFixed,
             .keepAwakeOn, .keepAwakeStopped,
             .usageLimitClose, .outputSwitched, .licenceBlocked,
             .scrolledToEnd:
            nil
        }
    }
}

/// Settings › General › Sounds: Off, Only important, All (card D2).
public enum SoundLevel: String, CaseIterable, Sendable {
    case off
    case important
    case all

    /// Only important: the gate sound people already had, plus a done chime.
    /// The owner's call, 2026-10-06.
    public static let `default`: SoundLevel = .important

    public func plays(_ sound: AirlockSound) -> Bool {
        switch self {
        case .off: false
        case .important: sound.isImportant
        case .all: true
        }
    }

    /// The level to use, from what is stored.
    ///
    /// `stored` is the new setting, and wins once it exists. Before it, the
    /// only sound was the gate's, behind its own switch (`legacyGateSound`,
    /// off by default). Somebody who turned that off said "no sound", and
    /// keeps silence. Everyone else, including everyone who was never asked,
    /// gets the default.
    public static func resolve(stored: String?, legacyGateSound: Bool?) -> SoundLevel {
        if let stored, let level = SoundLevel(rawValue: stored) { return level }
        if legacyGateSound == false { return .off }
        return .default
    }
}

/// Never two sounds on top of each other (card D2).
///
/// A sound that lands while another is playing waits for it to end if it
/// matters more, and is dropped if it does not. Only one waits: a still more
/// important one takes its place. So a gate arriving as an agent finishes
/// plays the chime, then the call; an agent finishing under the call is
/// dropped, because the call is the one with somebody behind it.
public struct SoundOverlap: Sendable {
    public enum Decision: Equatable, Sendable {
        case now
        /// Play then, in place of anything already waiting.
        case at(Date)
        case skip
    }

    private var last: AirlockSound?
    private var lastStart: Date = .distantPast
    private var lastEnd: Date = .distantPast

    public init() {}

    /// `length` is how long `sound` plays, so the next one knows when it may
    /// start.
    public mutating func admit(_ sound: AirlockSound, length: TimeInterval,
                               at now: Date) -> Decision {
        // Nothing is ten seconds long: a wait that long means the clock went
        // backwards, and that must not silence the next minutes.
        let remaining = lastEnd.timeIntervalSince(now)
        guard let last, remaining > 0, remaining < 10 else {
            start(sound, at: now, length: length)
            return .now
        }
        guard sound.rank > last.rank else { return .skip }
        if lastStart > now {
            // Replacing the one waiting: same slot, the playing one's end.
            start(sound, at: lastStart, length: length)
        } else {
            start(sound, at: lastEnd, length: length)
        }
        return .at(lastStart)
    }

    private mutating func start(_ sound: AirlockSound, at start: Date, length: TimeInterval) {
        last = sound
        lastStart = start
        lastEnd = start.addingTimeInterval(max(0, length))
    }
}
