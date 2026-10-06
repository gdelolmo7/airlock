import Foundation

/// The heads-up when Claude's 5-hour or weekly limit is nearly used up, and
/// the optional one when it resets (card Agents 1).
///
/// Pure: the reading, what was already said, and the clock come in as values,
/// so "once per window" is a one-line test rather than a wait.
///
/// **Once per window, keyed by when the window ends.** What is remembered is
/// the reset time of each window already warned about. Until that time passes
/// the window is the same one, however often the figure is re-read and however
/// far it climbs; once it passes, the window has rolled and the next crossing
/// is news again. Keyed by the end rather than by the figure, because the
/// figure only climbs inside a window and a level crossed twice is still one
/// warning.
///
/// **A reset is only announced for a window that was warned about.** Every
/// 5-hour window resets, several times a day; saying so each time would be a
/// notice about nothing. After "90% used" it is the news the person is waiting
/// for.
public enum UsageAlert {
    public enum Window: String, Codable, Sendable, CaseIterable {
        case fiveHour, sevenDay

        /// How long a window lasts, for a reading that arrived without its
        /// reset time.
        public var nominalLength: TimeInterval {
            switch self {
            case .fiveHour: return 5 * 3600
            case .sevenDay: return 7 * 24 * 3600
            }
        }

        /// As a sentence says it: "Claude's 5-hour limit".
        public var name: String {
            switch self {
            case .fiveHour: return "5-hour"
            case .sevenDay: return "weekly"
            }
        }
    }

    public enum Notice: Equatable, Sendable {
        case nearLimit(Window, percent: Int)
        case reset(Window)

        public var window: Window {
            switch self {
            case .nearLimit(let window, _), .reset(let window): return window
            }
        }

        /// What the compact island draws beside the glyph, or nil for the
        /// glyph alone.
        ///
        /// It was the window, "5h" or "7d" — shorthand nothing on screen
        /// explains, and not the news: a gauge with "90%" beside it reads as
        /// a limit filling up without a word of explanation. Which window is
        /// in the spoken sentence and the open panel. A reset has no number
        /// worth drawing, so it is the arrow alone.
        public var compactLabel: String? {
            switch self {
            case let .nearLimit(_, percent): return "\(percent)%"
            case .reset: return nil
            }
        }

        /// What VoiceOver says, and what the notice means in words.
        public var sentence: String {
            switch self {
            case let .nearLimit(window, percent):
                return "Claude's \(window.name) limit is \(percent)% used"
            case .reset(let window):
                return "Claude's \(window.name) limit has reset"
            }
        }
    }

    /// The levels Settings offers, in percent. Zero is "never warn".
    public static let levelChoices = [0, 75, 80, 90, 95]
    /// The card's suggestion: late enough to be worth interrupting for, early
    /// enough to finish the task at hand.
    public static let defaultLevel = 90

    /// What has already been said, per window: the end of the window warned
    /// about. Persisted, so a relaunch inside the same window stays quiet.
    public struct Memory: Codable, Equatable, Sendable {
        public var warnedUntil: [String: Date]

        public init(warnedUntil: [String: Date] = [:]) {
            self.warnedUntil = warnedUntil
        }

        public subscript(window: Window) -> Date? {
            get { warnedUntil[window.rawValue] }
            set { warnedUntil[window.rawValue] = newValue }
        }
    }

    /// The one notice due now, if any, and the memory to keep afterwards.
    ///
    /// **One at a time.** When two are due, only the first is returned and only
    /// it is written down; the other stays due, and the caller asks again once
    /// the first has had its turn on screen. The weekly window goes first: at
    /// 90% of the week the 5-hour figure matters less.
    ///
    /// A window that rolled with resets switched off is forgotten quietly, in
    /// the same pass, so switching the reset notice on later never announces a
    /// reset from last week.
    public static func evaluate(_ snapshot: UsageSnapshot?, memory: Memory, level: Int,
                                announcesReset: Bool, now: Date) -> (notice: Notice?, memory: Memory) {
        var memory = memory
        var resets: [Window] = []
        for window in Window.allCases {
            if let until = memory[window], until <= now {
                if announcesReset { resets.append(window) } else { memory[window] = nil }
            }
        }

        if level > 0 {
            for window in [Window.sevenDay, .fiveHour] {
                // A window still waiting to announce its reset is the old one;
                // a reading from the new one is considered after that notice.
                guard memory[window] == nil,
                      let reading = reading(window, in: snapshot),
                      !reading.hasRolled(at: now),
                      reading.usedPercentage >= Double(level) else { continue }
                memory[window] = reading.resetsAt ?? now.addingTimeInterval(window.nominalLength)
                return (.nearLimit(window, percent: Int(reading.usedPercentage.rounded(.down))), memory)
            }
        }

        if let window = resets.first {
            memory[window] = nil
            return (.reset(window), memory)
        }
        return (nil, memory)
    }

    private static func reading(_ window: Window, in snapshot: UsageSnapshot?) -> RateLimitWindow? {
        switch window {
        case .fiveHour: return snapshot?.fiveHour
        case .sevenDay: return snapshot?.sevenDay
        }
    }
}
