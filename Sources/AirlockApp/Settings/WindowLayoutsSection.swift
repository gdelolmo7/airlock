import AirlockCore
import SwiftUI

/// Window layouts, the rows of its add-on page: the grid on the green
/// button, and the keyboard shortcuts, each one changeable.
struct WindowLayoutsSection: View {
    @Bindable var layouts: WindowLayoutModel
    /// Read when the page appears and on every redraw; the permission is
    /// granted in System Settings, which the page comes back from.
    private var canMove: Bool { WindowMover.canMove }
    @Environment(LicenseModel.self) private var license: LicenseModel?
    @Environment(SettingsModel.self) private var settings: SettingsModel?

    /// Read from the licence, so the page redraws when the plan changes.
    private var movesWindows: Bool { license?.entitlement.limits.movesWindows ?? layouts.movesWindows }

    var body: some View {
        // The add-on page's big switch is the switch for all of it.
        if !movesWindows {
            // Free keeps the switch, so the strip can be turned off, and is
            // told here what it needs; the shortcuts wait for Plus.
            LookRow("Put windows in place",
                    subtitle: String(localized: "On Free, the strip shows where a window would go, and it stays put. Plus moves it, and adds the keyboard shortcuts.")) {
                PlanTagButton(.plus) { settings?.reveal(.plans) }
            }
            .settingsAnchor(.windowLayouts)
        } else {
            placingRows
        }
    }

    @ViewBuilder private var placingRows: some View {
        if layouts.isEnabled && !canMove {
            ProblemCard(sentence: String(localized: "Windows can't be moved until Airlock has the Accessibility permission."),
                        button: String(localized: "Open Accessibility Settings"),
                        action: { PasteService.openAccessibilitySettings() })
        }

        LookToggleRow("Rest on the green button",
                      subtitle: String(localized: "Hold the pointer on a window's green button to pick where it goes"),
                      isOn: $layouts.greenButtonEnabled)
            .settingsAnchor(.windowLayouts)
            .disabled(!layouts.isEnabled)

        LookToggleRow("Keyboard shortcuts", subtitle: String(localized: "Move the window in front from any app. Press an arrow twice to send it to the next screen."),
                      isOn: $layouts.shortcutsEnabled)
            .settingsAnchor(.windowLayoutShortcuts)
            .disabled(!layouts.isEnabled)
        if layouts.isEnabled && layouts.shortcutsEnabled {
            ForEach(WindowLayoutAction.allCases) { action in
                HotkeyRecorder(action.name,
                               binding: Binding(get: { layouts.shortcuts[action] ?? action.defaultShortcut },
                                                set: { layouts.setShortcut($0, for: action) }),
                               conflict: { layouts.conflict($0, for: action) })
                if let error = layouts.shortcutErrors[action] {
                    ProblemCard(sentence: error, tone: .stopped)
                }
            }
        }
    }
}
