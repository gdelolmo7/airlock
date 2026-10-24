import Foundation
import Observation
import AirlockCore

/// The "Try these" card's memory: which first steps a new person has done.
///
/// A shared instance, like `UsageCounts`, because the four things it listens
/// for happen in four unrelated models, and threading a reference through each
/// of them for a card that retires within days would be the wrong trade. The
/// rules live in Core (`FirstSteps`); this only saves them and redraws.
@MainActor
@Observable
final class FirstStepsModel {
    static let shared = FirstStepsModel()

    private static let key = "firstSteps"

    private(set) var progress: FirstSteps

    /// For the state gallery: made-up progress, never saved.
    @ObservationIgnored private let saves: Bool

    init(previewing progress: FirstSteps? = nil) {
        if let progress {
            self.progress = progress
            saves = false
        } else {
            self.progress = UserDefaults.standard.data(forKey: Self.key)
                .flatMap { try? JSONDecoder().decode(FirstSteps.self, from: $0) } ?? FirstSteps()
            saves = true
        }
    }

    /// Starts the card on a new install. Called with the first run, and with
    /// `--try-these` to see it again on a Mac that has long had Airlock.
    func begin(now: Date = Date()) {
        progress = FirstSteps(startedAt: now)
        save()
    }

    func note(_ step: FirstStep) {
        guard progress.note(step) else { return }
        save()
    }

    func hide() {
        progress.hidden = true
        save()
    }

    private func save() {
        guard saves, let data = try? JSONEncoder().encode(progress) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
