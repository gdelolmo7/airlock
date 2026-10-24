import AppKit
import SwiftUI
import AirlockCore
import DynamicNotchKit

/// The line under the notch while a file is in hand: "Drop it up here to
/// keep it or change its format".
///
/// A window of its own rather than something the island draws. The island
/// grows only for a question or a pointer resting on it, and a line inside it
/// would make every drag a growth. Out here it is a caption: it takes no
/// clicks and no drops, and the island stays exactly as compact as it was.
@MainActor
final class DragHintWindow {
    private var panel: NSPanel?

    /// Gap between the bottom of the notch and the line.
    static let gap: CGFloat = 8

    func show(on screen: NSScreen) {
        let panel = self.panel ?? make()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? .zero
        let metrics = screen.islandMetrics
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.maxY - metrics.notchHeight - Self.gap - size.height,
                              width: size.width, height: size.height),
                       display: false)
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Gone at once: the file was let go, or the box opened and says it itself.
    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // A caption, never a target: the drag goes through it to whatever
        // is under the pointer.
        panel.ignoresMouseEvents = true
        panel.canHide = false
        panel.level = .statusBar
        panel.collectionBehavior = DynamicNotchOverlay.collectionBehavior
        panel.contentView = NSHostingView(rootView: DragHintLabel())
        return panel
    }
}

/// The line itself, so the state gallery draws exactly this.
struct DragHintLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .semibold))
            Text("Drop it up here to keep it or change its format")
                .font(Theme.fixed(12, .medium))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.pill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .fixedSize()
        .padding(2)
        .accessibilityElement(children: .combine)
    }
}
