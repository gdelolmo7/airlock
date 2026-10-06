import Foundation

/// What to do with whatever was pasted into the licence field.
///
/// Two things can arrive there: a signed licence (issued by hand, checked on
/// this Mac with no network) or the licence key the shop emailed, which means
/// nothing here until the licence server exchanges it. This decides which
/// path a paste takes, and — the reason it exists — **who a refusal is about**.
///
/// The licence page used to blame the customer for faults in the build: a copy
/// packaged without its public key said "that does not look like a licence
/// key", and one without a server address said "if you retyped it, paste it
/// instead". Neither had anything to do with what was pasted.
public enum LicensePaste {
    public enum Step: Equatable, Sendable {
        /// A signed licence for this Mac: keep it.
        case store
        /// Not a signed licence, so most likely the shop's key — the server's
        /// to judge.
        case askServer
        /// A signed licence that can't be used here, for a reason worth naming.
        /// Sending it to the server would only come back as "that does not
        /// look like a licence key", which is the wrong answer to a right key
        /// for another Mac.
        case refuse(LicenseVerdict.Reason)
        /// This copy of Airlock can't check keys at all — no public key, or a
        /// shop key with no server to exchange it. The build's fault, never
        /// the customer's.
        case cannotCheck
    }

    /// - Parameters:
    ///   - verdict: what the local check made of the paste, or nil when the
    ///     build has no public key to check with.
    ///   - hasServer: whether the build knows where the licence server is.
    public static func step(verdict: LicenseVerdict?, hasServer: Bool) -> Step {
        guard let verdict else { return .cannotCheck }
        switch verdict {
        case .valid:
            return .store
        case .invalid(.malformed):
            return hasServer ? .askServer : .cannotCheck
        case .invalid(let reason):
            return .refuse(reason)
        }
    }
}
