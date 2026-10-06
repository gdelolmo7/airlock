//
//  DynamicNotch.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2023-08-24.
//

import SwiftUI


// MARK: - DynamicNotch

///
/// A customizable, notch-styled window for macOS applications.
///
/// ``DynamicNotch`` is the most flexible way to present custom windows using ``DynamicNotchKit``.
/// It accepts SwiftUI views as input and renders them in a dynamic floating window, and is ideal when full control over the content is required.
///
/// Inspired by Apple’s Dynamic Island, ``DynamicNotch`` introduces a similar interface experience for macOS, with built-in support for *expanded* and *compact* display states.
///
/// ### Expanded State
/// The expanded state is generally the largest view.
/// It shows the full content view below the notch, and is also the view used when the window is floating.
///
/// ### Compact State
/// In the compact state, there is the leading content, which is shown on the left side of the notch, and the trailing content, which is shown on the right side of the notch.
///
/// > When using the `floating` style, this framework does not support compact mode.
/// > Calling ``compact(on:)`` on these devices will automatically hide the window.
///
/// ## Usage
///
/// ```swift
/// Task {
///     let notch = DynamicNotch(style: style) {
///         VStack(spacing: 10) {
///             ForEach(0..<10) { i in
///                 Text("Hello World \(i)")
///             }
///         }
///     } compactLeading: {
///         Image(systemName: "moon.fill")
///             .foregroundStyle(.blue)
///     } compactTrailing: {
///         Image(systemName: "sun.max")
///             .foregroundStyle(.yellow)
///     }
///
///     await notch.expand()
///     try await Task.sleep(for: .seconds(2))
///     await notch.compact()
///     try await Task.sleep(for: .seconds(2))
///     await notch.hide()
/// }
/// ```
/// > There is also a `hoverBehavior` property of type ``DynamicNotchHoverBehavior``, which is available to modify how the window behaves when the user hovers over it.
/// > This can be helpful if you wish to keep the notch open during hover events or add effects such as scaling or haptic feedback.
///
public final class DynamicNotch<Expanded, CompactLeading, CompactTrailing>: ObservableObject, DynamicNotchControllable where Expanded: View, CompactLeading: View, CompactTrailing: View {
    /// Public in case user wants to modify the underlying NSPanel
    public var windowController: NSWindowController?

    /// The window appearance, indicating the style of the notch.
    public let style: DynamicNotchStyle

    /// Behavior of window when mouse enters.
    public let hoverBehavior: DynamicNotchHoverBehavior

    /// Namespace for matched geometry effect. It is automatically generated if `nil` when the notch is first presented.
    @Published public internal(set) var namespace: Namespace.ID?

    /// Configuration for customizing transition animations and behavior.
    public var transitionConfiguration = DynamicNotchTransitionConfiguration()

    /// agentic-notch: what fills the notch shape behind the content. Opaque
    /// black upstream; published so a host can swap it at runtime — set it to
    /// `.clear` and draw your own ground to make translucency possible.
    @Published public var backgroundStyle: AnyShapeStyle = AnyShapeStyle(.black)

    /// agentic-notch (LOCAL MODIFICATION): which screen the kit rebuilds its
    /// window on when nobody hands it one — that is, on a display change.
    ///
    /// Upstream rebuilds on `NSScreen.screens.first`: the PRIMARY display, not
    /// the notched one. Dock an external that happens to be primary and the
    /// panel jumps onto a screen with no cutout to fuse with, and stays there.
    /// The host is the one that knows which screen has the notch, so it answers.
    ///
    /// A closure rather than a stored `NSScreen`, because display
    /// reconfiguration REPLACES the `NSScreen` objects — a cached one would be
    /// the stale instance from before the very change being reacted to. Asking
    /// at the moment of the rebuild is the only reading that can be current.
    ///
    /// Unset, or returning nil, keeps upstream's behaviour: nil means "nowhere
    /// to be", so no window is built.
    ///
    /// The `NSScreen.screens[0]` defaults on `expand(on:)`/`compact(on:)` are
    /// deliberately left alone. A default argument expression cannot see `self`,
    /// so it could not consult this even if it wanted to — and every call from
    /// this app passes the screen explicitly (`NotchScreen.target`), so the
    /// default is reached by nobody here. The rebuild is the path with no
    /// caller to pass anything, which is why it is the one that changed.
    public var screenProvider: (@MainActor () -> NSScreen?)?

    /// agentic-notch (LOCAL MODIFICATION): the kit has just built a new window.
    ///
    /// It builds one in `initializeWindow` — on every expand from hidden, every
    /// screen change, every move between displays — and anything the host set on
    /// the WINDOW rather than on this object goes with the old one. A host that
    /// only re-applies its window settings when its own state changes therefore
    /// loses them on a display change, which changes no state at all. Rather
    /// than have the host guess at when (a sleep, a race), the kit says so.
    public var onWindowChanged: (@MainActor () -> Void)?

