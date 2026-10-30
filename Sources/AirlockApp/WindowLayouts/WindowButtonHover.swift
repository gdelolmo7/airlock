import AirlockCore
import AppKit
import SwiftUI

/// Rest the pointer on a window's green button, pick where the window goes.
///
/// A global monitor sees the pointer move — no permission for that. Once it
/// has stopped for a moment, one Accessibility look at the point says whether
/// it is resting on a green button, and whose. Only then does the grid open,
/// beside the button and past whatever menu macOS (or another tool) opened
/// there, with the same outline on the screen as the strip under the notch.
/// A click on a tile puts the window there and brings it to the front.
///
/// The grid is the one window of Airlock's that takes a click here, and it
/// takes it without coming forward itself: the other app stays the active
/// one. Moving away, clicking anywhere else, or Escape closes it.
@MainActor
final class WindowButtonHover {
    private let model: WindowLayoutModel
    private var monitors: [Any] = []
    private var lastMove = Date.distantPast
    private var resting: Task<Void, Never>?

    /// What is open: the grid, the window it moves, and where.
    private var picker: WindowButtonPicker?
    private var window: AXUIElement?
    private var pid: pid_t = 0
    private var screen: NSScreen?
    /// The window's size when the grid opened: what the centre tile's
    /// outline shows, since centring keeps it.
    private var size: CGSize = .zero
    private var watch: Timer?
    private var ticks = 0
    private var outsideSince: Date?
    /// The button a grid was just closed on: not opened again until the
    /// pointer has left it, or a pointer still on it would reopen what Escape
    /// just closed.
    private var closedOn: CGRect?

    private let grid = WindowButtonGridWindow()
    private let outline = WindowLayoutOutlineWindow()

    /// How long the pointer stays still before the button is looked at.
    private static let rest: TimeInterval = 0.35
    /// How long it may be away from the button and the grid before it closes.
    private static let grace: TimeInterval = 0.3

    init(model: WindowLayoutModel) {
        self.model = model
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }) {
            monitors.append(moved)
        }
        // A press anywhere else, in another app, closes it.
        if let pressed = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                           handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(pressed)
        }
        // Escape goes to the other app, which is still the active one; seen
        // here through Accessibility, which the layouts have already.
        if let key = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let escape = event.keyCode == 53
            MainActor.assumeIsolated { if escape { self?.close() } }
        }) {
            monitors.append(key)
        }
        // A click on the grid itself: the tile under it.
        if let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            let number = event.window?.windowNumber
            let picked = MainActor.assumeIsolated { () -> Bool in
                guard let self, let number, number == self.grid.panel?.windowNumber else { return false }
                self.pick()
                return true
            }
            return picked ? nil : event
        }) {
            monitors.append(click)
        }
    }

    private var isOn: Bool {
        model.isEnabled && model.greenButtonEnabled && model.movesWindows && WindowMover.canMove
    }

    // MARK: - Resting on the button

    private func moved() {
        guard picker == nil else { return }
        let pointer = NSEvent.mouseLocation
        if let closedOn, !closedOn.insetBy(dx: -4, dy: -4).contains(pointer) { self.closedOn = nil }
        guard isOn else { return }
        lastMove = Date()
        guard resting == nil else { return }
        // One wait per rest, not one timer per move: moves come by the
        // hundred a second.
        resting = Task { @MainActor [weak self] in
            while let self {
                let still = Date().timeIntervalSince(self.lastMove)
                if still >= Self.rest { break }
                try? await Task.sleep(nanoseconds: UInt64((Self.rest - still) * 1_000_000_000))
                if Task.isCancelled { return }
            }
            self?.resting = nil
            self?.rested()
        }
    }

    private func rested() {
        let pointer = NSEvent.mouseLocation
        guard picker == nil, isOn, closedOn.map({ !$0.contains(pointer) }) ?? true,
              let found = WindowMover.greenButton(at: pointer),
              let frame = WindowMover.frame(of: found.window),
              let screen = WindowMover.screen(of: frame) else { return }
        let avoiding = WindowMover.smallWindows(inFrontOf: frame, of: found.pid, near: found.button)
        let picker = WindowButtonPicker(button: found.button, visible: screen.visibleFrame, avoiding: avoiding)
        self.picker = picker
        window = found.window
        pid = found.pid
        self.screen = screen
        size = frame.size
        outsideSince = nil
        ticks = 0
        grid.show(picker)
        watch = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Open

    private func tick() {
        guard let picker, let window, let screen else { return close() }
        let pointer = NSEvent.mouseLocation
        if picker.holds(pointer) {
            outsideSince = nil
        } else if let outsideSince {
            if Date().timeIntervalSince(outsideSince) >= Self.grace { return close() }
        } else {
            outsideSince = Date()
        }
        let hovered = picker.pick(at: pointer)
        grid.hover(hovered)
        switch hovered {
        case .layout(let layout):
            outline.show(layout.frame(in: screen.visibleFrame), name: layout.name)
        case .centre:
            outline.show(WindowLayout.centred(size, in: screen.visibleFrame),
                         name: WindowLayoutAction.centre.name)
        case nil:
            outline.hide()
        }
        // A menu that opened after the grid (macOS's own comes a beat
        // later): every few ticks, step past it again.
        ticks += 1
        if ticks % 6 == 0, hovered == nil, let frame = WindowMover.frame(of: window) {
            let avoiding = WindowMover.smallWindows(inFrontOf: frame, of: pid, near: picker.button)
            let moved = WindowButtonPicker(button: picker.button, visible: screen.visibleFrame, avoiding: avoiding)
            if moved != picker {
                self.picker = moved
                grid.move(moved)
            }
        }
    }

    private func pick() {
        guard let picker, let window, let screen,
              let choice = picker.pick(at: NSEvent.mouseLocation) else { return }
        let pid = self.pid
        close()
        switch choice {
        case .layout(let layout): model.apply(layout, to: window, on: screen)
        case .centre: model.centre(window, on: screen)
        }
        WindowMover.raise(window, of: pid)
    }

    private func close() {
        resting?.cancel()
        resting = nil
        watch?.invalidate()
        watch = nil
        guard let picker else { return }
        closedOn = picker.button
        self.picker = nil
        window = nil
        screen = nil
        grid.hide()
        outline.hide()
    }
}

