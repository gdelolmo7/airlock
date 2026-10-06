import Observation
import AirlockCore

/// Whether the sound card is in the panel at all.
///
/// A whole model for one flag, because an `@Observable` one is the only kind a
/// settings toggle can move. `SoundWidget` read the preference straight out of
/// `WidgetToggle`, and SwiftUI cannot see a UserDefaults read — a switch wired
/// to it would have written the value and left both the panel and itself showing
/// the old one. That is the same trap `CalendarWidgetModel.isEnabled` records,
/// and this is the same shape as its fix.
///
/// It is its own model rather than a flag on `AudioOutputModel` because the card
/// is two models wide: output switching and the per-app mixer. Neither owns the
/// other, and the switch belongs to the card.
@MainActor
@Observable
final class SoundWidgetModel {
    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.sound.enabled",
                                                         defaultValue: true)
    /// On by default: output switching was reachable before the sound card
    /// existed, and taking it away would be a regression for anyone using it.
    /// Per-app levels inside the card are a separate switch and default off.
    var isEnabled: Bool = WidgetToggle.stored("widget.sound.enabled", default: true) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
        }
    }

    /// The card's shape, chosen once per panel session and then held.
    ///
    /// **Latched deliberately, and this is the whole safety argument.** Under a
    /// threshold that splits the forms, choosing live means that when a second
    /// app starts playing, every control in the card rotates 90° under a pointer
    /// that may already be travelling to one. Guarding on an active drag is not
    /// enough — a pointer in flight is exactly what `AppMix.slots`' 30s linger
    /// exists to protect, and re-orienting the whole instrument is that same bug
    /// at card scale.
    ///
    /// Deciding on the panel's false→true edge makes it structurally impossible
    /// for the shape to change while anyone is looking at it. That removes the
    /// animation question, the Reduce Motion question and the `panelConverting`
    /// opacity-stranding hazard at once, rather than mitigating any of them.
    ///
    /// **At the shipped `AppMix.formThreshold` there is nothing to rotate** —
    /// every count resolves to rows — so today the latch decides the same thing
    /// on every opening. It stays anyway, because it is what makes the knob a
    /// one-line reversal: move the threshold back to a split and this is already
    /// the thing standing between the card and a pointer.
    ///
    /// The initial value is the one the card wants everywhere, not a neutral
    /// one: `NotchController.transition` calls `setPanelVisible` synchronously
    /// before the panel's views are built, so this is only ever read in a state
    /// nobody sees — and a default that disagreed with the steady state would
    /// be one frame of the other shape waiting for a scheduling change to
    /// become visible. Derived from the threshold (see `init`) rather than
    /// written as `.rows`, so a reversal cannot leave it disagreeing.
    private(set) var form: AppMix.Form

    @ObservationIgnored private var panelVisible = false

    /// The knob this model reads. Always `AppMix.formThreshold` in the app;
    /// injectable because at the shipped `nil` no count reaches the console,
    /// and a latch between two forms is only testable with a threshold that
    /// produces both. See `LevelsFormLatchTests`.
    @ObservationIgnored private let formThreshold: Int?

    init(formThreshold: Int? = AppMix.formThreshold) {
        self.formThreshold = formThreshold
        // One source: the shipped default card, the output alone, since
        // per-app levels (`widget.sound.appLevels`) are off until switched on.
        form = AppMix.form(sourceCount: 1, threshold: formThreshold)
    }

    /// Called from `NotchController.transition` — the single funnel every
    /// presentation change passes through — beside the same call the system
    /// meters use. Only the rising edge decides anything.
    func setPanelVisible(_ visible: Bool, sourceCount: Int) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        guard visible else { return }
        form = AppMix.form(sourceCount: sourceCount, threshold: formThreshold)
    }
}
