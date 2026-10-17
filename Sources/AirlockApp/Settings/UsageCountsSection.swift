import SwiftUI

/// "Share usage counts" on General: the switch, and what a count is.
///
/// Values in rather than the counter read, so the state gallery draws the
/// row as it ships. General shows it only in a build that could send counts
/// (`UsageCounts.isAvailable`), like the crash reports row beside it.
///
/// Off until the person turns it on, here, on the first screen of setup, or
/// from the one question the notch puts to a copy set up before counts
/// existed. Turning it off deletes the counts not sent yet and the random
/// number that told this Mac's apart.
struct UsageCountsSection: View {
    @Binding var isOn: Bool

    var body: some View {
        LookToggleRow("Share usage counts",
                      subtitle: Self.subtitle,
                      isOn: $isOn)
            .settingsAnchor(.usageCounts)
    }

    /// The same line under the switch here, in setup and on the notch's
    /// question, so the three say one thing.
    static let subtitle = "Which features get used and where setup stops, so we know what to fix. Never what you type, say, copy or see."

    /// Behind "More options" on General: what is counted, where it goes, and
    /// what never is. Kept in step with the privacy page on the website,
    /// which says the same in its list of what leaves the Mac.
    static let notes = [
        "A count is a thing that happened, never its content: setup finished or skipped and on which step, a request approved or denied, the clipboard or the shelf used, a call's length and where its notes were written, which widgets are on, and which plan this Mac is on. Each batch also carries the Airlock version, the macOS version, the Mac model and its language.",
        "Never counted: your name, your email, your licence, your Mac's name, what you type, say or copy, what's on your screen, your files or projects, or what your agents were doing. Counts go to Airlock's licence server, which notes the country they came from, drops your Mac's address, and passes them to PostHog, the service that adds them up for us.",
        "A random number made when you say yes tells one Mac's counts from another's. Off until you turn it on. Turning it off deletes the counts not sent yet and that number, and nothing more is counted.",
    ]
}
