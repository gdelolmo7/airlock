import Foundation

/// A system error, said the way Airlock talks (`docs/how-airlock-talks.md`).
///
/// macOS's own sentences ("The file couldn't be saved because the volume is
/// read only", "Operation not permitted") are for the log. What reaches the
/// screen is one of a few plain causes, picked by the error's code, and the
/// rest fall back to something true for any of them: try again.
///
/// Pure, by domain and code, so the mapping is tested without a disk to fill.
public enum PlainProblem {
    public static let fallback = "Try again in a moment."

    /// Why something on disk did not happen, as the second sentence after
    /// "X couldn't go on the Shelf."
    public static func file(domain: String, code: Int) -> String {
        switch (domain, code) {
        case (NSCocoaErrorDomain, 640), (NSPOSIXErrorDomain, 28):
            return "Your Mac is out of space."
        case (NSCocoaErrorDomain, 513), (NSCocoaErrorDomain, 257),
             (NSPOSIXErrorDomain, 13), (NSPOSIXErrorDomain, 1):
            // One cause for reading, saving, moving and trashing alike, so
            // the sentence names none of those verbs.
            return "Airlock doesn't have permission for it."
        case (NSCocoaErrorDomain, 4), (NSCocoaErrorDomain, 260), (NSPOSIXErrorDomain, 2):
            return "It's no longer where it was."
        case (NSCocoaErrorDomain, 642), (NSPOSIXErrorDomain, 30):
            return "That disk can't be changed."
        default:
            return fallback
        }
    }

    public static func file(_ error: any Error) -> String {
        let ns = error as NSError
        return file(domain: ns.domain, code: ns.code)
    }
}
