import Foundation

/// What this copy of Airlock has actually done for you, counted for life.
///
/// **The trial's last day argues with the user's own history rather than a
/// feature list.** "214 commands approved without leaving what you were doing"
/// is a claim they can check against their own memory; "approve commands from
/// the notch" is a claim about a product. Only one of those is evidence.
///
/// Its own store because `GateLog` rolls at 500 records — it is a log, and a log
/// that forgets is the right kind of log. A lifetime count that quietly reset
/// every fortnight would be worse than no count, because it would be *wrong* on
/// exactly the screen that depends on it being true.
///
/// Three figures, and each is a thing the person would otherwise have done by
/// hand: switched to a terminal to approve, typed an answer, typed a sentence.
/// Nothing here counts something the app did on its own.
public struct UsageTally: Codable, Sendable, Equatable {
    /// Gates approved from the notch.
    public var approvals: Int
    /// Agent questions answered from the notch.
    public var answers: Int
    /// Dictations typed into another app.
    public var dictations: Int

    public init(approvals: Int = 0, answers: Int = 0, dictations: Int = 0) {
        self.approvals = approvals
        self.answers = answers
        self.dictations = dictations
    }

    /// Whether there is anything worth boasting about yet.
    ///
    /// A card offering "0 commands approved" as a reason to pay is an argument
    /// against itself, so the last-day card falls back to the plain ask.
    public var isWorthShowing: Bool { approvals + answers + dictations > 0 }

    /// The lines the card prints, in the order it prints them, skipping any
    /// that never happened.
    ///
    /// A zero is not shown rather than shown as zero: somebody who never
    /// dictated does not need a row telling them so on the day they are being
    /// asked for money.
    public var lines: [(count: Int, label: String)] {
        var lines: [(Int, String)] = []
        if approvals > 0 {
            lines.append((approvals,
                          "command\(approvals == 1 ? "" : "s") approved without leaving what you were doing"))
        }
        if answers > 0 {
            lines.append((answers, "question\(answers == 1 ? "" : "s") answered from the notch"))
        }
        if dictations > 0 {
            lines.append((dictations,
                          "dictation\(dictations == 1 ? "" : "s") typed straight into the app you were in"))
        }
        return lines
    }
}
