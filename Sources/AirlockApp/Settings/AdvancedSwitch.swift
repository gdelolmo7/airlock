import SwiftUI

/// The one switch that decides whether a pane shows its workings.
///
/// Settings had grown a second audience without anyone deciding to serve it: a
/// raw diagnostics paste in General, a rule tester with a "Tool" field, a
/// precedence table, a gate log, four buttons for editing a YAML file, and a
/// slider measured in points for the space around the camera. Every one of them
/// earns its place when something has gone wrong. All of them together are the
/// first thing a new customer sees, and what they say is "this is not for you".
///
/// **One stored flag, not a disclosure per pane.** Advanced is a fact about the
/// reader rather than five independent decisions — somebody who wants the rule
/// tester also wants the diagnostics paste — and one switch in whichever pane
/// they are looking at beats hunting for five.
///
/// **Hidden, never removed.** Everything behind it still works, is still
/// reachable in one click, and support still gets its paste; a customer who is
/// told "turn on advanced settings" finds the switch on the pane they are
/// already on.
struct AdvancedSwitch: View {
    /// Deliberately NOT one of the `Defaults` keys the widgets use: this is a
    /// preference about the settings window itself, and it should survive
    /// resetting a widget's own state.
    static let key = "settings.showAdvanced"

    @AppStorage(AdvancedSwitch.key) private var advanced = false

    var body: some View {
        Section {
            Toggle("Show advanced settings", isOn: $advanced)
            Text("Diagnostics, the rule tester and the file-level controls. Leave it off unless "
                 + "something has gone wrong — nothing behind it is needed for everyday use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
