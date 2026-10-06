import Foundation
import Observation
import AirlockCore

/// The limit heads-up's settings and its memory (card Agents 1). The rule is
/// `UsageAlert`; this holds what it needs between readings and the notice the
/// island is showing.
@MainActor
@Observable
final class UsageAlertModel {
    /// Percent at which to warn; zero never does. See `UsageAlert.levelChoices`.
    var level: Int = Defaults.int("agents.usageAlert.level", default: UsageAlert.defaultLevel) {
        didSet {
            guard level != oldValue else { return }
            Defaults.set(level, "agents.usageAlert.level")
        }
    }

    /// Also say when a window that was warned about resets. Off by default,
    /// the card's suggestion.
    var announcesReset: Bool = Defaults.bool("agents.usageAlert.announceReset", default: false) {
        didSet {
            guard announcesReset != oldValue else { return }
            Defaults.set(announcesReset, "agents.usageAlert.announceReset")
        }
    }

    /// The notice raised most recently and when. The island decides from `at`
    /// whether it is still on screen; nothing here clears it.
    private(set) var notice: UsageAlert.Notice?
    private(set) var noticeAt: Date?

    @ObservationIgnored private var memory: UsageAlert.Memory = UsageAlertModel.loadMemory()

    private static let memoryKey = "agents.usageAlert.memory"

    /// Reads the figures once more. True when a new notice went up, so the
    /// caller can bring the island up for it.
    ///
    /// Nothing is checked while the last notice is still showing: a second
    /// one due at the same time waits its turn rather than replacing the first
    /// before anybody saw it. With agents off nothing is checked or written
    /// down at all, so turning them back on still warns about the window
    /// that is filling now.
    func check(_ snapshot: UsageSnapshot?, agentsOn: Bool, now: Date = Date()) -> Bool {
        guard agentsOn else { return false }
        if let noticeAt, now.timeIntervalSince(noticeAt) >= 0,
           now.timeIntervalSince(noticeAt) < CompactIsland.usageNoticeDuration { return false }
        let result = UsageAlert.evaluate(snapshot, memory: memory, level: level,
                                         announcesReset: announcesReset, now: now)
        if result.memory != memory {
            memory = result.memory
            Self.saveMemory(memory)
        }
        guard let next = result.notice else { return false }
        notice = next
        noticeAt = now
        if case .nearLimit(let window, let percent) = next {
            Moments.shared.announce(.usageLimitClose, "\(window.rawValue) \(percent)%")
        }
        return true
    }

    private static func loadMemory() -> UsageAlert.Memory {
        guard let data = UserDefaults.standard.data(forKey: memoryKey),
              let memory = try? JSONDecoder().decode(UsageAlert.Memory.self, from: data)
        else { return UsageAlert.Memory() }
        return memory
    }

    private static func saveMemory(_ memory: UsageAlert.Memory) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: memoryKey)
    }
}
