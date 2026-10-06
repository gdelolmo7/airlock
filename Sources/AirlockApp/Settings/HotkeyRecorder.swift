import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Press the keys you want, instead of picking from three somebody chose.
///
/// **The pickers this replaces offered a fixed menu of chords.** Three for the
/// clipboard, three for the gate — and if all three were already taken by
/// something else on your Mac, the feature simply had no reachable key. A
/// recorder has no such ceiling: whatever you can press, you can bind.
///
/// A local key monitor rather than a text field. The field would want the
/// keystroke as text — which is the one thing a chord is not — and every
/// modifier combination that happens to type a character would land in it.
///
/// Recording is **modal by intent**: while armed, the monitor swallows the
/// keystroke so the chord being recorded cannot also fire whatever it is
/// currently bound to somewhere else in the app.
struct HotkeyRecorder: View {
    @Binding var binding: GlobalHotkey.Binding
    /// Checked live, so a clash is stated while the key is still fresh in mind
    /// rather than discovered later when the gesture silently does two things.
    var conflict: (GlobalHotkey.Binding) -> String?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var lastRejection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Text(isRecording ? "Press keys…" : binding.displayName)
                        .font(.body.monospaced())
                        .frame(minWidth: 96)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .accessibilityLabel(isRecording
                                    ? "Recording. Press the keys you want."
                                    : "Shortcut, \(binding.spokenName). Activate to change it.")

                if isRecording {
                    Button("Cancel") { stop() }
                        .buttonStyle(.borderless)
                }
            }

            if let lastRejection {
                ProblemCard(sentence: lastRejection)
            } else if let clash = conflict(binding) {
                ProblemCard(sentence: clash)
            }
        }
        // A recorder left armed would keep swallowing keystrokes after the pane
        // it lives on has gone.
        .onDisappear { stop() }
    }

    private func toggle() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        lastRejection = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            // Swallowed: the point of arming is that this keystroke means "bind
            // me", not whatever it usually means.
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        // Escape abandons rather than binds. It is the one key everybody expects
        // to mean "never mind", and binding it would take that meaning away
        // everywhere else.
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.carbon == 0 {
            stop()
            return
        }

        let modifiers = event.modifierFlags.carbon
        // A bare letter is not a shortcut, it is typing. Registering one would
        // take that key away from every app on the Mac — a global hotkey is
        // global — so the recorder refuses rather than letting somebody
        // discover it by pressing "v".
        guard modifiers != 0 else {
            lastRejection = "Add a modifier — ⌘, ⌥, ⌃ or ⇧. A key on its own would be taken from every app."
            return
        }
        // Shift alone shifts. Together with another modifier it is a fine part
        // of a chord, but by itself it is how capital letters are typed.
        guard modifiers != UInt32(shiftKey) else {
            lastRejection = "Shift on its own types capitals — add ⌘, ⌥ or ⌃."
            return
        }

        let candidate = GlobalHotkey.Binding(keyCode: UInt32(event.keyCode),
                                             carbonModifiers: modifiers)
        binding = candidate
        lastRejection = nil
        stop()
    }
}

private extension NSEvent.ModifierFlags {
    /// Carbon's bits, which is what `GlobalHotkey.Binding` and `RegisterEventHotKey`
    /// both speak. `deviceIndependentFlagsMask` first, or the left/right variants
    /// of the same modifier produce different chords for the same gesture.
    var carbon: UInt32 {
        var bits: UInt32 = 0
        let flags = intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        return bits
    }
}