    /// LOCAL MODIFICATION (3 of 3 in this vendored kit; see
    /// THIRD-PARTY-LICENSES.txt). Diagnostic only, and unused when nil.
    ///
    /// The island's SHAPE follows its shoulder widths, and those widths live in
    /// `NotchView`'s `@State` where nothing outside can see them. When a
    /// conversion and a content change happen together — a spoken command that
    /// pauses the music does both at once — the width target moves while the
    /// shape is already in flight, and the result is indistinguishable from the
    /// island hiding. Every attempt to diagnose that from outside failed
    /// because the numbers driving it were private.
    ///
    /// Called with (leading, trailing) whenever either is measured.
    public var onCompactGeometry: (@MainActor (CGFloat, CGFloat) -> Void)?

    /// agentic-notch (LOCAL MODIFICATION 5; see THIRD-PARTY-LICENSES.txt): the
    /// cutout to draw the notch style around on a screen that has none.
    ///
    /// Upstream's `.auto` makes a notchless screen `.floating`, and floating
    /// has no compact form — `compact(on:)` hides it. A host that rests compact
    /// therefore showed nothing at all on a plain monitor. A size here makes
    /// that screen present in the notch style around a cutout of that size,
    /// flush with the top edge.
    ///
    /// Asked ONLY for screens without a notch, so a real cutout is never
    /// second-guessed. Unset, or nil for a screen, is upstream's behaviour.
    /// Animations still follow the constructor's `style`, so they are the same
    /// on both kinds of screen.
    public var notchlessCutout: (@MainActor (NSScreen) -> CGSize?)?

    /// Content
    let expandedContent: Expanded
    let compactLeadingContent: CompactLeading
    let compactTrailingContent: CompactTrailing
    @Published var disableCompactLeading: Bool = false
    @Published var disableCompactTrailing: Bool = false

    /// Notch Properties
    // `public` is a LOCAL modification to the vendored kit, and the only one.
    // Re-vendoring must re-apply it — one word. It is here because the host's
    // own presentation log and the screen disagreed for six commits and there
    // was no way to tell which was lying: `applied` is what the controller
    // INTENDED, and this is what actually happened.
    @Published public private(set) var state: DynamicNotchState = .hidden
    @Published private(set) var notchSize: CGSize = .zero
    @Published private(set) var menubarHeight: CGFloat = 0
    @Published public private(set) var isHovering: Bool = false

    private var closePanelTask: Task<(), Never>? // Used to close the panel after hiding completes


    /// Creates a new DynamicNotch with custom content and style.
    /// - Parameters:
    ///   - hoverBehavior: defines the hover behavior of the notch, which allows for different interactions such as haptic feedback, increased shadow etc.
    ///   - style: the popover's style. If unspecified, the style will be automatically set according to the screen (notch or floating).
    ///   - expanded: a SwiftUI View to be shown in the expanded state of the notch.
    ///   - compactLeading: a SwiftUI View to be shown in the compact leading state of the notch.
    ///   - compactTrailing: a SwiftUI View to be shown in the compact trailing state of the notch.
    public init(
        hoverBehavior: DynamicNotchHoverBehavior = .all,
        style: DynamicNotchStyle = .auto,
        @ViewBuilder expanded: @escaping () -> Expanded,
        @ViewBuilder compactLeading: @escaping () -> CompactLeading = { EmptyView() },
        @ViewBuilder compactTrailing: @escaping () -> CompactTrailing = { EmptyView() }
    ) {
        self.hoverBehavior = hoverBehavior
        self.style = style

        self.expandedContent = expanded()
        self.compactLeadingContent = compactLeading()
        self.compactTrailingContent = compactTrailing()

        observeScreenParameters()
    }

    /// Creates a new DynamicNotch with custom content and style. Does not support the compact appearance.
    /// - Parameters:
    ///   - hoverBehavior: defines the hover behavior of the notch, which allows for different interactions such as haptic feedback, increased shadow etc.
    ///   - style: the popover's style. If unspecified, the style will be automatically set according to the screen (notch or floating).
    ///   - expanded: a SwiftUI View to be shown in the expanded state of the notch.
    public convenience init(
        hoverBehavior: DynamicNotchHoverBehavior = [.keepVisible],
        style: DynamicNotchStyle = .auto,
        @ViewBuilder expanded: @escaping () -> Expanded
    ) where CompactLeading == EmptyView, CompactTrailing == EmptyView {
        self.init(
            hoverBehavior: hoverBehavior,
            style: style,
            expanded: expanded,
            compactLeading: { EmptyView() },
            compactTrailing: { EmptyView() }
        )
        self.disableCompactLeading = true
        self.disableCompactTrailing = true
    }

