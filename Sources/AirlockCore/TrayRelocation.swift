import Foundation

/// The outcome of moving shelf items somewhere else on disk.
///
/// Its own type rather than a reuse of `TrayIngestResult`, whose message says
/// "Couldn't add" — the wrong direction, and it would read as a bug in the part
/// of the app that was working.
///
/// A value, because the file work runs off the main actor and the answer has to
/// cross back; the sentence a person reads is pure and therefore testable, which
/// is the half of this that `swift test` can see.
public struct TrayRelocationResult: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    /// Names that actually left the shelf.
    public let moved: [String]
    public let failures: [Failure]
    /// Where they were going, for the message.
    public let destination: String

    public init(moved: [String], failures: [Failure], destination: String) {
        self.moved = moved
        self.failures = failures
        self.destination = destination
    }

    /// `nil` when there is nothing to say — which is also what CLEARS a previous
    /// message, since `lastError` is one slot and last-writer-wins.
    ///
    /// Names the first failure only, like `TrayIngestResult` does: a list of
    /// five reasons in a one-line footer is a list nobody reads, and the tiles
    /// that failed are still on the shelf to try again.
    public var message: String? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            return "\(first.name) couldn't be moved to \(destination). \(first.reason)"
        }
        return "\(failures.count) items couldn't be moved to \(destination). \(first.reason)"
    }
}
