import AirlockCore
import AppKit
import Carbon.HIToolbox

/// Window layouts in Airlock's own menu: a "Window Layouts" row whose
/// submenu has every layout, a picture of it and its shortcut.
///
/// In Airlock's menu rather than an icon of its own, the owner's call
/// (2026-10-28): one icon in the menu bar, not two.
@MainActor
final class WindowLayoutsMenu: NSObject, NSMenuDelegate {
    private let model: WindowLayoutModel
    private let openSettings: () -> Void
    private let openPlans: () -> Void

    init(model: WindowLayoutModel, openSettings: @escaping () -> Void, openPlans: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.openPlans = openPlans
    }

    /// The submenu, filled each time it opens. The menu holds its delegate
    /// weakly, so whoever asks keeps this object.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window Layouts"))
        menu.delegate = self
        return menu
    }

    // MARK: - The menu

    /// Built each time it opens, so a shortcut changed in Settings or the
    /// permission granted since shows at once.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let canMove = WindowMover.canMove
        // On Free every row stays, tagged, and choosing one opens Plans.
        let onPlan = model.movesWindows
        if onPlan, !canMove {
            menu.addItem(row(String(localized: "Allow Accessibility to Move Windows…"),
                             #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        var lastGroup: Int?
        for action in WindowLayoutAction.allCases {
            let group = Self.group(of: action)
            if let lastGroup, lastGroup != group { menu.addItem(.separator()) }
            lastGroup = group

            let entry = row(action.name, #selector(choose(_:)))
            entry.representedObject = action.defaultsKey
            entry.image = Self.icon(for: action)
            entry.isEnabled = canMove || !onPlan
            if !onPlan { entry.badge = NSMenuItemBadge(string: AirlockPlan.plus.label) }
            // The chord only while it really is one. A menu's key equivalent
            // also fires while the menu is open, which does the same thing.
            if onPlan, model.shortcutsEnabled, let binding = model.shortcuts[action],
               let key = Self.keyEquivalent(binding.keyCode) {
                entry.keyEquivalent = key
                entry.keyEquivalentModifierMask = binding.cocoaModifiers
            }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(row(String(localized: "Window Layout Settings…"), #selector(settings)))
    }

    private func row(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// The window in front is still the other app's: opening a menu bar menu
    /// does not change which app is frontmost.
    @objc private func choose(_ sender: NSMenuItem) {
        guard model.movesWindows else { return openPlans() }
        guard let key = sender.representedObject as? String,
              let action = WindowLayoutAction.allCases.first(where: { $0.defaultsKey == key }) else { return }
        model.perform(action)
    }

    @objc private func openAccessibility() { PasteService.openAccessibilitySettings() }
    @objc private func settings() { openSettings() }

    /// Halves, quarters, thirds, two thirds, the whole screen, then centre
    /// and back: a line between each, as the strip under the notch groups
    /// them.
    private static func group(of action: WindowLayoutAction) -> Int {
        switch action {
        case .layout(let layout): layout.group
        case .centre, .restore: 5
        }
    }

    /// What `NSMenuItem` wants for the keys the layouts use. Nil for a key
    /// it cannot show, which then has no chord on its row.
    private static func keyEquivalent(_ keyCode: UInt32) -> String? {
        func char(_ scalar: Int) -> String { String(Character(UnicodeScalar(UInt16(scalar))!)) }
        switch Int(keyCode) {
        case kVK_LeftArrow: return char(NSLeftArrowFunctionKey)
        case kVK_RightArrow: return char(NSRightArrowFunctionKey)
        case kVK_UpArrow: return char(NSUpArrowFunctionKey)
        case kVK_DownArrow: return char(NSDownArrowFunctionKey)
        case kVK_Return: return "\r"
        case kVK_Delete: return char(NSBackspaceCharacter)
        case kVK_Space: return " "
        default:
            // Letters and digits: the binding's own name, lower-cased, since
            // an upper-case key equivalent means Shift as well.
            let name = GlobalHotkey.Binding(keyCode: keyCode, carbonModifiers: 0).displayName
            guard name.count == 1, let c = name.first, c.isLetter || c.isNumber else { return nil }
            return name.lowercased()
        }
    }

    // MARK: - Pictures

    private static let iconSize = NSSize(width: 18, height: 12)

    /// A little screen with the layout's part filled, like the strip's tiles.
    /// Centre is a smaller window in the middle; back is the system's arrow.
    private static func icon(for action: WindowLayoutAction) -> NSImage? {
        if case .restore = action {
            return NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        }
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let screen = rect.insetBy(dx: 0.5, dy: 0.5)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1
            outline.stroke()
            let inside = screen.insetBy(dx: 2, dy: 2)
            let part: CGRect
            switch action {
            case .layout(let layout):
                let unit = layout.unitFrame
                part = CGRect(x: inside.minX + inside.width * unit.minX,
                              y: inside.minY + inside.height * unit.minY,
                              width: inside.width * unit.width, height: inside.height * unit.height)
            default:
                part = inside.insetBy(dx: inside.width * 0.25, dy: inside.height * 0.2)
            }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: part, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
