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
///
/// On a monitor there is no housing, so it sits over the stand-in the island
/// is drawn around instead (`NSScreen.islandMetrics`) — the island's own black
/// centre, which takes no click of its own: tapping the compact island is its
/// shoulders' job. That holds only while the island is drawn, so there it
/// comes and goes with it (`islandShown`).
///
/// While a file the shelf keeps is in hand anywhere on screen it rests wider:
/// a strip along the top, as wide as the panel that opens (`reach`). The
/// cutout alone was too small a target to find mid-drag. Once that file comes
/// close to the top the island becomes a box to drop it in, and this window
/// rests over the box instead (`pocket`).
@MainActor
final class NotchDropCatcher {
    private var panel: NSPanel?
    private var coverage: Coverage = .cutout
    /// Placed over a stand-in rather than a camera housing. Then the window is
    /// only allowed on screen while the island is.
    private var onStandIn = false
    /// What the controller last said — see `islandShown`.
    private var islandVisible = false
    /// A file is in hand: rest on the strip rather than the cutout — see
    /// `reach`.
    private var reaching = false
    /// The island is the drop box: rest over it — see `pocket`. Outranks
    /// `reaching`, which is always true with it.
    private var pocketing = false
    /// The box's size while `pocketing`.
    private var pocketContent = DropPocketLayout(formats: 0, actions: 0).size
    /// When a drag last said anything. `watchForAbandonment` is the only reader.
    private var lastDragMessage = Date.distantPast
    private var abandonWatch: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private let onEnter: (TrayDropKind) -> Void
    /// The gesture rides along with the drop because it can only be read while
    /// the drag is still alive — see `DropCatcherView.gesture(of:)`.
    private let onDrop: (NSPasteboard, NSPoint, TrayIngestGesture) -> Bool
    /// Every drag move, so the AirDrop box and the format chips can light up
    /// before you let go. True when the point is on a format chip, where a drop
    /// makes a copy and the cursor has to say so.
    private let onDragMoved: (NSPoint) -> Bool
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
         onDragMoved: @escaping (NSPoint) -> Bool,
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