    /// Resolves the effective opening animation (custom override or style default).
    var effectiveOpeningAnimation: Animation { transitionConfiguration.openingAnimation ?? style.openingAnimation }

    /// Resolves the effective closing animation (custom override or style default).
    var effectiveClosingAnimation: Animation { transitionConfiguration.closingAnimation ?? style.closingAnimation }

    /// Resolves the effective conversion animation (custom override or style default).
    var effectiveConversionAnimation: Animation { transitionConfiguration.conversionAnimation ?? style.conversionAnimation }

    /// Observes screen parameters changes and re-initializes the window if necessary.
    private func observeScreenParameters() {
        Task {
            let sequence = NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification)
            for await _ in sequence.map(\.name) {
                // agentic-notch (LOCAL MODIFICATION): ask the host where to
                // rebuild — see `screenProvider`. Upstream was
                // `NSScreen.screens.first`, which is still what happens when no
                // host has answered; a host that answers nil means "nowhere to
                // be", and upstream's own `if let` already covers that.
                let screen = if let screenProvider { screenProvider() } else { NSScreen.screens.first }
                if let screen {
                    initializeWindow(screen: screen)
                }
            }
        }
    }

    /// Updates the hover state of the DynamicNotch, and processes necessary hover behavior.
    /// - Parameter hovering: a boolean indicating whether the mouse is hovering over the notch.
    func updateHoverState(_ hovering: Bool) {
        // Ensure that we only update when the state changes
        guard state != .hidden, hovering != isHovering else { return }

        isHovering = hovering

        if hoverBehavior.contains(.hapticFeedback) {
            let performer = NSHapticFeedbackManager.defaultPerformer
            performer.perform(.alignment, performanceTime: .default)
        }
    }
}

// MARK: - Public

extension DynamicNotch {
    public func expand(on screen: NSScreen = NSScreen.screens[0]) async {
        await _expand(on: screen, skipHide: transitionConfiguration.skipIntermediateHides)
    }

    func _expand(on screen: NSScreen = NSScreen.screens[0], skipHide: Bool) async {
        guard state != .expanded else { return }

        closePanelTask?.cancel()

        let needsNewWindow = state == .hidden || windowController?.window?.screen != screen

        if needsNewWindow {
            // Create window but don't show it yet
            initializeWindow(screen: screen, orderFront: false)

            // Start animation BEFORE showing window - this eliminates stutter
            withAnimation(effectiveOpeningAnimation) {
                self.state = .expanded
            }

            // Now show window with animation already in progress
            showWindow()
        } else {
            // Window exists and we're transitioning from compact state
            Task { @MainActor in
                if !skipHide {
                    withAnimation(effectiveClosingAnimation) {
                        self.state = .hidden
                    }

                    guard self.state == .hidden else { return }

                    try? await Task.sleep(for: .seconds(0.25))
                }

                withAnimation(effectiveConversionAnimation) {
                    self.state = .expanded
                }
            }
        }

        // This is the time it takes for the animation to complete
        // See DynamicNotchStyle's animations
        try? await Task.sleep(for: .seconds(0.4))
    }

    public func compact(on screen: NSScreen = NSScreen.screens[0]) async {
        await _compact(on: screen, skipHide: transitionConfiguration.skipIntermediateHides)
    }

    func _compact(on screen: NSScreen = NSScreen.screens[0], skipHide: Bool) async {
        guard state != .compact else { return }

        if effectiveStyle(for: screen).isFloating {
            await hide()
            return
        }

        if disableCompactLeading, disableCompactTrailing {
            await hide()
            return
        }

        closePanelTask?.cancel()

        let needsNewWindow = state == .hidden || windowController?.window?.screen != screen

        if needsNewWindow {
            // Create window but don't show it yet
            initializeWindow(screen: screen, orderFront: false)

            // Start animation BEFORE showing window - this eliminates stutter
            withAnimation(effectiveOpeningAnimation) {
                self.state = .compact
            }

            // Now show window with animation already in progress
            showWindow()
        } else {
            // Window exists and we're transitioning from expanded state
            Task { @MainActor in
                if !skipHide {
                    withAnimation(effectiveClosingAnimation) {
                        self.state = .hidden
                    }

                    try? await Task.sleep(for: .seconds(0.25))

                    guard self.state == .hidden else { return }
                }

                withAnimation(effectiveConversionAnimation) {
                    self.state = .compact
                }
            }
        }

        // This is the time it takes for the animation to complete
        // See DynamicNotchStyle's animations
        try? await Task.sleep(for: .seconds(0.4))
    }

