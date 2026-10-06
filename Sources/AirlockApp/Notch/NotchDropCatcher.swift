import AppKit
import AirlockCore
import DynamicNotchKit

/// An invisible window sitting exactly over the camera cutout, whose only job
/// is to notice a drag arriving.
///
/// It has to exist separately from the notch panel because of a chicken-and-egg
/// problem: the panel is hidden when nothing is running, so there is no window
/// to drag onto, so the tray can never open — which is precisely the moment you
/// want it (screenshot taken, file in hand, notch closed).
///
/// Sized to the cutout and no larger. That area is the camera housing, so there
/// is nothing behind it a click could have reached, which makes swallowing
/// clicks there harmless — anywhere else it would not be.
@MainActor
final class NotchDropCatcher {
    private var panel: NSPanel?
    private var coverage: Coverage = .cutout
    /// When a drag last said anything. `watchForAbandonment` is the only reader.
    private var lastDragMessage = Date.distantPast
    private var abandonWatch: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private let onEnter: (TrayDropKind) -> Void
    /// The gesture rides along with the drop because it can only be read while
    /// the drag is still alive — see `DropCatcherView.gesture(of:)`.
    private let onDrop: (NSPasteboard, NSPoint, TrayIngestGesture) -> Bool
    /// Every drag move, so the AirDrop box can light up before you let go.
    private let onDragMoved: (NSPoint) -> Void
    /// Fires when the drag resolves either way — dropped, or wandered off. The
    /// caller needs both: a drag that opened the panel and was then abandoned
    /// must not leave it pinned open.
    private let onSettle: () -> Void
    /// This window covers the cutout and therefore swallows the mouse there, so
    /// the panel underneath never sees a pointer arriving from below — only the
    /// island's rounded shoulders, which stick out past the cutout, stayed
    /// hoverable. Owning the region means owning its hover too.
    private let onHover: (Bool) -> Void

    init(onEnter: @escaping (TrayDropKind) -> Void,
         onDrop: @escaping (NSPasteboard, NSPoint, TrayIngestGesture) -> Bool,
         onDragMoved: @escaping (NSPoint) -> Void,
         onSettle: @escaping () -> Void,
         onHover: @escaping (Bool) -> Void) {
        self.onEnter = onEnter
        self.onDrop = onDrop
        self.onDragMoved = onDragMoved
        self.onSettle = onSettle
        self.onHover = onHover
    }

    deinit {
        screenTask?.cancel()
        abandonWatch?.cancel()
    }

