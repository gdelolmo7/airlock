import AirlockCore
import SwiftUI

/// Keep-awake's options, rows on the notch page: when it stops on battery,
/// whether it holds while an agent works, whether the screen may still turn
/// off, and a shortcut that presses the rail's button from anywhere.
struct KeepAwakeSection: View {
    @Bindable var controls: SystemControlsModel

    var body: some View {
        LookRow("Stop on battery", subtitle: "It turns itself off at this level, and the notch says so") {
            LookMenu(controls.keepAwakeCutoff == 0 ? "Never" : "Below \(controls.keepAwakeCutoff)%") {
                Picker("Stop on battery", selection: $controls.keepAwakeCutoff) {
                    ForEach(KeepAwakePolicy.cutoffChoices, id: \.self) { level in
                        Text(level == 0 ? "Never" : "Below \(level)%").tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.keepAwakeCutoff)

        // Card Awake 1. First of the switches, because it is the one that
        // works without anybody pressing anything.
        LookToggleRow("While an agent is working",
                      subtitle: "While Claude Code or Codex is busy, not while one waits for you",
                      isOn: $controls.awakeWhileAgentsWork)
            .settingsAnchor(.keepAwakeAgents)
        LookToggleRow("Also on battery", subtitle: "Off, only while the Mac is plugged in",
                      isOn: $controls.awakeWhileAgentsWorkOnBattery)
            .disabled(!controls.awakeWhileAgentsWork)

        LookToggleRow("Let the screen turn off", subtitle: "The Mac keeps working while the display sleeps",
                      isOn: $controls.letsScreenSleep)
            .settingsAnchor(.keepAwakeScreen)

        LookToggleRow("Keyboard shortcut", subtitle: "Turns keep awake on and off from any app",
                      isOn: $controls.hotkeyEnabled)
            .settingsAnchor(.keepAwakeShortcut)
        if controls.hotkeyEnabled {
            HotkeyRecorder("Shortcut", binding: $controls.hotkey, conflict: { _ in nil })
            if let error = controls.hotkeyError {
                ProblemCard(sentence: error, tone: .stopped)
            }
        }
    }
}
