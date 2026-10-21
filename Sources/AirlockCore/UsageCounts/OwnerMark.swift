import Foundation

/// `airlock://this-mac-is-mine?mark=…`: how the owner of Airlock tells their
/// own Macs apart in the usage counts, so their own use of the app can be
/// left out of the numbers.
///
/// The mark is 32 hexadecimal characters that the owner's numbers page puts
/// in the link. Kept in a file beside the app's other files (`fileName`), it
/// goes with every batch of usage counts this Mac sends (`UsageWire`), and the
/// server marks that batch's events as the owner's only when it is the mark
/// the server knows. Any other mark is ignored there, so a link from anywhere
/// else changes nothing; and the app asks before it keeps one (`question`).
///
/// A file, not a preference: every copy of Airlock on the Mac reads the same
/// one, and it outlives counts being switched off, which throws the install
/// id away, and a reinstall.
///
/// **Untrusted, like every URL**: this only reads a candidate out of it.
public enum OwnerMark {
    public static let host = "this-mac-is-mine"
    public static let fileName = "owner-mark"

    /// The mark an owner link carries, or nil for anything else. As strict
    /// about the shape as `ActivationURL`, for the same reason.
    public static func mark(from url: URL) -> String? {
        guard url.scheme?.lowercased() == ActivationURL.scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "mark" })?.value
        else { return nil }
        return valid(value)
    }

    /// `text` as a mark, in lower case: exactly 32 hexadecimal characters
    /// once spaces and line ends are trimmed, or nil.
    public static func valid(_ text: String) -> String? {
        let mark = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // isASCII as well: isHexDigit also takes the full-width digits.
        guard mark.count == 32, mark.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return mark
    }

    /// What the app asks before it keeps a mark. `keep` nil is a notice with
    /// one button, `done`.
    public struct Question: Equatable, Sendable {
        public let title: String
        public let message: String
        public let keep: String?
        public let done: String
    }

    /// The question for keeping `new`, given the mark this Mac already has
    /// and whether it sends usage counts at all.
    public static func question(new: String, current: String?, sendsCounts: Bool) -> Question {
        let leftOut = "your numbers page can leave them out when Hide me is on"
        if current == new {
            return Question(title: "This Mac is already marked as yours",
                            message: "The usage counts it sends carry your mark, so \(leftOut).",
                            keep: nil, done: "OK")
        }
        var message = "Airlock adds your mark to the usage counts this Mac sends, so \(leftOut). Nothing else changes."
        if current != nil { message += " It replaces the mark this Mac has now." }
        if !sendsCounts {
            message += " Usage counts are off on this Mac, so it sends none; the mark is kept for if you turn them on."
        }
        return Question(title: "Mark this Mac as yours?", message: message, keep: "Mark as Mine", done: "Cancel")
    }
}
