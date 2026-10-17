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

    /// macOS refused: a folder it guards (Desktop, Documents, Downloads, a
    /// disk), or a file that isn't the person's.
    public static let notAllowed = "macOS isn't letting Airlock use it. Allow Airlock in System Settings › "
        + "Privacy & Security › Files & Folders, then try again."

    /// Why something on disk did not happen, as the second sentence after
    /// "X couldn't go on the Shelf."
    public static func file(domain: String, code: Int) -> String {
        switch (domain, code) {
        case (NSCocoaErrorDomain, 640), (NSPOSIXErrorDomain, 28):
            return "Your Mac is out of space."
        case _ where isPermission(domain: domain, code: code):
            // One cause for reading, saving, moving and trashing alike, so
            // the sentence names none of those verbs, and the way to let it.
            return PlainProblem.notAllowed
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

    /// macOS refused access to a file. Lets a caller that knows WHICH file say
    /// so, instead of the general "doesn't have permission for it".
    public static func isPermission(domain: String, code: Int) -> Bool {
        switch (domain, code) {
        case (NSCocoaErrorDomain, 513), (NSCocoaErrorDomain, 257),
             (NSPOSIXErrorDomain, 13), (NSPOSIXErrorDomain, 1):
            return true
        default:
            return false
        }
    }

    public static func isPermission(_ error: any Error) -> Bool {
        let ns = error as NSError
        return isPermission(domain: ns.domain, code: ns.code)
    }
}
