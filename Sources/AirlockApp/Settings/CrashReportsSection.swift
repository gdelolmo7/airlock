import SwiftUI

/// "Send crash reports" on General: the switch, and what a report is.
///
/// Values in rather than the crash reporter read, so the state gallery draws
/// the row as it ships from a build that has no DSN. General shows it only
/// in a build that could send a report (`CrashReporter.isAvailable`): a
/// switch that can send nothing anywhere is a promise with nothing behind it.
///
/// Off until the person turns it on, here, in setup, or from the one
/// question the notch puts after a run that ended unexpectedly. Turning it
/// off stops the crash handler at once and deletes reports not sent yet.
struct CrashReportsSection: View {
    @Binding var isOn: Bool

    var body: some View {
        LookToggleRow("Send crash reports",
                      subtitle: String(localized: "Only when Airlock crashes. Nothing personal is included."),
                      isOn: $isOn)
            .settingsAnchor(.crashReports)
    }

    /// Behind "More options" on General: what is in a report, where it goes,
    /// and what is never in one. Kept in step with the privacy page on the
    /// website, which says the same in its list of what leaves the Mac.
    static let notes = [
        String(localized: "A crash report is what a fix needs: the Airlock version, the macOS version, the Mac model, and where in Airlock's code it stopped. A report is also sent when Airlock stops answering for five seconds or more."),
        String(localized: "Never in a report: your name, your Mac's name, your files, what's on your screen, what you copied or said, or what your agents were doing. Reports go to Sentry, the service that collects them for us."),
        String(localized: "Off until you turn it on. Turning it off stops it at once and deletes any report not sent yet."),
    ]
}