    public func hide() async {
        await withCheckedContinuation { continuation in
            _hide {
                continuation.resume()
            }
        }
    }

    /// Hides the popup, with a completion handler when the animation is completed.
    func _hide(completion: (() -> ())? = nil) {
        guard state != .hidden else {
            completion?()
            return
        }

        if hoverBehavior.contains(.keepVisible), isHovering {
            Task {
                try? await Task.sleep(for: .seconds(0.1))
                _hide(completion: completion)
            }
            return
        }

        withAnimation(effectiveClosingAnimation) {
            state = .hidden
            isHovering = false
        }

        closePanelTask?.cancel()
        closePanelTask = Task {
            try? await Task.sleep(for: .seconds(0.25)) // Wait for most of animation
            guard Task.isCancelled != true else { return }

            // Fade out window to hide any closing glitches
            await fadeOutWindow()

            guard Task.isCancelled != true else { return }
            deinitializeWindow()
            completion?()
        }
    }

    /// Fades out the window smoothly before closing.
    @MainActor
    private func fadeOutWindow() async {
        guard let window = windowController?.window else { return }

        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: {
                continuation.resume()
            }
        }
    }
}

// MARK: - Window Management

private extension DynamicNotch {
    /// Determines the effective style for a selected screen.
    /// - Parameter screen: the screen to check for a notch.
    /// - Returns: the effective style for the screen.
    func effectiveStyle(for screen: NSScreen) -> DynamicNotchStyle {
        if style == .auto {
            // agentic-notch (LOCAL MODIFICATION 5): a host cutout counts as a
            // notch — see `notchlessCutout`. Upstream: `screen.hasNotch` alone.
            return screen.hasNotch || notchlessCutout?(screen) != nil ? .notch : .floating
        }
        return style
    }

    /// Initializes the window for the DynamicNotch.
    /// - Parameter screen: the screen to initialize the window on.
    /// - Parameter orderFront: whether to order the window front immediately (default: true)
    func initializeWindow(screen: NSScreen, orderFront: Bool = true) {
        // so that we don't have a duplicate window
        deinitializeWindow()

        // agentic-notch (LOCAL MODIFICATION 5): the host's cutout where there is
        // no notch — see `notchlessCutout`. Its height stands in for the menu
        // bar too, so hovering the compact island does not resize it. Upstream
        // is the `else` branch.
        if !screen.hasNotch, let cutout = notchlessCutout?(screen) {
            notchSize = cutout
            menubarHeight = cutout.height
        } else {
            notchSize = screen.notchFrameWithMenubarAsBackup.size
            menubarHeight = screen.menubarHeight
        }

        let style = effectiveStyle(for: screen)
        let view = NSHostingView(rootView: NotchContentView(dynamicNotch: self, style: style))

        let panel = DynamicNotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = view

        // agentic-notch: full screen height, was `height / 2`.
        //
        // The half-screen box hard-cut any content taller than it — no scroll,
        // no warning. I first fixed that by resizing the window to fit its
        // content, which worked and looked awful: a window that changes size
        // mid-transition is a second visible motion on top of the content's own
        // animation, so hiding read as two clunky steps. Upstream never resizes,
        // and that is exactly why its animations are smooth.
        //
        // A window merely LARGER than its content costs nothing — the content is
        // masked to the notch shape and the rest is transparent, which is
        // already true of the half-screen box today. So: size it once, big
        // enough that content never reaches the edge, and never touch it again.
        //
        // The arithmetic itself lives in `DynamicNotchOverlay.windowFrame`
        // because `NotchDropCatcher` has to land on the very same rectangle —
        // the AirDrop hit test compares coordinates across the two windows
        // without converting. One function, so they cannot disagree.
        panel.setFrame(DynamicNotchOverlay.windowFrame(on: screen), display: false)

        panel.layoutIfNeeded()

        if orderFront {
            panel.orderFrontRegardless()
        }

        windowController = .init(window: panel)

        // agentic-notch (LOCAL MODIFICATION): the window the host configured is
        // gone and this is its replacement — see `onWindowChanged`. LAST, after
        // `windowController` is assigned, so the host reaches the new window
        // rather than the one just closed.
        onWindowChanged?()
    }

    /// Shows the window if it exists but hasn't been ordered front yet.
    func showWindow() {
        guard let window = windowController?.window else { return }

        // Start invisible to hide any initial frame glitches
        window.alphaValue = 0
        window.orderFrontRegardless()

        // Fade in smoothly
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// Deinitializes the window and removes it from the screen.
    func deinitializeWindow() {
        guard let windowController else { return }
        windowController.close()
        self.windowController = nil
    }
}
