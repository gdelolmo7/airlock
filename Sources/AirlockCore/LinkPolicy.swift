import Foundation

/// Which links in agent or model-written text may be opened with a click.
///
/// Markdown from an agent's reply or a call summary can carry any link, and
/// the row shows only the link's words, never its address. A `file:`,
/// `x-apple.systemsettings:` or another app's own scheme would then open
/// something the words did not promise. Web pages and mail are what such text
/// legitimately links to; everything else stays plain words.
public enum LinkPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// The same text with every link that may not be opened turned back into
    /// plain words. `keep` lets a caller keep a link it put there itself.
    public static func strippingDisallowedLinks(_ text: AttributedString,
                                                keep: (URL) -> Bool = { _ in false }) -> AttributedString {
        var result = text
        for run in text.runs {
            guard let url = run.link, !isAllowed(url), !keep(url) else { continue }
            result[run.range].link = nil
        }
        return result
    }
}