    /// Whether the island is drawn right now, from the controller's single
    /// presentation funnel, every pass.
    ///
    /// Over a camera housing this changes nothing: the window stays put even
    /// with the island hidden, because a drag arriving at a closed notch is
    /// the moment it exists for, and the housing is black hardware either way.
    ///
    /// Over a stand-in it decides whether the window is there at all. Hidden
    /// there means a full-screen app has the menu bar, and a window left over
    /// that strip would be a dead patch in the middle of the film — eating
    /// clicks, catching drags meant for the app. So it goes with the island
    /// and comes back with it.
    ///
    /// Every pass rather than on a change, because the stand-in is the menu
    /// bar's height and that moves on its own; the frame follows it here.
    /// Only at rest: a grown window belongs to the drag, and `shrinkToNotch`
    /// puts it back when the drag is done. The strip `reach` rests on counts as
    /// rest, and goes with the island like the stand-in does.
    func islandShown(_ visible: Bool) {
        islandVisible = visible
        guard onStandIn, let panel else { return }
        guard visible else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if coverage.isRest {
            let resting = restFrame(on: NotchScreen.notched)
            if panel.frame != resting { reshape(panel, to: resting) }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// A file the shelf keeps is in hand (`FileInHand`), or no longer: rest on
    /// the strip along the top, or back on the cutout.
    ///
    /// **The menu bar's strip and not a pixel lower.** The pointer is stopped
    /// by the top edge of the screen, so a strip there is as easy to hit as a
    /// target of any height: fling the file upward anywhere above where the
    /// panel would open and it arrives. Below the menu bar would take drops
    /// meant for the windows under it — a browser's tab strip, a Finder
    /// window's toolbar — which is the mistake `arm(rail:)` already records.
    ///
    /// As wide as the panel's column (`panelFrame`), the width this window
    /// grows to the moment the drag enters anyway, so the strip promises
    /// nothing the grown window does not keep. The menu-bar items it covers
    /// cannot be clicked mid-drag in any case; dropping a file ON one of them
    /// is the cost, for the seconds a drag lasts.
    ///
    /// Only ever between the two resting states. A grown window belongs to the
    /// drag that grew it, and `shrinkToNotch` lands it on whichever rest this
    /// says; an armed AirDrop box is the tray's own drag and is left alone.
    func reach(_ armed: Bool) {
        reaching = armed
        rest()
    }

    /// The island is the drop box (`DropPocket`), or no longer: rest over the
    /// box, or back on the strip.
    ///
    /// **The box and a margin round it, and not the strip as well.** The box
    /// hangs well below the menu bar, and a window as wide as the strip and as
    /// tall as the box would take drops meant for the windows either side of
    /// it — the browser tab strip and Finder toolbar `reach` stays clear of.
    /// What catches is what shows.
    ///
    /// A drag arriving here does not grow this window over the panel the way
    /// one arriving on the cutout or the strip does: the box is the target, and
    /// its places light up where they are.
    ///
    /// `content` is the box's size, which depends on what is dragged: the
    /// format chips make it taller.
    func pocket(_ up: Bool, content: CGSize) {
        pocketing = up
        pocketContent = content
        rest()
    }

    /// Where this window is on screen, for turning a drag point in it into
    /// the panel's space (`panelPoint`). Nil before it is placed.
    var frame: NSRect? { panel?.frame }

    /// Re-rest after `reaching` or `pocketing` moved. Only from one resting
    /// state to another: a window grown or shaped for a drag belongs to that
    /// drag, and `shrinkToNotch` lands it on whichever rest is current then.
    private func rest() {
        guard let panel, coverage.isRest else { return }
        coverage = restCoverage
        let resting = restFrame(on: NotchScreen.notched)
        if panel.frame != resting { reshape(panel, to: resting) }
    }

    /// Every move of this window goes through here, so a hover it claimed
    /// before the move is taken back if the pointer is no longer inside.
    private func reshape(_ panel: NSPanel, to frame: NSRect) {
        panel.setFrame(frame, display: false)
        (panel.contentView as? DropCatcherView)?.reshaped()
    }

    private var restCoverage: Coverage {
        pocketing ? .pocket : reaching ? .reach : .cutout
    }

    /// Rebuilt rather than moved on display changes: the notch geometry may
    /// belong to a different screen entirely now.
    private func place() {
        panel?.orderOut(nil)
        panel = nil
        // Rebuilt at rest, whatever it was covering before.
        coverage = restCoverage

        // Wherever the island is — the housing, or a monitor's stand-in.
        // `catching` and `notched` name the same screen whenever the first is
        // non-nil, which is what lets every frame below keep reading `notched`.
        guard let screen = NotchScreen.catching else { return } // no island anywhere
        onStandIn = !screen.notchMetrics.hasNotch

        let panel = NSPanel(contentRect: restFrame(on: screen),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false // drag tracking needs hit-testing
        // Stays when the app is hidden from its Dock icon, as the panel it
        // sits over does.
        panel.canHide = false
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
                guard let self else { return }
                if self.coverage == .pocket {
                    // The box is the target: it lights up where it is.
                    self.coverage = .overPocket
                    self.lastDragMessage = Date()
                    self.watchForAbandonment()
                } else {
                    // Grow even for a refused drag: the message has to be
                    // readable, and the panel it appears on is bigger than the
                    // cutout.
                    self.coverPanel()
                }
                self.onEnter(kind)
            },
            onDrop: onDrop,
            onDragMoved: { [weak self] point in
                self?.lastDragMessage = Date()
                return self?.onDragMoved(point) ?? false
            },
            onSettle: { [weak self] in
                self?.shrinkToNotch()
                self?.onSettle()
            },
            onHover: onHover
        )
        self.panel = panel
        if !onStandIn || islandVisible { panel.orderFrontRegardless() }
    }

    /// Only the cutout at rest. This window swallows clicks in its frame, and
    /// the cutout is the one place on screen where that costs nothing — there
    /// is no UI behind the camera housing, and on a monitor the island's own
    /// centre is drawn over the stand-in.
    private static func restingFrame(on screen: NSScreen) -> NSRect {
        restingFrame(screenFrame: screen.frame, island: screen.islandMetrics)
    }

    /// Where this window rests right now: over the box while the island is
    /// one, the strip while a file is in hand, the cutout otherwise.
    private func restFrame(on screen: NSScreen) -> NSRect {
        switch restCoverage {
        case .pocket: Self.pocketFrame(screenFrame: screen.frame, island: screen.islandMetrics,
                                       content: pocketContent)
        case .reach: Self.reachFrame(on: screen)
        default: Self.restingFrame(on: screen)
        }
    }

    private static func reachFrame(on screen: NSScreen) -> NSRect {
        reachFrame(screenFrame: screen.frame, island: screen.islandMetrics)
    }

    /// The strip `reach` rests on, from numbers a test can construct: the
    /// panel's column, the island's height, flush with the top.
    static func reachFrame(screenFrame: CGRect, island metrics: NotchMetrics) -> NSRect {
        let column = DynamicNotchOverlay.windowFrame(inScreenFrame: screenFrame)
        return NSRect(x: column.minX,
                      y: screenFrame.maxY - metrics.notchHeight,
                      width: column.width,
                      height: metrics.notchHeight)
    }

    /// Room round the box for a drop that grazes its edge.
    static let pocketMargin: CGFloat = 12

    /// The box `pocket` rests over, from numbers a test can construct: the
    /// island at the box's size, centred and top-flush like the island, with
    /// `pocketMargin` at the sides and below.
    ///
    /// The kit's chrome round the box's content, both ways: its ears and side
    /// insets across (`IslandChrome`), and down, the top inset the notch takes
    /// (`NotchMetrics.foreignTopInset`) and the clear space under the content
    /// (`NotchHost.bottomInset`).
    static func pocketFrame(screenFrame: CGRect, island metrics: NotchMetrics,
                            content: CGSize) -> NSRect {
        let width = IslandChrome.islandWidth(panelWidth: content.width) + 2 * pocketMargin
        let height = metrics.foreignTopInset + content.height
            + NotchHost.bottomInset + pocketMargin
        return NSRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height,
                      width: width, height: height)
    }

