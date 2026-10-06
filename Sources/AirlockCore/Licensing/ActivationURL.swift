import Foundation

/// `airlock://activate?key=…` — how the browser hands a key back.
///
/// **Without it the purchase ends in a copy-and-paste**, which is where the
/// hand-off leaks: the key is in an email, the email is on a phone, and the app
/// is a notch panel that collapses when you leave it. A scheme turns three
/// steps into none.
///
/// Pure and value-typed so the parsing is testable without registering a
/// scheme, launching a browser or having a licence — and parsing a URL that
/// arrives from outside the app is exactly the code that should not need any of
/// those to be exercised.
///
/// **Everything here is untrusted.** A URL can be typed by anyone, so this only
/// extracts a candidate string; whether it is a real licence is
/// `LicenseVerifier`'s question, and it is asked afterwards on every path.
public enum ActivationURL {
    public static let scheme = "airlock"
    public static let host = "activate"

    /// The key carried by an activation URL, or nil for anything else.
    ///
    /// Deliberately strict about the shape: an app that accepts
    /// `airlock://anything?key=…` is one whose URL handling grows a second
    /// meaning later and cannot tell the two apart.
    public static func key(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "key" })?.value
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The URL a checkout should send somebody back to.
    ///
    /// Built here rather than written out at the call site so the app and
    /// whatever fills in the checkout template cannot disagree about the shape
    /// — a mismatch there fails as "nothing happened", with no error anywhere.
    public static func url(key: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        return components.url
    }
}
