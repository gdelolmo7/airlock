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
/// **Shown when the panel opens, gone when it closes, and back at every open
/// until it is answered** with "Not now" or "See Plus". It never opens the
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
    /// Setup, a new version's card or one of the one-time questions fills
    /// the panel, so no widget, and no card, would be seen this open.
    @ObservationIgnored var panelTaken: () -> Bool = { false }
    /// The parts of Airlock this Mac uses now, for the week's card.
    @ObservationIgnored var uses: () -> Set<UpgradeReminder.Use> = { [] }
    /// Opens Settings › Plans.
    @ObservationIgnored var onSeePlus: () -> Void = {}
    /// A card came on screen (once, not at each open it comes back at), and
    /// "Not now" on one, for usage counts. The gallery's model never calls them.
    @ObservationIgnored var onShown: (UpgradeReminder.Kind) -> Void = { _ in }
    @ObservationIgnored var onNotNow: (UpgradeReminder.Kind) -> Void = { _ in }

    @ObservationIgnored private var reminders: UpgradeReminders
    /// The card up now was drawn and counted. A card is picked when the
    /// panel opens but only counts once it is drawn: dictation or a spoken
    /// answer can open the panel with the widgets, and the card, hidden.
    @ObservationIgnored private var cardCounted = false
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
        let onFree = onFree()
        if onFree { change { $0.openedOnFree(now: now) } } else { change { $0.leftFree() } }
        // Nothing is seen behind it: the card waits for the next open.
        if panelTaken() { return }
        if otherCardUp() {
            if onFree { change { $0.anotherCardShown(now: now) } }
            return
        }
        guard let due = reminders.due(onFree: onFree, callOn: callOn(), agentAsking: agentAsking(),
                                      uses: uses(), now: now) else { return }
        card = due
        cardCounted = false
    }

    /// The card was drawn: now it is the day's one. Called by the card's
    /// view, so a card picked but never drawn is still due next open.
    func cardAppeared(now: Date = Date()) {
        guard defaults != nil, let card, !cardCounted else { return }
        cardCounted = true
        // Back from an earlier open, still waiting for an answer: counted then.
        let back = reminders.unanswered == card.kind
        change { $0.shown(card, now: now) }
        if back {
            Self.log.info("free reminder back: \(card.kind.rawValue, privacy: .public)")
        } else {
            onShown(card.kind)
            Self.log.info("free reminder shown: \(card.kind.rawValue, privacy: .public)")
        }
    }

    func islandClosed() {
        guard defaults != nil else { return }
        card = nil
    }

    // MARK: - The buttons

    func seePlus() {
        if let card { Self.log.info("free reminder: see plus (\(card.kind.rawValue, privacy: .public))") }
        card = nil
        change { $0.answered() }
        onSeePlus()
    }

    func notNow(now: Date = Date()) {
        guard let shown = card else { return }
        card = nil
        change { $0.notNow(shown.kind, now: now) }
        if defaults != nil { onNotNow(shown.kind) }
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
