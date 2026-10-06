import Foundation
import Observation
import AirlockCore

/// Keeps the lifetime counts, and is the only thing allowed to raise them.
///
/// UserDefaults rather than a file: three integers that must survive forever and
/// are read once, on the one screen that uses them. `GateLog`'s own store exists
/// because a log has records, ordering and a roll policy; this has none of that
/// and would be a file for the sake of symmetry.
///
/// **Counts what the person did, never what the app did.** An auto-approved gate
/// raises nothing — a rule ran, and claiming credit for it on the day somebody
/// is asked for money would be counting the same decision twice, since they
/// already approved the thing that wrote the rule.
@MainActor
@Observable
final class UsageTallyStore {
    private(set) var tally: UsageTally

    init() {
        tally = UsageTally(
            approvals: Defaults.int("tally.approvals", default: 0),
            answers: Defaults.int("tally.answers", default: 0),
            dictations: Defaults.int("tally.dictations", default: 0))
    }

    /// A gate the human approved. Deny is not counted: the card's argument is
    /// about work done for you, and a refusal is work you did.
    func recordApproval() {
        tally.approvals += 1
        Defaults.set(tally.approvals, "tally.approvals")
    }

    func recordAnswer() {
        tally.answers += 1
        Defaults.set(tally.answers, "tally.answers")
    }

    func recordDictation() {
        tally.dictations += 1
        Defaults.set(tally.dictations, "tally.dictations")
    }
}
