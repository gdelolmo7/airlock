import AirlockCore
import AppKit
import Carbon.HIToolbox
import Observation

/// Window layouts: the switch, the keyboard shortcuts, and putting a window
/// where it was asked to go.
///
/// One for the app (`shared`), because the drag watcher, the shortcuts and
/// Settings all mean the same switch, and none of them owns the others.
@MainActor
@Observable
final class WindowLayoutModel {
    static let shared = WindowLayoutModel()

    /// Everything off: no strip under the notch, no shortcuts.
    var isEnabled: Bool = Defaults.bool("windowLayouts.enabled", default: true) {
        didSet {
            guard isEnabled != oldValue else { return }
            Defaults.set(isEnabled, "windowLayouts.enabled")
            applyShortcuts()
        }
    }

    /// On to begin with (the owner's call): the layouts are reached by
    /// their keys more than by the menu. A chord another app already holds
    /// fails to register and says so under its row (`shortcutErrors`), and
    /// one switch here turns them all off for anybody with a window tool.
    var shortcutsEnabled: Bool = Defaults.bool("windowLayouts.shortcuts", default: true) {
        didSet {
            guard shortcutsEnabled != oldValue else { return }
            Defaults.set(shortcutsEnabled, "windowLayouts.shortcuts")
            applyShortcuts()
        }
    }

    /// The grid beside a window's green button (`WindowButtonHover`). On to
    /// begin with; off for anybody whose own window tool opens there.
    var greenButtonEnabled: Bool = Defaults.bool("windowLayouts.greenButton", default: true) {
        didSet {
            guard greenButtonEnabled != oldValue else { return }
            Defaults.set(greenButtonEnabled, "windowLayouts.greenButton")
        }
    }

    /// The plan's limits, asked each time a window would move. Nil before
    /// launch has made the licence, and in tests: nothing to hold back.
    @ObservationIgnored var plan: () -> PlanLimits? = { nil }

    /// Whether this plan puts windows in place (`PlanLimits.movesWindows`).
    /// Free still sees the strip and the menu's rows, with a Plus tag, and
    /// nothing moves.
    var movesWindows: Bool { plan()?.movesWindows ?? true }

    private(set) var shortcuts: [WindowLayoutAction: GlobalHotkey.Binding] = [:]
    /// Why a shortcut is not registered, by action — see `GlobalHotkey.lastError`.
    private(set) var shortcutErrors: [WindowLayoutAction: String] = [:]

    @ObservationIgnored private var registrations: [WindowLayoutAction: GlobalHotkey] = [:]

    /// Where each window was before Airlock first moved it, for "Put it
    /// back". Newest last, a handful kept: this is for the window you just
    /// tiled by mistake, not a history.
    @ObservationIgnored private var before: [(window: AXUIElement, frame: CGRect, placed: CGRect)] = []
    private static let remembered = 20

    private init() {
        for action in WindowLayoutAction.allCases {
            shortcuts[action] = Defaults.binding(action.defaultsKey, default: action.defaultShortcut)
        }
    }

    func start() {
        applyShortcuts()
    }

    /// A plan change takes the shortcuts' keys back, or gives them, at once.
    func planDidChange() {
        applyShortcuts()
    }

    func setShortcut(_ binding: GlobalHotkey.Binding, for action: WindowLayoutAction) {
        guard shortcuts[action] != binding else { return }
        shortcuts[action] = binding
        Defaults.setBinding(binding, action.defaultsKey)
        applyShortcuts()
    }

    /// Another layout already on this chord, said while the key is fresh.
    func conflict(_ binding: GlobalHotkey.Binding, for action: WindowLayoutAction) -> String? {
        guard let other = WindowLayoutAction.allCases.first(where: { $0 != action && shortcuts[$0] == binding })
        else { return nil }
        return String(localized: "\(binding.displayName) is already used for \(other.name).")
    }

    private func applyShortcuts() {
        registrations.values.forEach { $0.unregister() }
        shortcutErrors = [:]
        // Not on Free: a shortcut that moves nothing would still take its
        // keys from every other app.
        guard isEnabled, shortcutsEnabled, movesWindows else { return }
        for action in WindowLayoutAction.allCases {
            guard let binding = shortcuts[action] else { continue }
            let registration = registrations[action] ?? GlobalHotkey()
            registrations[action] = registration
            registration.register(binding) { [weak self] in self?.perform(action) }
            if let error = registration.lastError { shortcutErrors[action] = error }
        }
    }

    // MARK: - Moving windows

    /// A shortcut: the front window, on the screen it is on.
    func perform(_ action: WindowLayoutAction) {
        guard movesWindows, let window = WindowMover.frontWindow() else { return }
        switch action {
        case .layout(let layout):
            guard let frame = WindowMover.frame(of: window),
                  let screen = WindowMover.screen(of: frame) else { return }
            apply(layout, to: window, on: screen)
        case .centre:
            guard let frame = WindowMover.frame(of: window),
                  let screen = WindowMover.screen(of: frame) else { return }
            centre(window, on: screen)
        case .restore:
            restore(window)
        }
    }

