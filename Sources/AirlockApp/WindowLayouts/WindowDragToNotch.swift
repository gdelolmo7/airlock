import AirlockCore
import AppKit
import SwiftUI
import DynamicNotchKit

/// Drag a window up to the notch, pick where it goes.
///
/// Watches the button with global monitors (down, dragged, up) — no
/// permission for those; only key events are guarded. While a press is
/// young it reads the front window a few times a second, and `WindowDrag`
/// decides whether that window is following the pointer. Once it is, the
/// pointer coming up to the notch drops the strip of layouts out of it, the
/// tile under the pointer shows its outline on the screen, and letting go on
/// a tile puts the window there. Letting go anywhere else does nothing.
///
/// Windows of their own, not the island. The drag belongs to the other app
/// until the button comes up, so nothing here can take a click, and the
/// island grows only for a question or a resting pointer; the strip is a
/// caption of the gesture, like the line `DragHintWindow` draws for a file.
@MainActor
final class WindowDragToNotch {
    private let model: WindowLayoutModel
    private var monitors: [Any] = []
    private var drag = WindowDrag()
    private var lastLook: Date?
    /// The window found following the pointer: the one that will move.
    private var window: AXUIElement?
    private var picker: WindowLayoutPicker?
    private let strip = WindowLayoutStripWindow()
    private let outline = WindowLayoutOutlineWindow()

    /// How often a young press reads the front window. Accessibility asks the
    /// other app, and dragged events come by the hundred a second.
    private static let lookInterval: TimeInterval = 0.08

    init(model: WindowLayoutModel) {
        self.model = model
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        // Global only: a press in Airlock's own windows is never another
        // app's window being moved.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }) {
            monitors.append(monitor)
        }
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            reset()
            guard model.isEnabled, WindowMover.canMove else { return }
            drag.pressed()
        case .leftMouseDragged:
            dragged()
        case .leftMouseUp:
            released()
        default:
            break
        }
    }

    private func dragged() {
        let pointer = NSEvent.mouseLocation
        guard drag.isMovingWindow else {
            let now = Date()
            if let lastLook, now.timeIntervalSince(lastLook) < Self.lookInterval { return }
            lastLook = now
            guard let front = WindowMover.frontWindow() else { return }
            if drag.sample(pointer: pointer, window: WindowMover.frame(of: front)) {
                window = WindowMover.isFullScreen(front) ? nil : front
            }
            return
        }
        guard window != nil, let screen = NotchScreen.target else { return }
        let picker = self.picker ?? WindowLayoutPicker(screen: screen.frame,
                                                       notchHeight: screen.islandMetrics.notchHeight)
        if self.picker == nil {
            guard picker.reaches(pointer) else { return }
            self.picker = picker
            strip.show(picker)
        } else if !picker.holds(pointer) {
            closeStrip()
            return
        }
        let hovered = picker.layout(at: pointer)
        strip.hover(hovered)
        if let hovered {
            // On Free the outline still shows where it would go, and says
            // what it needs; letting go moves nothing.
            let name = model.movesWindows ? hovered.name
                : String(localized: "\(hovered.name) · Comes with Plus")
            outline.show(hovered.frame(in: screen.visibleFrame), name: name)
        } else {
            outline.hide()
        }
    }

    private func released() {
        defer { reset() }
        guard let window, let picker, let screen = NotchScreen.target,
              let layout = picker.layout(at: NSEvent.mouseLocation) else { return }
        // A beat after the button: the app finishes its own move on the
        // release, and a frame set before that is overwritten by it.
        Task { @MainActor [model] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            model.apply(layout, to: window, on: screen)
        }
    }

    private func closeStrip() {
        picker = nil
        strip.hide()
        outline.hide()
    }

    private func reset() {
        closeStrip()
        drag.released()
        lastLook = nil
        window = nil
    }
}

// MARK: - The strip

@MainActor
@Observable
final class WindowLayoutStripState {
    var isOpen = false
    var hovered: WindowLayout?
}

/// The strip itself: a black tray under the notch with a small screen
/// drawn for each layout.
@MainActor
final class WindowLayoutStripWindow {
    private var panel: NSPanel?
    private var hosting: NSHostingView<WindowLayoutStrip>?
    private let state = WindowLayoutStripState()
    private var closing: Task<Void, Never>?

