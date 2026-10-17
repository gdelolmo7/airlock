import AirlockCore
import Foundation
import Observation
import os

/// Free's reminders in the notch: hears what Free let go as it happens, and
/// puts at most one card a day above the widgets when the panel opens.
///
/// The rules are `UpgradeReminders` (Core, pure and tested): one a day across
/// every kind, never during a call or while an agent is asking, "Not now"
/// quiets a kind for 14 days. What lives here is the part that cannot be
/// pure: the preferences, the clock, and when the panel opens and closes.
///
/// **Shown when the panel opens, gone when it closes.** It never opens the
/// notch by itself (only a gate or a question may), never plays a sound, and
/// is never drawn instead of the widgets.
@MainActor
@Observable
final class UpgradeReminderModel {
    /// The card on screen while the panel is open; nil the rest of the time.
    private(set) var card: UpgradeReminder?

    /// Whether this Mac is on Free now.
    @ObservationIgnored var onFree: () -> Bool = { false }
    /// A call on, or notes being taken in the room.
    @ObservationIgnored var callOn: () -> Bool = { false }
    /// An agent waiting on an answer, on the notch or in its own terminal.
    @ObservationIgnored var agentAsking: () -> Bool = { false }
    /// "You're on Free now" or a welcome is up: that is the day's one.
    @ObservationIgnored var otherCardUp: () -> Bool = { false }
    /// Opens Settings › Plans.
    @ObservationIgnored var onSeePlus: () -> Void = {}

    @ObservationIgnored private var reminders: UpgradeReminders
    /// Nil for the state gallery's, which keeps nothing.
    @ObservationIgnored private let defaults: UserDefaults?

    static let key = "upgradeReminders"
    private static let log = Logger(subsystem: "com.airlock.app", category: "license")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reminders = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(UpgradeReminders.self, from: $0) } ?? UpgradeReminders()
    }

    /// A card that is simply there: the state gallery's.
    init(previewing card: UpgradeReminder?) {
        defaults = nil
        reminders = UpgradeReminders()
        self.card = card
    }

    /// Shows the day's card when the panel opens and takes it away when it
    /// closes. Called once, for the app's own model.
    func listenToTheIsland(_ moments: Moments = .shared) {
        moments.listen(to: .islandOpened) { [weak self] in self?.islandOpened() }
        moments.listen(to: .islandClosed) { [weak self] in self?.islandClosed() }
    }

    // MARK: - What happened

    /// The clipboard let copies go for Free's limit.
    func copiesLetGo(_ count: Int, now: Date = Date()) {
        guard count > 0 else { return }
        change { $0.copiesLetGo(count, now: now) }
    }

    /// An agent asked in its own terminal because another had the notch.
    func agentAskedInTerminal(asking: String, answering: String?, now: Date = Date()) {
        change { $0.agentAskedInTerminal(asking: asking, answering: answering, now: now) }
    }

    /// A call's notes stopped at Free's limit.
    func notesStopped(now: Date = Date()) {
        change { $0.notesStopped(now: now) }
    }

    // MARK: - The panel

    func islandOpened(now: Date = Date()) {
        guard defaults != nil, card == nil else { return }
        if otherCardUp() {
            if onFree() { change { $0.anotherCardShown(now: now) } }
            return
        }
        guard let due = reminders.due(onFree: onFree(), callOn: callOn(), agentAsking: agentAsking(),
                                      now: now) else { return }
        card = due
        change { $0.shown(due, now: now) }
        Self.log.info("free reminder shown: \(due.kind.rawValue, privacy: .public)")
    }

    func islandClosed() {
        guard defaults != nil else { return }
        card = nil
    }

    // MARK: - The buttons

    func seePlus() {
        if let card { Self.log.info("free reminder: see plus (\(card.kind.rawValue, privacy: .public))") }
        card = nil
        onSeePlus()
    }

    func notNow(now: Date = Date()) {
        guard let shown = card else { return }
        card = nil
        change { $0.notNow(shown.kind, now: now) }
    }

    private func change(_ edit: (inout UpgradeReminders) -> Void) {
        guard let defaults else { return }
        var next = reminders
        edit(&next)
        guard next != reminders else { return }
        reminders = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
    }
}