    /// Puts `window` in `layout` on `screen`, keeping the menu bar and the
    /// Dock in view.
    func apply(_ layout: WindowLayout, to window: AXUIElement, on screen: NSScreen) {
        guard movesWindows, !WindowMover.isFullScreen(window), let current = WindowMover.frame(of: window) else { return }
        let visible = screen.visibleFrame
        guard let placed = WindowMover.move(window, to: layout.frame(in: visible), within: visible) else { return }
        remember(window, was: current, now: placed)
    }

    /// The middle of `screen`, at the size the window already is.
    func centre(_ window: AXUIElement, on screen: NSScreen) {
        guard movesWindows, !WindowMover.isFullScreen(window), let current = WindowMover.frame(of: window) else { return }
        let visible = screen.visibleFrame
        let target = WindowLayout.centred(current.size, in: visible)
        guard let placed = WindowMover.move(window, to: target, within: visible) else { return }
        remember(window, was: current, now: placed)
    }

    /// Back to where it was before Airlock moved it. Nothing to go back to,
    /// nothing happens.
    func restore(_ window: AXUIElement) {
        guard let index = before.lastIndex(where: { CFEqual($0.window, window) }) else { return }
        let entry = before.remove(at: index)
        let visible = (WindowMover.screen(of: entry.frame) ?? NSScreen.main)?.visibleFrame ?? entry.frame
        WindowMover.move(window, to: entry.frame, within: visible)
    }

    /// The first move remembers where the window was. A second move keeps
    /// that first frame — "back" means back to how you had it, not to the
    /// left half you tried on the way — unless the window was moved by hand
    /// since, which makes where it is now the new "how you had it".
    private func remember(_ window: AXUIElement, was current: CGRect, now placed: CGRect) {
        var original = current
        if let index = before.lastIndex(where: { CFEqual($0.window, window) }) {
            let entry = before.remove(at: index)
            if Self.same(entry.placed, current) { original = entry.frame }
        }
        before.append((window, original, placed))
        if before.count > Self.remembered { before.removeFirst(before.count - Self.remembered) }
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}

/// What a shortcut can do: a layout, the middle of the screen at the size
/// the window is, or put the window back.
enum WindowLayoutAction: Hashable, Identifiable {
    case layout(WindowLayout)
    case centre
    case restore

    static let allCases: [WindowLayoutAction] = WindowLayout.pickerOrder.map(Self.layout) + [.centre, .restore]

    var id: String { defaultsKey }

    var defaultsKey: String {
        switch self {
        case .layout(let layout): return "windowLayouts.shortcut.\(layout.rawValue)"
        case .centre: return "windowLayouts.shortcut.centre"
        case .restore: return "windowLayouts.shortcut.restore"
        }
    }

    var name: String {
        switch self {
        case .layout(let layout): return layout.name
        case .centre: return String(localized: "Centre")
        case .restore: return String(localized: "Put it back")
        }
    }

    /// Control-Option and a key that looks like the place: the arrows for the
    /// halves, Return for all of it, C for the centre, Delete to undo, and the
    /// D-F-G row for the thirds with E and T above them for two thirds.
    var defaultShortcut: GlobalHotkey.Binding {
        let key: Int
        switch self {
        case .layout(.leftHalf): key = kVK_LeftArrow
        case .layout(.rightHalf): key = kVK_RightArrow
        case .layout(.topHalf): key = kVK_UpArrow
        case .layout(.bottomHalf): key = kVK_DownArrow
        case .layout(.topLeftQuarter): key = kVK_ANSI_U
        case .layout(.topRightQuarter): key = kVK_ANSI_I
        case .layout(.bottomLeftQuarter): key = kVK_ANSI_J
        case .layout(.bottomRightQuarter): key = kVK_ANSI_K
        case .layout(.leftThird): key = kVK_ANSI_D
        case .layout(.centerThird): key = kVK_ANSI_F
        case .layout(.rightThird): key = kVK_ANSI_G
        case .layout(.leftTwoThirds): key = kVK_ANSI_E
        case .layout(.rightTwoThirds): key = kVK_ANSI_T
        case .layout(.fullScreen): key = kVK_Return
        case .centre: key = kVK_ANSI_C
        case .restore: key = kVK_Delete
        }
        return GlobalHotkey.Binding(keyCode: UInt32(key), carbonModifiers: UInt32(controlKey | optionKey))
    }
}

extension WindowLayout {
    var name: String {
        switch self {
        case .leftHalf: return String(localized: "Left half")
        case .rightHalf: return String(localized: "Right half")
        case .topHalf: return String(localized: "Top half")
        case .bottomHalf: return String(localized: "Bottom half")
        case .topLeftQuarter: return String(localized: "Top left quarter")
        case .topRightQuarter: return String(localized: "Top right quarter")
        case .bottomLeftQuarter: return String(localized: "Bottom left quarter")
        case .bottomRightQuarter: return String(localized: "Bottom right quarter")
        case .leftThird: return String(localized: "Left third")
        case .centerThird: return String(localized: "Middle third")
        case .rightThird: return String(localized: "Right third")
        case .leftTwoThirds: return String(localized: "Left two thirds")
        case .rightTwoThirds: return String(localized: "Right two thirds")
        case .fullScreen: return String(localized: "Whole screen")
        }
    }
}
