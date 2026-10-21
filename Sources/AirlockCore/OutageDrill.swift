import Foundation

/// A pretend outage of Airlock's online services, so the screens a real one
/// shows can be seen on purpose: hidden launch flags, and nothing changes
/// unless one is passed.
///
/// `--outage` pretends a dead server, never a missing network. Every request
/// to the licence server (activate, refresh, online notes, usage counts) and
/// the voices download still goes through its own request code, and meets a
/// connection nobody answers, or the 5xx that follows the flag
/// (`--outage 503`). So the fallbacks that run are the real ones: a paid plan
/// stays as it is, a call's notes are written on the Mac or wait, and counts
/// and downloads try again later. The update check is Sparkle's own request,
/// so it is pointed at an address nothing listens on (`deadFeedURL`) and is
/// refused whatever follows the flag.
///
/// `--no-apple-intelligence` makes the Mac behave as if Apple Intelligence
/// were switched off. With `--outage` it is the one way to see a call wait
/// for its notes ("Call saved, notes later") on a Mac that could write them.
public enum OutageDrill {
    public enum Failure: Equatable, Sendable {
        /// Nobody answers: the connection is refused.
        case noReply
        /// The server answers with this status, 500 to 599.
        case serverError(Int)
    }

    public static let flag = "--outage"
    public static let noAppleIntelligenceFlag = "--no-apple-intelligence"

    /// The update check's feed during the outage: this Mac, on a port
    /// nothing listens on, so the connection is refused at once.
    public static let deadFeedURL = "https://127.0.0.1:9/appcast.xml"

    /// The failure `arguments` ask for, or nil for the services as they are.
    /// A status from 500 to 599 straight after the flag is the reply;
    /// anything else there is not the flag's and leaves it at no reply.
    public static func failure(in arguments: [String]) -> Failure? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        if next < arguments.endIndex, let status = Int(arguments[next]), (500...599).contains(status) {
            return .serverError(status)
        }
        return .noReply
    }

    public static func hidesAppleIntelligence(in arguments: [String]) -> Bool {
        arguments.contains(noAppleIntelligenceFlag)
    }

    /// The Mac's model as Airlock should see it: as it is, or switched off.
    public static func availability(_ real: ModelAvailability, hidden: Bool) -> ModelAvailability {
        hidden ? .needsAppleIntelligence : real
    }

    /// For the logs, so a pretend outage is never read as a real one.
    public static func logLine(_ failure: Failure) -> String {
        switch failure {
        case .noReply: "pretend outage on: online services refuse every connection"
        case .serverError(let status): "pretend outage on: online services answer \(status)"
        }
    }
}