    func install() {
        place()
        // An async sequence rather than a block observer: `Task` is Sendable, so
        // it can be cancelled from a nonisolated deinit, and mapping to the name
        // keeps a non-Sendable `Notification` from crossing the boundary.
        screenTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: NSApplication.didChangeScreenParametersNotification)
                .map(\.name)
            for await _ in changes {
                guard let self else { return }
                self.place()
            }
        }
    }

    /// Rebuilt rather than moved on display changes: the notch geometry may
    /// belong to a different screen entirely now.
    private func place() {
        panel?.orderOut(nil)
        panel = nil
        coverage = .cutout // rebuilt at rest, whatever it was covering before

        let screen = NotchScreen.notched
        guard screen.notchMetrics.hasNotch else { return } // nothing to hover over

        let panel = NSPanel(contentRect: Self.restingFrame(on: screen),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false // drag tracking needs hit-testing
        // One step above the notch panel, which now also sits at .statusBar.
        //
        // Both halves of this matter, each learned by breaking it. Too HIGH
        // (.screenSaver and above) and a window stops participating in drag
        // destination resolution altogether — that is why the kit's panel never
        // received a drop, and why parking this above it killed detection
        // outright. Too LOW, level-equal with the panel, and the panel is
        // ordered in front and steals the drag: this window gets a spurious
        // exit, shrinks back to the cutout, and the drop lands on nothing.
        //
        // Between the two, above the panel and below the system's dragging
        // window (~500), it takes every drop and the dragged file still renders
        // on top of everything.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // The kit panel's own behaviour, from the one place it is written down —
        // see `DynamicNotchOverlay.collectionBehavior`. This window grows to that
        // panel's exact frame and the AirDrop hit test assumes the two rectangles
        // coincide, which two windows in different spaces are not. The panel now
        // carries the identical set, `.fullScreenAuxiliary` included, so a
        // full-screen space holds both of them or neither.
        panel.collectionBehavior = DynamicNotchOverlay.collectionBehavior
        panel.contentView = DropCatcherView(
            onEnter: { [weak self] kind in
                // Grow even for a refused drag: the message has to be readable,
                // and the panel it appears on is bigger than the cutout.
                self?.coverPanel()
                self?.onEnter(kind)
            },
            onDrop: onDrop,
            onDragMoved: { [weak self] point in
                self?.lastDragMessage = Date()
                self?.onDragMoved(point)
            },
            onSettle: { [weak self] in
                self?.shrinkToNotch()
                self?.onSettle()
            },
            onHover: onHover
        )
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Only the cutout at rest. This window swallows clicks in its frame, and
    /// the cutout is the one place on screen where that costs nothing — there
    /// is no UI behind the camera housing.
    private static func restingFrame(on screen: NSScreen) -> NSRect {
        let metrics = screen.notchMetrics
        return NSRect(x: screen.frame.midX - metrics.notchWidth / 2,
                      y: screen.frame.maxY - metrics.notchHeight,
                      width: metrics.notchWidth,
                      height: metrics.notchHeight)
    }

    /// The kit's panel frame — not a copy of it, the same function. The AirDrop
    /// hit test relies on the two windows being one rectangle, and a second
    /// transcription of "half the screen wide, full height, top-flush" is
    /// exactly how that stops being true without anyone noticing.
    static func panelFrame(on screen: NSScreen) -> NSRect {
        DynamicNotchOverlay.windowFrame(on: screen)
    }

    /// A drag that STARTS inside the panel — an item dragged off the shelf —
    /// never crosses the cutout, so nothing would wake this window and the
    /// AirDrop box would have nothing listening. Arm it explicitly for the
    /// duration of that drag instead.
    ///
    /// Over the BOX and nothing else. Growing to the whole panel here is what
    /// broke dragging an item out to another app: this window sits above
    /// everything at `.statusBar + 1`, so the centre column of the screen —
    /// half its width, top to bottom — became the drag's destination and
    /// swallowed the drop. The file never reached Finder, `tray.accept` refused
    /// it for already being in the tray, and the gesture read as doing nothing
    /// at all. A destination that declines does NOT hand the drag back to the
    /// window below, so the only fix is not to be there.
    ///
    /// `zone` is the box's frame in the panel's own top-left coordinates, which
    /// is what the SwiftUI side publishes. Nil means the tray has never been
    /// laid out, so there is no box to feed: stay at the cutout rather than
    /// guess.
    func arm(rail zone: CGRect?) {
        guard let panel, let zone else { return }
        coverage = .airDropOnly
        panel.setFrame(Self.railFrame(zone, on: NotchScreen.notched), display: false)
    }

    func disarm() {
        coverage = .cutout
        shrinkToNotch()
    }

    /// The box in screen coordinates. The panel is `panelFrame`, and SwiftUI
    /// measures from its top-left while AppKit measures from the screen's
    /// bottom-left — the same flip `isOverRail` does, in the other
    /// direction.
    static func railFrame(_ zone: CGRect, on screen: NSScreen) -> NSRect {
        let panel = panelFrame(on: screen)
        return NSRect(x: panel.minX + zone.minX,
                      y: panel.maxY - zone.maxY,
                      width: zone.width, height: zone.height)
    }

    /// Grown ONLY while a drag is in flight. Any longer and it would eat clicks
    /// meant for the panel underneath.
    private func coverPanel() {
        guard let panel, coverage != .airDropOnly else { return }
        coverage = .panel
        lastDragMessage = Date()
        panel.setFrame(Self.panelFrame(on: NotchScreen.notched), display: false)
        watchForAbandonment()
    }

    private func shrinkToNotch() {
        guard let panel, coverage != .airDropOnly else { return }
        abandonWatch?.cancel()
        abandonWatch = nil
        coverage = .cutout
        panel.setFrame(Self.restingFrame(on: NotchScreen.notched), display: false)
    }

    /// Shrink when the drag stops talking to us, whatever the reason.
    ///
    /// Grown with no drag holding it there is the state that makes the panel
    /// unusable, and it is worth being precise about why: this window sits
    /// ABOVE the notch at `.statusBar + 1`, and grown it is the panel's exact
    /// rectangle — half the screen wide, its full height. The pointer then
    /// never reaches the panel at all. Rows stop highlighting, the cursor stops
    /// turning into a hand, clicks land on nothing, and hover-out never
    /// registers because the region the pointer left belongs to THIS window and
    /// spans the whole column. It reads exactly like a pane of glass over the
    /// notch, because that is what it is.
    ///
    /// The messages that shrink it are not guaranteed. `draggingEnded` is
    /// documented as unreliable for a destination — the comment on `onDrop` in
    /// `NotchController` was written after it went missing — and a drag the
    /// system cancels can deliver neither it nor `draggingExited`. One missed
    /// message and the notch is glass until the next drag or a display change.
    ///
    /// So don't wait to be told. A live drag over this window sends
    /// `draggingUpdated` on a timer (`wantsPeriodicDraggingUpdates`, true by
    /// default) whether or not the pointer moves, so silence means the drag is
    /// gone. Deliberately NOT the mouse button: with three-finger drag enabled
    /// a drag runs with no button held, and shrinking under one would cancel a
    /// drop the user was in the middle of making.
    private func watchForAbandonment() {
        abandonWatch?.cancel()
        abandonWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, let self, self.coverage == .panel else { return }
                guard Date().timeIntervalSince(self.lastDragMessage) > 1.5 else { continue }
                self.shrinkToNotch()
                // The panel is pinned open for the drag too, so tell the
                // controller as well — a drag that vanished has still ended.
                self.onSettle()
                return
            }
        }
    }
}

