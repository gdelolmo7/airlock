import AirlockCore
import SwiftUI

/// Keep-awake's three options, next to the widgets on the notch page: when
/// it stops on battery, whether the screen may still turn off, and a
/// shortcut that presses the rail's button from anywhere.
struct KeepAwakeSection: View {
    @Bindable var controls: SystemControlsModel

    var body: some View {
        Section("How should keep awake behave?") {
            Picker(selection: $controls.keepAwakeCutoff) {
                ForEach(KeepAwakePolicy.cutoffChoices, id: \.self) { level in
                    Text(level == 0 ? "Never" : "Below \(level)%").tag(level)
                }
            } label: {
                Text("Stop on battery")
                Text("Keep awake turns itself off at this level, and the notch says so")
            }
            .settingsAnchor(.keepAwakeCutoff)

            // Card Awake 1. First, because it is the one that works without
            // anybody pressing anything.
            Toggle(isOn: $controls.awakeWhileAgentsWork) {
                Text("While an agent is working")
                Text("Keeps the Mac awake while Claude Code or Codex is busy, not while one waits for your answer. The screen can still turn off, and closing the lid still sleeps the Mac")
            }
            .settingsAnchor(.keepAwakeAgents)
            Toggle(isOn: $controls.awakeWhileAgentsWorkOnBattery) {
                Text("Also on battery")
                Text("Off, it only does this while the Mac is plugged in. The battery stop above still applies")
            }
            .disabled(!controls.awakeWhileAgentsWork)

            Toggle(isOn: $controls.letsScreenSleep) {
                Text("Let the screen turn off")
                Text("The Mac keeps working on downloads, renders and agents while the display sleeps")
            }
            .settingsAnchor(.keepAwakeScreen)

            Toggle(isOn: $controls.hotkeyEnabled) {
                Text("Keyboard shortcut")
                Text("Turns keep awake on and off from any app")
            }
            .settingsAnchor(.keepAwakeShortcut)
            if controls.hotkeyEnabled {
                HotkeyRecorder(binding: $controls.hotkey, conflict: { _ in nil })
                if let error = controls.hotkeyError {
                    ProblemCard(sentence: error, tone: .stopped)
                }
            }
        }
    }
}