    func show(_ picker: WindowLayoutPicker) {
        closing?.cancel()
        let panel = self.panel ?? make(picker)
        self.panel = panel
        // Rebuilt each time: the screen it measures can have changed since.
        hosting?.rootView = WindowLayoutStrip(picker: picker, state: state)
        panel.setFrame(picker.panel, display: false)
        panel.orderFrontRegardless()
        state.hovered = nil
        state.isOpen = true
    }

    func hover(_ layout: WindowLayout?) {
        guard state.hovered != layout else { return }
        state.hovered = layout
    }

    func hide() {
        guard state.isOpen else { return }
        state.isOpen = false
        state.hovered = nil
        // Ordered out once the Close motion has played.
        closing = Task { @MainActor [weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(Motion.close.response * 1_000_000_000))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private func make(_ picker: WindowLayoutPicker) -> NSPanel {
        let panel = overlayPanel()
        let hosting = NSHostingView(rootView: WindowLayoutStrip(picker: picker, state: state))
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }
}

struct WindowLayoutStrip: View {
    let picker: WindowLayoutPicker
    let state: WindowLayoutStripState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if state.isOpen {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    ForEach(picker.tiles.indices, id: \.self) { index in
                        let tile = picker.tiles[index]
                        WindowLayoutTile(layout: tile.layout, lit: state.hovered == tile.layout)
                            .frame(width: tile.frame.width, height: tile.frame.height)
                            .offset(x: tile.frame.minX, y: tile.frame.minY)
                    }
                }
                .transition(Motion.open.transition(reduceMotion: reduceMotion))
            }
        }
        .frame(width: picker.panel.width, height: picker.panel.height, alignment: .top)
        .animation(state.isOpen ? Motion.open.animation(reduceMotion: reduceMotion)
                                : Motion.close.animation(reduceMotion: reduceMotion),
                   value: state.isOpen)
        .animation(MotionEffect.pointer, value: state.hovered)
    }
}

/// A little screen with the layout's part of it filled in.
struct WindowLayoutTile: View {
    /// The part of the little screen filled in, as `WindowLayout.unitFrame`.
    let unit: CGRect
    let name: String
    let lit: Bool

    init(unit: CGRect, name: String, lit: Bool) {
        self.unit = unit
        self.name = name
        self.lit = lit
    }

    init(layout: WindowLayout, lit: Bool) {
        self.init(unit: layout.unitFrame, name: layout.name, lit: lit)
    }

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 3
            let width = proxy.size.width - inset * 2
            let height = proxy.size.height - inset * 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(lit ? 0.16 : 0.06))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(lit ? 0.9 : 0.3), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white.opacity(lit ? 1 : 0.55))
                    // Half a point in from each shared edge, so two
                    // neighbouring parts read as two.
                    .frame(width: width * unit.width - (unit.width < 1 ? 1 : 0),
                           height: height * unit.height - (unit.height < 1 ? 1 : 0))
                    .offset(x: inset + width * unit.minX + (unit.minX > 0 ? 0.5 : 0),
                            y: inset + height * (1 - unit.maxY) + (unit.maxY < 1 ? 0.5 : 0))
            }
        }
        .scaleEffect(lit ? 1.08 : 1)
        .accessibilityLabel(name)
    }
}

// MARK: - The outline

/// Where the window will land, drawn on the screen while a tile is lit.
@MainActor
final class WindowLayoutOutlineWindow {
    private var panel: NSPanel?
    private var hosting: NSHostingView<WindowLayoutOutline>?

    func show(_ frame: CGRect, name: String) {
        let panel = self.panel ?? make()
        self.panel = panel
        hosting?.rootView = WindowLayoutOutline(name: name)
        let wasVisible = panel.isVisible
        if wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    private func make() -> NSPanel {
        let panel = overlayPanel()
        // Under the strip and the island, over the window being dragged.
        panel.level = .floating
        let hosting = NSHostingView(rootView: WindowLayoutOutline(name: ""))
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }
}

struct WindowLayoutOutline: View {
    let name: String

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.7), lineWidth: 2))
            .overlay {
                Text(name)
                    .font(Theme.fixed(13, .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.pill))
            }
            .padding(4)
    }
}

/// A caption window: never a target, never in the way of the drag, on every
/// Space and over full screen like the island.
@MainActor
func overlayPanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.canHide = false
    panel.level = .statusBar
    panel.collectionBehavior = DynamicNotchOverlay.collectionBehavior
    return panel
}
