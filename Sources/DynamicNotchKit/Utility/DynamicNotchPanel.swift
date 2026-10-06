//
// DynamicNotchPanel.swift
// DynamicNotchKit
//
// Created by <Huy D.> on 2024-11-01.
//

import AppKit

/// agentic-notch: everything TWO windows have to agree on, written down once.
///
/// The kit's panel draws the island; `NotchDropCatcher` (app side) sits above it
/// to catch drags. The AirDrop hit test compares a point in the catcher's
/// coordinates against a box laid out in the panel's, with no screen conversion
/// — so the two windows must occupy the same rectangle, on the same screen, in
/// the same space. That used to be two definitions promising to stay in step.
/// It is now one, and the promise is a call.
public enum DynamicNotchOverlay {
    /// Space membership, carried by BOTH windows.
    ///
    /// `.canJoinAllSpaces` puts them on every ordinary space; `.fullScreenAuxiliary`
    /// is the member that crosses into another app's full-screen space, and
    /// without it the catcher could be present in a full-screen space while the
    /// panel was absent — the hit test's assumption quietly false.
    ///
    /// **The island over full-screen apps is wanted**, and that is what
    /// `.fullScreenAuxiliary` buys. The accepted cost is that it now draws over
    /// full-screen video and presentations as well: it is one window, and the
    /// system offers no "over full-screen apps except the ones you are watching".
    /// Presence is not expansion — the island still only expands on its own when
    /// something needs answering, so what appears over a film is the compact
    /// island, not a pane opening on top of it.
    ///
    /// `.ignoresCycle` keeps both out of ⌘` window cycling, which they have no
    /// business being in; it does not stop the panel becoming key on request.
    public static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    /// The overlay window is half the screen wide.
    ///
    /// Transcribed the other way round in `PanelWidthLimit.hostWindowFraction`
    /// (Core cannot see this module), and `OverlayWindowFrameTests` asserts the
    /// two are the same number.
    public static let widthFraction: CGFloat = 0.5

    /// Pure: screen frame in, overlay window frame out. Centred horizontally,
    /// flush to the top, full screen height.
    public static func windowFrame(inScreenFrame screen: CGRect) -> CGRect {
        let size = CGSize(width: screen.width * widthFraction, height: screen.height)
        return CGRect(
            x: screen.midX - (size.width / 2),
            y: screen.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The same, for a live screen.
    public static func windowFrame(on screen: NSScreen) -> NSRect {
        windowFrame(inScreenFrame: screen.frame)
    }
}

// agentic-notch (LOCAL MODIFICATION, 4 of 4; see THIRD-PARTY-LICENSES.txt):
// `public`, and `canBecomeKey` consults `refusesKeyStatus`. Upstream was an
// internal class hardcoding `true`.
//
// The hardcoded `true` is what defeats every polite way of handing the
// keyboard back. When the key window disappears, AppKit reassigns key status
// by asking each window `canBecomeKey` — an unconditional `true` means this
// panel volunteers every time, `NSPanel.becomesKeyOnlyIfNeeded` never gets a
// vote (it feeds the DEFAULT implementation this override replaces), and the
// host's invisible key-sink hand-off measurably bounced straight back on
// every release. The switch lets the host make the panel ineligible for
// exactly the instant of the hand-back, so the keyboard falls out of the app
// instead of ricocheting. Public because the host reaches the window through
// `NSWindowController` as `NSWindow` and needs the cast.
public final class DynamicNotchPanel: NSPanel {
    /// While true, the panel refuses key status — reassignment skips it and
    /// explicit `makeKey()` is a no-op. Raise it only around a deliberate
    /// hand-back, and drop it before the next `makeKey`.
    public var refusesKeyStatus = false

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        self.hasShadow = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = DynamicNotchOverlay.collectionBehavior
    }

    override public var canBecomeKey: Bool {
        !refusesKeyStatus
    }
}
