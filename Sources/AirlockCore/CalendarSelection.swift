import Foundation

/// Which calendars the calendar widget reads.
///
/// The subtlety is that "none" has to be a sayable thing. While the selection
/// was a plain `Set<String>` with empty overloaded to mean "all of them",
/// unticking the last calendar in settings put every one of them straight back
/// on — the user asked for nothing and got everything, and no relaunch could
/// remember otherwise because nothing distinguishable had been stored.
///
/// So this is a tri-state, read the same way `AgentsPresence` reads its switch:
/// `nil` is nobody has chosen, which genuinely does mean all of them, and an
/// empty set is a choice. `UserDefaults.stringArray(forKey:)` already tells an
/// absent key (nil) from a stored empty array ([]), so the distinction survives
/// a quit for free.
public struct CalendarSelection: Equatable, Sendable {
    /// The calendars the user picked, or nil while they never have.
    public let chosen: Set<String>?

    public init(chosen: Set<String>?) {
        self.chosen = chosen
    }

    /// First run: no choice made, so every calendar counts.
    public static let unchosen = CalendarSelection(chosen: nil)

    /// True when the user has said, explicitly, to show nothing.
    ///
    /// Callers have to ask, because EventKit's own "all calendars" is an empty
    /// list too — handing `predicateForEvents` an empty array of calendars
    /// fetches from every one of them, which is the exact inversion this type
    /// exists to prevent.
    public var readsNothing: Bool { chosen?.isEmpty == true }

    public func includes(_ id: String) -> Bool {
        guard let chosen else { return true }
        return chosen.contains(id)
    }

    /// The result of ticking or unticking one row in settings.
    ///
    /// `all` is every calendar there is, and it matters only for the first
    /// untick from `unchosen`: the rows were all shown ticked, so switching one
    /// off has to mean "the others, minus this one" rather than "nothing".
    public func setting(_ id: String, to on: Bool, amongst all: [String]) -> CalendarSelection {
        var ids = chosen ?? Set(all)
        if on { ids.insert(id) } else { ids.remove(id) }
        return CalendarSelection(chosen: ids)
    }

    /// What the settings pane says is happening, given the calendars that exist
    /// right now.
    ///
    /// Three sentences rather than one, because the tri-state turned the old
    /// line — "All of them until you pick." — from a rule into a description.
    /// Under the two-state it was true in both states and said nothing about
    /// which one you were in; it then stayed on screen unchanged with three
    /// calendars ticked, where it reads as a claim that everything is still
    /// being shown.
    ///
    /// The picked case is also the only one that can say the thing nobody is
    /// told otherwise: `setting(_:to:amongst:)` never collapses a full tick-list
    /// back to `unchosen`, so once you have picked, a calendar added tomorrow
    /// stays off until it is ticked like any other.
    ///
    /// Counted against `all` rather than off `chosen`, because an id whose
    /// calendar has since been deleted contributes no events — and if every
    /// picked one has gone, the outcome is an empty fetch, which is what
    /// `CalendarWidgetModel.fetch` does with it too.
    public func summary(amongst all: [String]) -> String {
        guard let chosen else {
            return "Nobody has picked yet, so all \(all.count) are read — including any you add later."
        }
        let ticked = all.filter(chosen.contains).count
        guard ticked > 0 else {
            return "Nothing is ticked, so the calendar shows no events. Tick one to bring it back."
        }
        return "Reading \(ticked) of \(all.count). Now that you have picked, a calendar added later "
            + "stays off until you tick it too."
    }

    /// What goes into UserDefaults. Sorted so a re-store is a no-op diff, and
    /// nil only for the state nobody has touched — writing an empty array is how
    /// "show me nothing" survives the relaunch.
    public var stored: [String]? { chosen.map { $0.sorted() } }

    public init(stored: [String]?) {
        self.chosen = stored.map(Set.init)
    }
}
