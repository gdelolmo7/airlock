import Foundation
import Observation

/// Which of Home's tips the person has closed. A closed tip never comes back.
///
/// The owner's call (2026-10-28): the tips were there every time Home had
/// nothing else to show, for good, and "they shouldn't be there". They are
/// for the first days now: each has a close button, and once all are closed
/// the card is gone.
@MainActor
@Observable
final class KeyMapTips {
    static let shared = KeyMapTips()

    /// Every tip's row id, as `KeyMapSectionView.rows` names them.
    static let all = ["dictate", "clipboard", "tray"]

    private static let closedKey = "keymap.tips.closed"
    /// Written once the first time this build runs, so the copy's age is
    /// decided once and not at every launch.
    private static let settledKey = "keymap.tips.settled"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var closed: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        closed = Set(defaults.stringArray(forKey: Self.closedKey) ?? [])
    }

    func isClosed(_ id: String) -> Bool { closed.contains(id) }

    func close(_ id: String) {
        guard !closed.contains(id) else { return }
        closed.insert(id)
        defaults.set(closed.sorted(), forKey: Self.closedKey)
    }

    /// Once, at the first launch of a build that has this: a copy that
    /// already finished setup has had its first days, so its tips start
    /// closed. A new copy has not finished setup yet when this runs, and
    /// keeps them.
    func settle(setUpAlready: Bool) {
        guard !defaults.bool(forKey: Self.settledKey) else { return }
        defaults.set(true, forKey: Self.settledKey)
        guard setUpAlready else { return }
        for id in Self.all { close(id) }
    }
}
