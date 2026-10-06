import Foundation

// The few guide types that code in every build draws. The guide itself lives
// in the `Guide` folders and is private (see the top of Package.swift); these
// are declared here so the compact island, bloub's face and the listening
// strip compile without it. Without the guide nothing ever makes one of
// these values, so each surface simply never shows its guide state. With it,
// the files in `Guide/` extend the same two namespaces with everything else.

/// What a guide looks like at any moment — see `Guide/GuidePresentation.swift`.
public enum GuidePresentation {
    /// The compact island's half of a running guide.
    public enum Compact: Equatable, Sendable {
        case listening
        /// The eye, naming the app being read.
        case looking(app: String)
        /// `practice`: the first run's practice, labelled beside the dots.
        case guiding(step: Int, of: Int, offTrack: Bool, practice: Bool = false)
        /// The last 20 seconds before the no-progress end.
        case noProgress(secondsLeft: Int)
        case done(message: String, steps: Int)
    }
}

/// Whether something said to the ask key wants a guide, an answer, or a
/// closer look before either — see `Guide/GuideRouting.swift`.
public enum GuideRouting {
    public enum Route: Equatable, Sendable {
        case guide
        case chat
        /// The words alone do not say. `AskIntent` decides with the front app
        /// as context; with no model to ask, it is an answer — never a guide.
        case unsure
    }
}