    /// A drag point in this window, in the panel's top-left space, wherever
    /// this window is. Grown to the panel the two coincide and only y flips;
    /// resting over the box they do not, so the point goes through the screen.
    static func panelPoint(_ pointInWindow: NSPoint, catcher: NSRect, panel: NSRect) -> CGPoint {
        CGPoint(x: catcher.minX + pointInWindow.x - panel.minX,
                y: panel.maxY - (catcher.minY + pointInWindow.y))
    }

    /// The same, from numbers a test can construct.
    static func restingFrame(screenFrame: CGRect, island metrics: NotchMetrics) -> NSRect {
        NSRect(x: screenFrame.midX - metrics.notchWidth / 2,
               y: screenFrame.maxY - metrics.notchHeight,
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
        reshape(panel, to: Self.railFrame(zone, on: NotchScreen.notched))
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

    /// The drop box handed the drag to the full tray: grow over the panel, as a
    /// drag arriving anywhere else would have.
    func cover() {
        coverPanel()
    }

    /// Grown ONLY while a drag is in flight. Any longer and it would eat clicks
    /// meant for the panel underneath.
    private func coverPanel() {
        guard let panel, coverage != .airDropOnly else { return }
        coverage = .panel
        lastDragMessage = Date()
        reshape(panel, to: Self.panelFrame(on: NotchScreen.notched))
        watchForAbandonment()
    }

    /// Back to rest — the box or the strip, if the file is still in hand. A
    /// drag that wanders off the panel is still looking for somewhere to land,
    /// and they are how it finds the way back.
    private func shrinkToNotch() {
        guard let panel, coverage != .airDropOnly else { return }
        abandonWatch?.cancel()
        abandonWatch = nil
        coverage = restCoverage
        reshape(panel, to: restFrame(on: NotchScreen.notched))
    }

    /// Shrink when the drag stops talking to us, whatever the reason. Over the
    /// drop box too: there nothing is glass, but the box would stay lit, and
    /// hand over to the tray, for a drag that is gone.
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
                guard !Task.isCancelled, let self, self.coverage.isDragShaped else { return }
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
///
/// `reach` and `pocket` are the other rests: the strip along the top while a
/// file is in hand, and the drop box once it is near. `overPocket` is the box
/// with a drag on it — the same frame, belonging to that drag until it settles.
private enum Coverage {
    case cutout
    case reach
    case pocket
    case panel
    case overPocket
    case airDropOnly

    var isRest: Bool { self == .cutout || self == .reach || self == .pocket }
    /// Shaped for a drag arriving, so `watchForAbandonment` looks after it.
    var isDragShaped: Bool { self == .panel || self == .overPocket }
}

private final class DropCatcherView: NSView {
    private let onEnter: (TrayDropKind) -> Void
    private let onDrop: (NSPasteboard, NSPoint, TrayIngestGesture) -> Bool
    private let onDragMoved: (NSPoint) -> Bool
    private let onSettle: () -> Void
    private let onHover: (Bool) -> Void

    init(onEnter: @escaping (TrayDropKind) -> Void,
         onDrop: @escaping (NSPasteboard, NSPoint, TrayIngestGesture) -> Bool,
         onDragMoved: @escaping (NSPoint) -> Bool,
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
    override func mouseEntered(with event: NSEvent) { report(isPointerInside) }
    override func mouseExited(with event: NSEvent) { report(isPointerInside) }

    /// What this view last told the controller.
    private var reportedInside = false

    private func report(_ inside: Bool) {
        reportedInside = inside
        onHover(inside)
    }

    /// The window was just reshaped by code. Shrinking away from a pointer
    /// sends no exit, so a claim made over the drop box outlived the box and
    /// the notch stopped peeking (`HoverArbiter.withdrawsAfterReshape`).
    /// Only a withdrawal: a window grown under the pointer stays unreported.
    func reshaped() {
        guard let window, HoverArbiter.withdrawsAfterReshape(
            reported: reportedInside, region: window.frame, pointer: NSEvent.mouseLocation) else { return }
        report(false)
    }

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
        let copiesHere = onDragMoved(sender.draggingLocation)
        let operation = Self.operation(for: sender, kind: Self.kind(of: sender))
        // Over a format chip the picture stays where it is, whatever the shelf
        // would have done with it, so the badge is "+" there and only there.
        return copiesHere && !operation.isEmpty ? .copy : operation
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
