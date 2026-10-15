import Foundation

/// When Airlock shows up as an ordinary app — a Dock icon, a place in ⌘Tab,
/// its own menus in the menu bar, a stage of its own in Stage Manager — and
/// when it goes back to being only the notch.
///
/// At rest Airlock is an accessory app: the notch and the menu-bar icon are
/// the whole of it, and a Dock icon for something with no window would be a
/// button that does nothing. But some of what it opens is a full window — call
/// notes, Settings, the setup guide, buying a licence — and an accessory app's
/// window is one the Mac cannot manage. It is not in ⌘Tab, there is no Dock
/// icon to bring it back, and Stage Manager cannot give it a place of its own,
/// so it sits on top of whichever app was in front and that app stays in front
/// with it. So the app is ordinary for exactly as long as one of those windows
/// is open, minimised included: a minimised window with no Dock icon to click
/// is a window nobody can get back.
///
/// Only full windows count, and only because their owners report them. The
/// notch, the window beside a live call, the drop catcher and the guide's
/// overlays float over other apps on purpose, without becoming the app you
/// are in, which is the one thing an ordinary app's window cannot do.
public enum DockPresence {
    public enum WindowState: Equatable, Sendable {
        case onScreen
        case minimised
        /// Closed, or taken off screen without closing (the welcome window
        /// steps aside this way while its practice runs).
        case closed
    }

    public enum Policy: Equatable, Sendable {
        /// Dock icon, ⌘Tab, menu bar, a stage of its own.
        case regular
        /// The notch and the menu-bar icon only.
        case accessory
    }

    /// One full window, as the app last saw it.
    public struct Tracked<ID: Hashable & Sendable>: Equatable, Sendable {
        public var id: ID
        public var state: WindowState
        /// When the person last had it: shown, brought back, or given the
        /// keyboard. Larger is more recent.
        public var lastUsed: Int

        public init(id: ID, state: WindowState, lastUsed: Int) {
            self.id = id
            self.state = state
            self.lastUsed = lastUsed
        }
    }

    /// Ordinary while any full window is on screen or minimised.
    public static func policy(_ states: some Sequence<WindowState>) -> Policy {
        states.contains { $0 != .closed } ? .regular : .accessory
    }

    /// The window a click on the Dock icon puts in front, or nil to let the
    /// click do what it always does.
    ///
    /// The one the person used last among those on screen, so the keyboard
    /// lands in a window rather than in the notch: the notch panel can take
    /// the keyboard too, and it is the frontmost of Airlock's windows. With
    /// none on screen, the one minimised last, which comes back. Nil when
    /// nothing is open at all, which is also what a second launch from Finder
    /// or Spotlight lands on: with the notch already showing, opening a window
    /// nobody asked for would be a surprise.
    public static func reopenTarget<ID>(_ windows: [Tracked<ID>]) -> ID? {
        func latest(_ state: WindowState) -> ID? {
            windows.filter { $0.state == state }.max { $0.lastUsed < $1.lastUsed }?.id
        }
        return latest(.onScreen) ?? latest(.minimised)
    }

    /// Whether the keyboard should go back to the app the person was in.
    ///
    /// Only on the way back to accessory, and only if Airlock is the active
    /// app at that moment. An accessory app has no menu bar and no Dock icon,
    /// so being left active with nothing on screen is being nowhere: the
    /// keyboard goes to no window and the menu bar belongs to nobody useful.
    /// When the window closed while the person was elsewhere, they are
    /// already where they mean to be.
    public static func handsFocusBack(from old: Policy, to new: Policy, isActive: Bool) -> Bool {
        old == .regular && new == .accessory && isActive
    }

    /// Whether becoming ordinary needs the menu bar handed over again.
    ///
    /// An app that is already the active one when it turns ordinary keeps
    /// the previous app's menus in the menu bar (measured on macOS 26:
    /// activating again changes nothing). Airlock is active with no window
    /// after a second launch from Finder or Spotlight, or after an open or
    /// save panel. When it was not active, activating it after the switch is
    /// enough.
    public static func redrawsMenuBar(from old: Policy, to new: Policy, wasActive: Bool) -> Bool {
        old == .accessory && new == .regular && wasActive
    }
}
