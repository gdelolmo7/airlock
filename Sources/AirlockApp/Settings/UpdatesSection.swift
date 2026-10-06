import AppKit
import SwiftUI

/// Settings › General › Updates, from plain values.
///
/// Out of `AboutSettings` so the state gallery can draw it without starting
/// Sparkle: the page itself needs the live updater model, and an updater that
/// failed, or one waiting for the app to quit, is exactly the state nobody can
/// reach on purpose.
struct UpdatesSection: View {
    @Binding var checksAutomatically: Bool
    let lastCheck: Date?
    let canCheck: Bool
    /// `UpdaterModel.statusLine`: how the updater stands, and why Check Now is
    /// greyed out whenever it is.
    let statusLine: String?
    var onCheck: () -> Void = {}

    var body: some View {
        Section("Should Airlock keep itself up to date?") {
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .settingsAnchor(.updates)
            LabeledContent("Last checked") {
                Text(lastCheckLabel).foregroundStyle(.secondary)
            }
            // Disabled rather than hidden while a check is already running:
            // the button not being there would read as the updater having gone
            // away. Greyed out, it now always has the line below saying why.
            Button("Check Now", action: onCheck)
                .disabled(!canCheck)
            if let statusLine {
                Text(statusLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Sparkle asks once, on the second launch, and this switch is that
            // answer — readable and changeable here forever after. It is never
            // flipped on for somebody: the plist leaves
            // `SUEnableAutomaticChecks` absent, which Sparkle treats as "ask".
            //
            // It also said checking was "the only outbound request Airlock ever
            // makes", which stopped being true with the licence server and the
            // guide. What is true about the check itself is what it says now.
            Text("Airlock asks once, on its second launch, whether it may check for updates — and does nothing if you say no. A check fetches one small file and sends nothing about you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Whatever arrives is checked against a signing key built into this copy of the app, so a web host that has been taken over can serve anything it likes and the update is refused rather than run.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastCheckLabel: String {
        guard let lastCheck else { return "Never" }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }
}

/// What General says when Launch at login could not be changed.
///
/// Amber with a way out, not red: nothing is broken, macOS turned the change
/// down and the switch is one click away in System Settings. It used to be a
/// red card with the path spelled out and no button.
struct LaunchAtLoginProblem: View {
    let note: String

    var body: some View {
        ProblemCard(sentence: note, tone: .needs, button: "Open Login Items") {
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