/// What the catcher currently covers. `airDropOnly` is sticky: an outbound drag
/// wandering on and off the box must not grow this window back over the panel
/// (`draggingEntered`) or shrink it away from under the box (`draggingExited`).
/// Only `disarm`, when the drag is genuinely over, ends it.
private enum Coverage {
    case cutout
    case panel
    case airDropOnly
}

private final class DropCatcherView: NSView {
    private let onEnter: (TrayDropKind) -> Void
    private let onDrop: (NSPasteboard, NSPoint, TrayIngestGesture) -> Bool
    private let onDragMoved: (NSPoint) -> Void
    private let onSettle: () -> Void
    private let onHover: (Bool) -> Void

    init(onEnter: @escaping (TrayDropKind) -> Void,
         onDrop: @escaping (NSPasteboard, NSPoint, TrayIngestGesture) -> Bool,
         onDragMoved: @escaping (NSPoint) -> Void,
         onSettle: @escaping () -> Void, onHover: @escaping (Bool) -> Void) {
        self.onEnter = onEnter
        self.onDrop = onDrop
        self.onDragMoved = onDragMoved
        self.onSettle = onSettle
        self.onHover = onHover
        super.init(frame: .zero)
        // Deliberately wider than what the tray can actually keep. Registering
        // only `.fileURL` meant a browser image never triggered anything at all
        // — the notch stayed shut and the drag silently fell through, which
        // reads as the app being broken. Catch it, then explain the refusal.
        //
        // Read from Core rather than spelled out here, because the open panel
        // declares the identical set (`TrayPanelDropTarget`) and the two
        // drifting apart is exactly the bug this list already once caused.
        registerForDraggedTypes(TrayDropKind.watchedTypeIdentifiers.map(NSPasteboard.PasteboardType.init(rawValue:)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `.activeAlways` matters: this is an accessory app whose panel never
    /// becomes key, so anything gated on the app being active would never fire.
    /// `.inVisibleRect` keeps the area correct as the window grows and shrinks
    /// around a drag.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Both answer from where the pointer ACTUALLY is, not from the fact of the
    /// message.
    ///
    /// AppKit synthesises enter and exit whenever a tracking area is rebuilt,
    /// and this window rebuilds its own every time it resizes for a drag. The
    /// result was an entry the pointer never made, followed in the same instant
    /// by its matching exit — observed claiming an arrival while the pointer sat
    /// on a different display entirely. The entry armed the hover peek, the exit
    /// was stationary and therefore swallowed as spurious, and 300ms later the
    /// island opened over nothing. That is the notch "randomly opening".
    override func mouseEntered(with event: NSEvent) { onHover(isPointerInside) }
    override func mouseExited(with event: NSEvent) { onHover(isPointerInside) }

    private var isPointerInside: Bool {
        guard let window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let kind = Self.kind(of: sender)
        onEnter(kind)
        // Refusing here gives the "can't drop" cursor, which agrees with the red
        // panel instead of promising something we won't honour.
        return Self.operation(for: sender, kind: kind)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragMoved(sender.draggingLocation)
        return Self.operation(for: sender, kind: Self.kind(of: sender))
    }

    private static func kind(of sender: NSDraggingInfo) -> TrayDropKind {
        TrayDropKind.classify(typeIdentifiers: sender.draggingPasteboard.types?.map(\.rawValue) ?? [])
    }

    /// What the cursor promises, and it has to be what actually happens: a drop
    /// that takes the file while the badge says "+" is a lie the user only
    /// discovers back in Downloads.
    ///
    /// Pixels off a web page are `.copy` whatever the mask says — there is no
    /// original to take, only bytes on a pasteboard.
    private static func operation(for sender: NSDraggingInfo, kind: TrayDropKind) -> NSDragOperation {
        guard kind.isSupported else { return [] }
        guard kind == .files else { return .copy }
        return gesture(of: sender) == .drag(allowsMove: true) ? .move : .copy
    }

    /// Where the Option key is actually read.
    ///
    /// `draggingSourceOperationMask` is modifier-aware by design: AppKit
    /// narrows it to `.copy` while Option is held, so asking the mask asks the
    /// keyboard and the source's own willingness in one question. Both answers
    /// mean the same thing here — copy — and neither is a guess.
    ///
    /// `NSEvent.modifierFlags` is checked alongside it rather than trusted
    /// alone: it is the live keyboard state, which is right for a drag already
    /// in flight, but a source that offers no move at all would still read as
    /// "no Option, therefore move". Requiring both keeps the promise above
    /// honest in either direction.
    ///
    /// The rule itself is `TrayIngestGesture.fromPointerDrag` in Core, shared
    /// with the panel's SwiftUI target. This seam is the one that CAN answer
    /// the mask question; that one passes `nil` and copies. Two seams with a
    /// rule each is how the panel came to badge `.move` over a copy-only
    /// source.
    private static func gesture(of sender: NSDraggingInfo) -> TrayIngestGesture {
        .fromPointerDrag(sourceAllowsMove: sender.draggingSourceOperationMask.contains(.move),
                         optionHeld: NSEvent.modifierFlags.contains(.option))
    }

    /// Both exits matter: `draggingExited` when the drag wanders off, and
    /// `draggingEnded` after any drop. Miss either and this window stays grown
    /// over the panel, eating every click.
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onSettle()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onSettle()
    }

    /// Hands the whole pasteboard over rather than pre-extracting file URLs —
    /// a web image has no file URL to extract, only pixels.
    ///
    /// The gesture goes with it, read here and not later: this is the last
    /// instant at which the drag still exists, and the shelf's file work runs
    /// off the main actor long after the Option key has come up.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop(sender.draggingPasteboard, sender.draggingLocation, Self.gesture(of: sender))
    }
}