// MARK: - The grid

/// The grid's window: a black tray of tiles, beside the green button.
@MainActor
final class WindowButtonGridWindow {
    private(set) var panel: NSPanel?
    private var hosting: NSHostingView<WindowButtonGrid>?
    private let state = WindowButtonGridState()
    private var closing: Task<Void, Never>?

    func show(_ picker: WindowButtonPicker) {
        closing?.cancel()
        let panel = self.panel ?? make(picker)
        self.panel = panel
        hosting?.rootView = WindowButtonGrid(picker: picker, state: state)
        panel.setFrame(picker.panel, display: false)
        panel.orderFrontRegardless()
        state.hovered = nil
        state.isOpen = true
    }

    /// Somewhere else, already open: no second opening motion.
    func move(_ picker: WindowButtonPicker) {
        hosting?.rootView = WindowButtonGrid(picker: picker, state: state)
        panel?.setFrame(picker.panel, display: true)
    }

    func hover(_ pick: WindowButtonPicker.Pick?) {
        guard state.hovered != pick else { return }
        state.hovered = pick
    }

    func hide() {
        guard state.isOpen else { return }
        state.isOpen = false
        state.hovered = nil
        closing = Task { @MainActor [weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(Motion.close.response * 1_000_000_000))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private func make(_ picker: WindowButtonPicker) -> NSPanel {
        let panel = overlayPanel()
        // Takes the click on a tile; still never comes forward for it.
        panel.ignoresMouseEvents = false
        // One above menus: macOS's own menu on the green button can open
        // after the grid, while the pointer is already on a tile, and at the
        // same level the later window would cover this one.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        let hosting = NSHostingView(rootView: WindowButtonGrid(picker: picker, state: state))
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }
}

/// What the grid shows: open or closing, and the tile under the pointer.
@MainActor
@Observable
final class WindowButtonGridState {
    var isOpen = false
    var hovered: WindowButtonPicker.Pick?
}

struct WindowButtonGrid: View {
    let picker: WindowButtonPicker
    let state: WindowButtonGridState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.isOpen {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    ForEach(picker.tiles.indices, id: \.self) { index in
                        let tile = picker.tiles[index]
                        WindowLayoutTile(unit: tile.pick.unitFrame, name: tile.pick.name,
                                         lit: state.hovered == tile.pick)
                            .frame(width: tile.frame.width, height: tile.frame.height)
                            .offset(x: tile.frame.minX, y: tile.frame.minY)
                    }
                }
                .transition(Motion.open.transition(reduceMotion: reduceMotion))
            }
        }
        .frame(width: picker.panel.width, height: picker.panel.height, alignment: .topLeading)
        .animation(state.isOpen ? Motion.open.animation(reduceMotion: reduceMotion)
                                : Motion.close.animation(reduceMotion: reduceMotion),
                   value: state.isOpen)
        .animation(MotionEffect.pointer, value: state.hovered)
    }
}

extension WindowButtonPicker.Pick {
    var name: String {
        switch self {
        case .layout(let layout): return layout.name
        case .centre: return WindowLayoutAction.centre.name
        }
    }
}
