import AppKit
import Combine
import OSLog
import SwiftUI
import DynamicNotchKit
import AirlockCore

/// Transient UI state the compact island renders (owned by NotchController,
/// separate from domain state on purpose).
@MainActor
@Observable
final class NotchUIState {
    /// Green ✓ pulse in the compact island when a session just finished.
    var completionTick = false
    /// The clock the island's two transient rules — the route acknowledgement
    /// and the media retirement — are read against.
    ///
    /// Advanced by `apply()`, which already runs on every state change and is
    /// what the deadline tasks call. Core reads no clock; this is the one handed
    /// to it, and it lives here so a redraw follows from moving it.
    ///
    /// **Never key an `.animation(value:)` or `.onChange(of:)` off this, or off
    /// the input built from it.** Two inputs a millisecond apart are unequal, so
    /// such a key fires on every redraw. Key off the resolved `CompactSlot`.
    var islandNow: Date = .now
    /// Survives collapse, so a manual re-open lands where you left off. An
    /// interrupt overrides it — see `apply()`.
    var selectedTab: NotchTab = .home {
        // Picking another tab is asking for that tab, in full.
        didSet {
            guard selectedTab != oldValue else { return }
            askingYou = false
            tabChanged()
        }
    }
    /// Told after every tab change, so the controller can check the new tab
    /// actually arrived (`FrameWatch`). Set by the controller.
    @ObservationIgnored var tabChanged: () -> Void = {}
    /// Points the panel's content is taller than the room it was given — more
    /// than zero is content cut off at the bottom. Written by `NotchRootView`,
    /// read by `FrameWatch`; never drawn, so it is not observed.
    @ObservationIgnored var panelOverflow: CGFloat = 0
    /// The panel opened because an agent is asking, so it shows the waiting
    /// cards and nothing else from the tab (`PanelStackContent`, the owner's
    /// call 2026-10-01). Set only where a gate brings the panel up — its
    /// arrival and the gate hotkey — and cleared by "Show all", by another
    /// tab, by the panel closing, and by the last question being answered.
    var askingYou = false
    /// A question card's own words field was clicked: the panel takes the
    /// keyboard the way the gate hotkey would, so typing lands here and the
    /// keyboard goes back once the card is answered. Set by the controller.
    @ObservationIgnored var takeKeyboardForAnswer: () -> Void = {}

    /// The panel is being rearranged rather than used.
    ///
    /// Entered from the panel's own top bar rather than from Settings, because
    /// you arrange what you are looking at — a widgets list in another window
    /// is a different tab's worth of abstraction away from the thing being
    /// moved. Cleared on collapse: an arrange mode you left open is a panel
    /// that does nothing when you next open it for a reason.
    var isArranging = false
    /// First-run setup, running *in* the panel rather than in its own window.
    ///
    /// Non-nil IS "the wizard is on screen" — there is no separate flag, so the
    /// hold, the view and the teardown cannot disagree about whether setup is
    /// running. It lives here rather than on `NotchController` because the
    /// panel's views already read this object, and a second observable reached
    /// some other way is how a mode ends up drawn in one tree and not another.
    ///
    /// Cleared by `NotchController.endOnboarding()`, which is also the only
    /// place that settles `hasCompletedSetup` for this route.
    var onboarding: OnboardingModel?
    /// The running guide's compact state, copied from `GuideController` on
    /// every change it reports. Here rather than read from the controller so
    /// the island's one input keeps coming from one place.
    var guideCompact: GuidePresentation.Compact?
    /// A drag is hovering the panel. Driven by the AppKit catcher, because the
    /// SwiftUI drop handler it bypasses is where `isTargeted` would have come
    /// from.
    var isDropTargeted = false
    /// Non-nil when the hovering drag is something the tray can't keep. Drives
    /// the red state and the message, so it doubles as "is this refused".
    var dropRejection: String?
    /// The destinations rail's frame — the WHOLE column, AirDrop and the two
    /// cards under it — in the panel's own top-left coordinates. The catcher
    /// intercepts every drop, so the rail can't use a SwiftUI drop target: it
    /// publishes where it is and lets the catcher route by location.
    ///
    /// One rect for the column rather than one per card. Three publishers into
    /// one preference key collapse to whichever `reduce` saw last, and every
    /// drop would then aim at that one.
    var railFrame: CGRect?
    /// Which destination the drag is currently over, if any. `nil` covers both
    /// "not over the rail" and "in a gap between two cards" — aiming between
    /// Downloads and Trash is not a vote for either.
    var overRailDestination: TrayRailDestination?
    /// An item is being dragged OFF the shelf. The shelf must not light up as a
    /// drop target for its own contents — only the AirDrop box is a destination
    /// during that gesture.
    var isDraggingOut = false
    /// Whether the panel currently holds the keyboard.
    ///
    /// Views bind key equivalents unconditionally — SwiftUI has nowhere else to
    /// put them — but a `.keyboardShortcut` on a panel that is not key never
    /// fires. Anything that *prints* its shortcut has to read this first, or it
    /// advertises a key that does nothing.
    var keyboardHeld = false
    /// The answer just dismissed and the panel is on its way closed. While
    /// this is true the expanded stack keeps rendering the ANSWER — whose text
    /// `AssistantModel.dismiss` now deliberately leaves in place — instead of
    /// swapping to the selected tab's widgets.
    ///
    /// Without it there is a measured ~70ms gap (answer removed at 273.00,
    /// conversion begun at 273.07, in the trace that found it) where the
    /// fully expanded panel mounts the home tab, plus the whole shrink after:
    /// reported as "for a brief second I see the home page" on every spoken
    /// answer. The widgets were never on screen during the answer, so
    /// mounting them for the closing animation is a flash of content nobody
    /// asked for; the answer fading out with the panel is what reads as the
    /// panel closing.
    ///
    /// Set by the answer's dismissal, cleared when the conversion it caused
    /// finishes — or immediately, when no conversion follows, because then
    /// the panel is staying open and the tab genuinely should mount.
    var holdAnswerThroughCollapse = false
    /// The same for dictation: a hold, a notice or one of its cards just
    /// ended and the panel is on its way closed. `DictationOverlayView` keeps
    /// drawing what it last showed instead of the panel mounting the Home tab
    /// for the shrink — reported 2026-10-05 as the notice card "expanding full
    /// size for a micro second, then hiding". Raised and cleared exactly where
    /// `holdAnswerThroughCollapse` is, and dropped the moment dictation starts
    /// again or an answer takes the panel.
    var holdDictationThroughCollapse = false
    /// The kit is animating between presentations. While this is true the
    /// compact slots land content swaps UNANIMATED — see the `.animation` on
    /// `NotchCompactLeadingView` / `NotchCompactTrailingView`.
    ///
    /// A transition that begins inside a subtree the conversion is itself still
    /// inserting can be stranded when the conversion completes: laid out,
    /// reporting a healthy width to `onGeometryChange`, and drawn at opacity 0.
    /// A branch swap in an ANIMATED transaction is such a transition — SwiftUI
    /// gives the incoming branch a default `.opacity` insertion whether or not
    /// anyone wrote `.transition`, which is why deleting the kit's shoulder
    /// transitions did not fix it. A swap in an unanimated transaction gets no
    /// transition at all, and nothing is the one thing that cannot strand.
    ///
    /// Only a spoken media command hits this in practice, because only it
    /// converts the panel AND changes the slots inside the same 0.4s: the
    /// command collapses the panel the instant it executes, and the
    /// now-playing change arrives from the system moments later, mid-flight.
    /// A keyboard media key swaps with no conversion; "go to Chrome" converts
    /// with no swap; each alone is fine, and was.
    var panelConverting = false
}

/// Where the keyboard goes so the panel can stop being key without leaving
/// the screen — see `NotchController.releaseKeyboard` for the two measured
/// failures that make this necessary. 1×1, clear, mouse-ignoring; its whole
/// contribution is being a legal `makeKey` target whose order-out nobody can
/// see.
private final class KeySinkPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Drives the DynamicNotchKit surface from session state.
///
/// THE CONTRACT (user-set): the island expands on its own only when a user
/// action is required to continue — a permission gate the notch can answer,
/// or a question. Completions pulse a ✓ in the compact island, never expand.
///
///   no sessions        → hidden
///   agents working     → compact glyph + count
///   session finishes   → ✓ tick in compact for a few seconds
///   action required    → expanded (edge-triggered; resolving it collapses)
///
/// Gestures — hover is a PEEK, tap is a PIN:
///   hover in  (≥0.3s dwell AND the pointer stopped, so drive-bys to the menu
///   bar don't trigger however slowly they cross) → expand
///   hover out (0.45s grace) → back to compact — unless pinned by tap/attention
///   tap       → pin open (survives hover-out)
///   chevron / menu toggle → collapse, and suppress hover re-expand until the
///   pointer has left once (otherwise collapsing under the cursor would
///   immediately re-peek).
@MainActor
final class NotchController {
    private let model: AppModel
    private let media: MediaWidgetModel
    private let calendar: CalendarWidgetModel
    private let battery: BatteryWidgetModel
    private let system: SystemStatsWidgetModel
    private let tray: TrayModel
    private let clipboard: ClipboardWidgetModel
    private let dictation: DictationModel
    private let assistant: AssistantModel
    private let appearance: NotchAppearanceModel
    private let agents: AgentsWidgetModel
    /// Kept alive here: its listeners hold it weakly.
    private var sounds: Sounds?
    private let audioOutput: AudioOutputModel
    /// Held so `withEveryModel` can hand it to the panel: arrange mode edits the
    /// rail's order, and the rail is the one row whose contents were decided by a
    /// `CaseIterable` rather than by the registry. Also read by `apply()`, for
    /// the one fact the compact island takes from it — whether the Mac is being
    /// held awake.
    private let systemControls: SystemControlsModel
    /// Held only to fold its switch into the compact island's input — see
    /// `AppModel.compactIslandInput`. Reading `WidgetToggle.stored` here instead
    /// would be exactly the invisible-to-`@Observable` trap this model exists to
    /// record.
    private let sound: SoundWidgetModel
    private let appVolume: AppVolumeModel
    private let repository: RepositoryWidgetModel
    private let license: LicenseModel
    #if AIRLOCK_GUIDE
    private let guide = GuideController.shared
    #endif
    /// Held, not just handed to the view: `apply()` asks it which tabs still
    /// exist, so a tab switched off underneath the panel can be escaped from.
    private let registry: WidgetRegistry
    /// The injector the island's trees use, kept for `preview()`.
    private var everyModel: ((AnyView) -> AnyView)?
    /// Set by the app delegate: the controller is built before the settings
    /// window exists, so the gear can't be wired at construction.
    var onOpenSettings: (() -> Void)?
    private let uiState = NotchUIState()
    private var notch: DynamicNotch<AnyView, AnyView, AnyView>?

    /// Pinned open by tap/menu/attention; cleared by collapse or resolution.
    private var stickyExpand = false
    /// Peek while the pointer is on the island; falls back on exit.
    private var hoverExpand = false
    /// Set by an explicit collapse under the cursor; cleared on pointer exit.
    private var hoverSuppressed = false
    /// Opened by the clipboard hotkey. Deliberately NOT `stickyExpand`: a tap
    /// pins the panel until you dismiss it, but a hotkey open is a peek you
    /// happened to summon without the pointer. It holds the panel open only
    /// until the pointer has been on the notch and left again — or until you
    /// pick something, press Escape, or click back into your editor.
    private var hotkeyExpand = false
    /// Held open for the duration of a dictation hold.
    private var dictationExpand = false
    /// Held for the duration of a drag on the media timeline.
    ///
    /// A scrub is one gesture that legitimately leaves the panel: aim at the end
    /// of the bar and the pointer goes past the edge, which arrives as an
    /// ordinary hover-out. `HoverArbiter` cannot filter it — the pointer really
    /// did move, which is the only thing that tells a genuine exit from the view
    /// shrinking — so the 450ms grace fires and the panel collapses out from
    /// under a gesture that is still in progress.
    private var scrubExpand = false
    /// An answer on screen. Unlike `dictationExpand` this is NOT tied to a key
    /// being held — it outlives the gesture, because an unread answer must not
    /// vanish when you let go.
    private var assistantExpand = false
    /// Whether the pointer has actually been on the notch since the hotkey
    /// opened it. Without this the very first hover-*out* event closes the
    /// panel, including a spurious one at open time — which is exactly the
    /// split-second flash: open, then gone.
    private var hoveredSinceHotkey = false

    /// Whether the pointer has actually been on the panel since an answer
    /// appeared. The same edge-triggering `hoveredSinceHotkey` needs, for the
    /// same recorded reason: an out event can arrive without a matching in, and
    /// acting on that alone dismissed the answer the instant it was shown.
    private var hoveredSinceAnswer = false

    /// When the island last had a reason to be up where it cannot rest — a
    /// monitor whose menu bar is hidden. Drives the linger — see
    /// `IslandPresentation.linger`.
    private var lastShown = IslandPresentation.LastShown()
    /// The pointer is at the top edge of a display whose menu bar is hidden —
    /// see `TopEdgeReveal` and `watchTopEdge`.
    private var topEdgeRevealed = false
    /// The app in front has a full-screen window on the island's display —
    /// see `FullScreenFront`, and `refreshFullScreen` for when it is asked.
    private var frontIsFullScreen = false
    private var activationTask: Task<Void, Never>?
    /// The main-thread stall logger, only while the trace is on.
    private var stallTimer: Timer?
    private var lastStallTick = Date()
    /// Mouse-moved monitors, installed only while the island cannot rest, so a
    /// desktop with its menu bar showing costs nothing. Global for the pointer
    /// over other apps, local for it over our own windows. Neither needs a
    /// permission: only KEY events are guarded that way.
    private var topEdgeMonitors: [Any] = []
    /// Last slot description written to the trace, so only changes are logged.
    private var lastLoggedSlots: String?
    private var lingerTask: Task<Void, Never>?
    /// The pending "take the keyboard once you are actually on screen".
    /// Consumed by `transition`, because that is the only place that knows the
    /// expand has finished and which window it finished on.
    private var wantsKeyboard = false
    /// Takes key status so the panel can lose it without leaving the screen —
    /// see `releaseKeyboard`. Built once, on first release.
    private var keySink: KeySinkPanel?
    /// Set when the GATE hotkey took the keyboard, so that resolving the gate
    /// hands it straight back — and so that resolving one does not yank the
    /// keyboard out of the clipboard, which takes it for its own reasons and
    /// gives it back on its own schedule.
    private var gateHoldsKeyboard = false
    private var lastAttention = 0
    /// The card each session is showing, by request id — so a queued gate
    /// taking the card can be told apart from the same card redrawn.
    private var lastCards: [String: String] = [:]
    private var knownSessions: [String: AgentSession] = [:]
    private var applied: IslandPresentation?
    private var transitionChain: Task<Void, Never>?
    /// Clears `panelConverting` a beat after the kit call returns — see
    /// `endConversionGateSoon`.
    private var convertingSettleTask: Task<Void, Never>?
    /// Bumped by every change the island makes, so a frame check that a newer
    /// change overtook stands down instead of judging a picture mid-motion.
    private var frameCheckGeneration = 0
    /// Set while the scripted loop runs: transitions are also watched frame
    /// by frame, which costs frames and is never on otherwise.
    private var watchesEveryFrame = false
    /// Whose turn a tab change is in the frame loop — see `tabChanged`.
    private var tabFramesTurn = false
    /// The panel's height at the last look, the loop's "before" for a tab.
    private var lastShapeHeight: CGFloat?
    private var tickTask: Task<Void, Never>?
    /// The island transients' deadline wakes — see `scheduleIslandDeadlines`.
    private var routeAckTask: Task<Void, Never>?
    private var mediaRetireTask: Task<Void, Never>?
    private var keepAwakeStopTask: Task<Void, Never>?
    private var usageNoticeTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hoverCancellable: AnyCancellable?
    /// Two hover sources, spurious-exit filtering and the anchor, in one tested
    /// place — see `HoverArbiter`.
    private var hover = HoverArbiter()
    private var dropCatcher: NotchDropCatcher?
    private var dragPinTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    /// Space changes, and the re-read a beat after one — see
    /// `observeDisplayChanges`.
    private var spaceTask: Task<Void, Never>?
    private var spaceSettleTask: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?
    /// Watches Reduce Motion — see `observeReduceMotion`.
    private var reduceMotionTask: Task<Void, Never>?
    private var keyStateTask: Task<Void, Never>?
    private var keyResignTask: Task<Void, Never>?
    private var surfaceTask: Task<Void, Never>?
    private var dropCollapseTask: Task<Void, Never>?
    /// Polls the mouse button for the end of a drag OFF the shelf — see
    /// `watchForDragOutEnd` for why an event monitor could not do it.
    /// The rail as it was when the drag began: its frame, and whether the shelf
    /// had anything on it. Routed against rather than live state — see
    /// `pinForDragOut`.
    private var armedRail: (frame: CGRect, hasDestinations: Bool)?
    private var dragOutWatch: Task<Void, Never>?

    init(model: AppModel, media: MediaWidgetModel, calendar: CalendarWidgetModel, battery: BatteryWidgetModel, system: SystemStatsWidgetModel, tray: TrayModel, clipboard: ClipboardWidgetModel, dictation: DictationModel, assistant: AssistantModel, appearance: NotchAppearanceModel, agents: AgentsWidgetModel, audioOutput: AudioOutputModel, sound: SoundWidgetModel, appVolume: AppVolumeModel, systemControls: SystemControlsModel, repository: RepositoryWidgetModel, license: LicenseModel, registry: WidgetRegistry) {
        self.model = model
        self.media = media
        self.calendar = calendar
        self.battery = battery
        self.system = system
        self.tray = tray
        self.clipboard = clipboard
        self.dictation = dictation
        self.assistant = assistant
        self.appearance = appearance
        self.agents = agents
        self.audioOutput = audioOutput
        self.sound = sound
        self.systemControls = systemControls
        self.appVolume = appVolume
        self.repository = repository
        self.license = license
        self.registry = registry
        let pin: () -> Void = { [weak self] in
            self?.stickyExpand = true
            self?.apply()
        }
        let collapse: () -> Void = { [weak self] in
            self?.collapseExplicitly()
        }
        let dragSettled: () -> Void = { [weak self] in
            self?.settleAfterDrag()
        }
        let openSettings: () -> Void = { [weak self] in
            guard let self else { return }
            onOpenSettings?()
            // Settings is another window taking focus, so the notch's job is
            // done — same rule as Reveal in Finder or a terminal jump.
            collapseExplicitly()
        }
        let uiState = self.uiState
        uiState.takeKeyboardForAnswer = { [weak self] in self?.takeKeyboardForAnswer() }
        uiState.tabChanged = { [weak self] in
            guard let self, let applied = self.applied else { return }
            let context = "tab \(self.uiState.selectedTab)"
            self.watchFrame(after: context, presentation: applied, settle: Self.tabSettle)
            guard self.watchesEveryFrame, applied == .expanded else { return }
            // Frames and timing take turns, a tab change each. Looking every
            // frame costs the main thread tens of milliseconds a look, and
            // the fade waits on that same thread, so a tab watched frame by
            // frame starts its fade late BECAUSE it is watched. Its timing is
            // read on the other turn, with one look at the deadline.
            self.tabFramesTurn.toggle()
            guard self.tabFramesTurn else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.tabContentBy * 1e9))
                    guard let self, self.applied == .expanded else { return }
                    let reading = self.readFrame(.expanded)
                    if reading.contentBelowBar == 0 {
                        FrameWatch.report([.lateContent], context: context, reading: reading)
                    }
                }
                return
            }
            // The height before the change, as a first sample: the change
            // has already been made by the time a look can be taken, and
            // a snap is exactly a first look that is already at the end.
            let before = self.lastShapeHeight.map {
                FrameWatch.Sample(time: -0.016, height: $0, hasContent: true)
            }
            Task { @MainActor [weak self] in
                let samples = await FrameWatch.sample(window: { self?.notch?.windowController?.window },
                                                      duration: Self.tabSettle,
                                                      notchSize: Self.notchSize())
                self?.reportFrames((before.map { [$0] } ?? []) + samples, presentation: applied,
                                   context: context, timingElsewhere: true)
            }
        }
        let clipboardModel = clipboard
        let dictationModel = dictation
        let assistantModel = assistant
        let agentsModel = agents
        let outputModel = audioOutput
        let soundModel = sound
        let systemControlsModel = systemControls
        let appVolumeModel = appVolume
        let repositoryModel = repository
        let licenseModel = license
        #if AIRLOCK_GUIDE
        let guideModel = guide
        #endif
        // ONE list, three trees.
        //
        // `soundModel` used to be in both compact lists and neither expanded
        // one. That was harmless for exactly as long as no expanded view read
        // it — then the levels card did, and hovering the notch trapped inside
        // `EnvironmentValues` before anything drew. A missing `.environment`
        // cannot be caught by the compiler and cannot be reached by
        // `swift test`, so the only defence that actually holds is having
        // nowhere left to forget: every tree gets every model.
        //
        // Over-injecting is free. A model a tree never reads costs one
        // dictionary entry and no work, which is a trade worth making against a
        // SIGTRAP on first render.
        func withEveryModel(_ view: some View) -> AnyView {
            let every = view
                .environment(model).environment(media).environment(calendar)
                .environment(battery).environment(system).environment(tray)
                .environment(appearance).environment(uiState)
                .environment(clipboardModel).environment(dictationModel)
                .environment(assistantModel).environment(agentsModel)
                .environment(outputModel).environment(soundModel)
                .environment(appVolumeModel).environment(systemControlsModel)
                .environment(repositoryModel)
                .environment(licenseModel)
            #if AIRLOCK_GUIDE
            return AnyView(every.environment(guideModel))
            #else
            return AnyView(every)
            #endif
        }
        everyModel = { withEveryModel($0) }

        let notch = DynamicNotch(
            // NOT `.all`, and the missing member is `.hapticFeedback` — the tap
            // is performed by `hoverChanged` instead, which is where the pointer
            // actually arrives. Read the block there before adding it back.
            //
            // The short version: the kit's haptic runs in `updateHoverState`,
            // reachable only from SwiftUI `.onHover` on the kit's own panel, and
            // `NotchDropCatcher` sits one window level above that panel covering
            // exactly the cutout. So the kit's tap can only ever fire on the
            // compact island's shoulders, either side of the notch — hovering
            // the notch itself produced nothing at all. An earlier comment here
            // asserted the opposite, which is how the bug survived a revert.
            //
            // The two members that remain have the same hole in the middle of
            // them and are kept anyway, labelled rather than claimed:
            //   `.keepVisible`    holds the panel open under the pointer. Only
            //                     reachable on the shoulders and over the
            //                     EXPANDED panel — which is where it is needed,
            //                     since the expanded panel is the thing you can
            //                     be reading when it decides to hide.
            //   `.increaseShadow` lifts the island's shadow on hover, same
            //                     reachability: live on the shoulders, absent
            //                     over the cutout.
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .auto,
            expanded: {
                withEveryModel(NotchExpandedView(onCollapse: collapse,
                                                 onDragSettled: dragSettled,
                                                 onOpenSettings: openSettings,
                                                 registry: registry))
                    // Scheme is set INSIDE the view now: it follows the chosen
                    // surface, and this closure is built once so it could not.
            },
            // BOTH halves resolve against the SAME input, so both need every
            // model that input reads — even the ones only one side draws. They
            // used to say so as two hand-kept lists; `withEveryModel` is what
            // makes them agree by construction, with the expanded tree included
            // in the same guarantee.
            compactLeading: {
                AnyView(withEveryModel(NotchCompactLeadingView(onTap: pin))
                    .colorScheme(.dark))
            },
            compactTrailing: {
                AnyView(withEveryModel(NotchCompactTrailingView(onTap: pin))
                    .colorScheme(.dark))
            }
        )
        self.notch = notch
        // WHERE THE KIT REBUILDS ITSELF, and what to do when it has.
        //
        // The kit rebuilds its window on every display change, on its own
        // notification observer, with no call from us — so these two hooks are
        // the only say we get. Without the first it rebuilds on
        // `NSScreen.screens.first`, the PRIMARY display rather than the notched
        // one; without the second, everything we set on the WINDOW (its level,
        // its pinned appearance) goes with the window that was thrown away.
        //
        // A closure and not a stored screen: display reconfiguration REPLACES
        // the `NSScreen` objects, so anything cached here is the instance from
        // before the change being reacted to. Asked at the moment of the
        // rebuild, this is the same answer `transition` would compute.
        // The two numbers that drive the island's width, which live in the
        // kit's `@State` and have been invisible to every previous attempt at
        // "why does it look like it hid". Logged with the kit's own state so a
        // width moving DURING a conversion is distinguishable from one moving
        // while the shape is at rest — the first is the suspected fault and the
        // second is what a keyboard pause does harmlessly.
        // `weak self` as well as `weak notch`: this closure is stored ON the
        // notch, which the controller owns, so a strong capture is a cycle.
        notch.onCompactGeometry = { [weak self, weak notch] leading, trailing in
            guard let self, let notch else { return }
            HoverTrace.note(String(format: "widths lead=%.1f trail=%.1f  kit=%@  ",
                                   leading, trailing, String(describing: notch.state))
                            + self.describePanelWindow())
        }
        notch.screenProvider = { NotchScreen.target }
        // A monitor with the lid shut: the island rests around a stand-in
        // cutout instead of the kit going floating, which has no compact form
        // (kit modification 5). Nil on a screen with a real notch.
        notch.notchlessCutout = { $0.standInCutout }
        notch.onWindowChanged = { [weak self, weak notch] in
            self?.adoptRebuiltPanel()
            // The kit rebuilds on a display change even while HIDDEN, and
            // orders the new window front. Over a camera housing that draws
            // black on black; on a monitor it is a black tab over whatever is
            // at the top of the screen. A hidden island has nothing to show and
            // no hover to catch (`updateHoverState` ignores hidden), so it goes
            // back out. `expand`/`compact` order their own window in afterwards.
            if notch?.state == .hidden { notch?.windowController?.window?.orderOut(nil) }
        }
        // THE ONE PLACE the panel's motion is configured, and deliberately so.
        //
        // Converting compact ↔ expanded otherwise goes via `hide` and a 250ms
        // sleep (`DynamicNotch._expand`), so the island blinks out and back —
        // on the single transition whose entire job is to be noticed, because
        // an arriving gate is what causes it. `skipIntermediateHides` converts
        // in place instead.
        //
        // The kit's expand/collapse is the largest automatic motion the product
        // makes and this value is its only override point, so Reduce Motion
        // lands here too — as animation overrides on this same configuration.
        // What that means, and why an overshooting spring under a pointer
        // heading for Approve/Deny is the harm, is in `NotchMotion`.
        //
        // Assigned through `syncPanelMotion()` rather than inline, because the
        // setting can be turned on while the app is running and this must not
        // be the launch-time reading of it.
        syncPanelMotion()

        hoverCancellable = notch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                self?.hoverChanged(.panel, hovering: hovering)
            }

        tray.onChange = { [weak self] in self?.apply() }
        tray.onDragOut = { [weak self] in self?.pinForDragOut() }
        model.onStateChange = { [weak self] in self?.apply() }
        media.onChange = { [weak self] in self?.apply() }
        media.onScrubbingChanged = { [weak self] scrubbing in self?.holdForScrub(scrubbing) }
        calendar.onChange = { [weak self] in self?.apply() }
        battery.onChange = { [weak self] in self?.apply() }
        // The cutoff letting go is a driver: it brings the island up to say so.
        systemControls.onAwakeStoppedByCutoff = { [weak self] in self?.apply() }
        system.onChange = { [weak self] in self?.apply() }
        model.agentsOn = { [weak agents] in agents?.isEnabled ?? false }
        repository.onChange = { [weak self] in self?.apply() }
        // Switching agents off has to re-derive presentation immediately: a
        // running session stops being a reason for the island to be on screen.
        agents.onChange = { [weak self] in self?.apply() }
        // The only model here that had no change callback at all. CoreAudio has
        // nothing further to say after the default device moves, so without this
        // the two-second acknowledgement would wait for something unrelated to
        // redraw the island — usually until after it had already expired.
        audioOutput.onRouteChange = { [weak self] in self?.apply() }
        // A call is a driver: it brings the island up on its own.
        model.calls.onChange = { [weak self] in self?.apply() }
        model.calls.start()

        // Navigation collapses the island: if you're being sent to another app,
        // the notch's job is done. In-place interaction (approve, answer, skip
        // a track) leaves it open — those are controls, not exits.
        let collapseOnNavigation: () -> Void = { [weak self] in self?.collapseExplicitly() }
        model.onNavigateAway = collapseOnNavigation
        media.onNavigateAway = collapseOnNavigation
        calendar.onNavigateAway = collapseOnNavigation
        tray.onNavigateAway = collapseOnNavigation
        clipboard.onNavigateAway = collapseOnNavigation

        // The hotkey is the whole point of a clipboard manager: it has to open
        // the panel from anywhere, already on the right tab and with the search
        // field focused. Pressing it while the panel is open on that tab
        // toggles back, so the same key gets you out.
        clipboard.onHotkey = { [weak self] in self?.toggleClipboard() }

        // The gate's only keyboard route, and deliberately opt-in — see
        // `focusPendingGate`.
        agents.onGateHotkey = { [weak self] in self?.focusPendingGate() }

        // Typing at the notch: the same resolver speech uses, reached without a
        // microphone. Opt-in, because turning it on claims a global chord.
        assistant.onCommandBarHotkey = { [weak self] in self?.toggleCommandBar() }
        assistant.onCommandBarEscaped = { [weak self] in self?.collapseExplicitly() }

        // Dictation has no surface of its own — you hold a key in another app
        // entirely — so the panel IS its indicator. Opening on a gesture the
        // user just made is not the unsolicited kind of expansion the island
        // contract forbids.
        #if AIRLOCK_GUIDE
        guide.onChange = { [weak self] in self?.guideChanged() }
        guide.onStart = { [weak self] in self?.yieldToGuide() }
        #endif
        dictation.onListeningChanged = { [weak self] listening in
            self?.showDictation(listening)
        }

        // An answer keeps the panel open on its own terms, long after the key
        // that produced it came up.
        assistant.onPresentingChanged = { [weak self] presenting in
            self?.showAssistant(presenting)
        }

        // A drag arriving over the cutout opens the tray, even from hidden —
        // otherwise the shelf is unreachable at the one moment you want it.
        dropCatcher = NotchDropCatcher(
            onEnter: { [weak self] kind in self?.revealTrayForDrag(kind) },
            onDrop: { [weak self] pasteboard, point, gesture in
                guard let self else { return false }
                self.logDropRouting(point)
                // AirDrop takes no gesture: sending a file to another device
                // never touches where it came from, whatever the drag offered.
                let accepted: Bool
                switch self.railDestination(at: point) {
                case .airDrop:   accepted = self.tray.airDrop(pasteboard: pasteboard)
                case .downloads: accepted = self.tray.moveToDownloads(pasteboard: pasteboard)
                case .trash:     accepted = self.tray.trashFromShelf(pasteboard: pasteboard)
                case nil:
                    accepted = self.tray.accept(pasteboard: pasteboard, gesture: gesture)
                    Moments.shared.announce(accepted ? .fileDropped : .dropRefused, "on drop")
                }
                self.uiState.selectedTab = .tray
                // Settle HERE rather than leaning on the catcher's onSettle:
                // `draggingEnded` is not reliably delivered to a destination, so
                // the release that was meant to follow the drop never ran and the
                // panel sat pinned until the 15s watchdog. `performDragOperation`
                // always runs, so this is the signal that actually exists.
                self.settleAfterDrag()
                return accepted
            },
            onDragMoved: { [weak self] point in
                guard let self else { return }
                let over = self.railDestination(at: point)
                if over != self.uiState.overRailDestination {
                    self.uiState.overRailDestination = over
                }
            },
            onSettle: { [weak self] in self?.settleAfterDrag() },
            onHover: { [weak self] hovering in
                self?.hoverChanged(.catcher, hovering: hovering)
            }
        )
        dropCatcher?.install()
        observeDisplayChanges()
        observeReduceMotion()
        listenToMoments()

        apply()
    }

    /// The reactions behind `Moments` (card A3): the four sounds behind
    /// Settings › General › Sounds (card D2, `Sounds`), and every trackpad
    /// tick, the hover tick among them (card D3, `Ticks`). Where they fire —
    /// and every guard on that — stays at the call sites.
    ///
    /// The gate's Needs you is the audible half of a gate arriving, for people
    /// the VoiceOver announcement cannot reach. Same edge as `announceGate`:
    /// once per ARRIVING gate, never on a re-render, and never at launch for
    /// restored sessions, because `SessionState.preparedForRestore` clears
    /// pending gates before the state is adopted.
    private func listenToMoments() {
        let agents = agents
        sounds = Sounds(needsYouChoice: { agents.gateSoundName })
        Ticks.listen()
    }

    /// Push the current Reduce Motion setting into the kit's transition
    /// configuration. Idempotent, and safe at any time: the kit resolves
    /// `transitionConfiguration` at the moment it starts a transition
    /// (`effectiveOpeningAnimation` and friends), so a later write simply
    /// applies from the next expand onward.
    ///
    /// `growing` picks the conversion: Open into the panel, Close back to the
    /// compact island. Set again just before each transition, since the kit
    /// has one conversion animation for both directions.
    private func syncPanelMotion(growing: Bool = true) {
        notch?.transitionConfiguration = NotchMotion.transitionConfiguration(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            growing: growing
        )
    }

    /// Reduce Motion is a system switch someone flips *because* something on
    /// screen is already hurting, so honouring it only at launch is honouring
    /// it too late — and relaunching Airlock to make an accessibility setting
    /// take effect is exactly the friction the setting exists to remove.
    ///
    /// Read via `NSWorkspace` rather than SwiftUI's
    /// `@Environment(\.accessibilityReduceMotion)`, which is how every drawn
    /// animation in the app reads it: this value is consumed by an AppKit-level
    /// object with no view to read an environment from, and — worse — the
    /// panel's SwiftUI content does not exist while the notch is hidden, which
    /// is precisely the state the OPENING animation is configured for. The
    /// notification is posted on `NSWorkspace`'s own centre, not the default one.
    private func observeReduceMotion() {
        reduceMotionTask = Task { [weak self] in
            let changes = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                .map(\.name)
            for await _ in changes {
                guard let self else { return }
                self.syncPanelMotion()
            }
        }
    }

    /// A display arrived, left or was rearranged.
    ///
    /// WHERE the panel goes is no longer decided here. The kit rebuilds its own
    /// window on this same notification and now asks `screenProvider` which
    /// screen — so it lands on the notched one first time, and the catcher,
    /// rebuilding itself on the same notification via `place()`, lands on that
    /// same screen because both resolve through `NotchScreenChoice`. Their two
    /// rectangles are compared without conversion for the AirDrop hit test, and
    /// that is only sound while the screen is the same one.
    ///
    /// This used to drag the panel back afterwards, on a 400ms sleep chosen to
    /// land after the kit's own observer — a race by construction, and two
    /// mechanisms disagreeing about where the panel belongs. What is left here
    /// is only what the kit cannot know: the hover visit that ended when both
    /// windows were torn down under the pointer, and the presentation, which a
    /// display change can genuinely alter (shut the lid and there may be no
    /// screen to be on at all).
    private func observeDisplayChanges() {
        displayTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: NSApplication.didChangeScreenParametersNotification)
                .map(\.name)
            for await _ in changes {
                guard let self else { return }
                // BOTH hover sources are rebuilt on this notification — the kit's
                // panel by its own observer, the catcher by `place()` — so any
                // visit in flight ends here with no exit event to end it. See
                // `forgetHover`.
                self.forgetHover()
                // Recomputed rather than reasserted: `forgetHover` may have
                // dropped the peek that was holding the panel open, and the
                // notched screen may have just arrived or gone.
                self.apply()
            }
        }
        // A menu bar hiding or coming back — a full-screen app in front or
        // gone — posts no display change, only a space change, and whether the
        // island may rest depends on exactly that (`islandCanRest`). Read
        // again a beat later in case the screen's `visibleFrame` lags the
        // notification. On every display: since 2026-10-04 the notch hides in
        // full screen too.
        spaceTask = Task { [weak self] in
            let changes = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.activeSpaceDidChangeNotification)
                .map(\.name)
            for await _ in changes {
                guard let self else { return }
                refreshFullScreen()
                apply()
                spaceSettleTask?.cancel()
                spaceSettleTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.refreshFullScreen()
                    self?.apply()
                }
            }
        }
        // Switching to another app inside the same space can end or start a
        // full-screen front without a space change: a second display, or the
        // app's own windows. Cheap: one Accessibility read per switch.
        activationTask = Task { [weak self] in
            let changes = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didActivateApplicationNotification)
                .map(\.name)
            for await _ in changes {
                guard let self else { return }
                refreshFullScreen()
            }
        }
        refreshFullScreen()
        watchMainThreadStalls()
        surfaceTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: .notchSurfaceDidChange)
                .map(\.name)
            for await _ in changes {
                guard let self else { return }
                applyGround()
            }
        }
        policyTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: .notchDisplayPolicyDidChange)
                .map(\.name)
            for await _ in changes {
                guard let self else { return }
                // Turning it on with the lid shut should show the panel now, and
                // turning it off should take it away now.
                apply()
            }
        }
        // Observed rather than set alongside `makeKey()`/`releaseKeyboard()`,
        // because the panel also loses the keyboard for reasons we never hear
        // about — clicking into another app, ⌘-tab. A flag we only wrote
        // ourselves would go on claiming the keys still work.
        keyStateTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: NSWindow.didBecomeKeyNotification)
                .map { _ in () }
            for await _ in changes {
                guard let self else { return }
                syncKeyboardHeld()
            }
        }
        keyResignTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: NSWindow.didResignKeyNotification)
                .map { _ in () }
            for await _ in changes {
                guard let self else { return }
                syncKeyboardHeld()
            }
        }
    }

    /// Both notifications are app-wide, so ask our own window rather than trust
    /// whichever window sent it — Settings and onboarding are windows too.
    private func syncKeyboardHeld() {
        uiState.keyboardHeld = notch?.windowController?.window?.isKeyWindow ?? false
    }

    /// Speak a gate that has just arrived.
    ///
    /// Expanding the island is the whole notification for someone watching it,
    /// and nothing at all for someone who is not. `announcementRequested` is a
    /// no-op unless VoiceOver is running, so this costs nothing for everyone
    /// else — no sound, no banner, no permission.
    ///
    /// Edge-triggered by the caller, so it speaks once per arriving gate rather
    /// than on every `apply()`. Fires whatever the agents switch says, for the
    /// same reason the hotkey registers regardless: a blocking gate outranks it.
    private func announceGate(sessionID: String? = nil) {
        // The session that is actually blocked: the card the keyboard answers
        // — the one at the top, named once in `SessionState.focusedGate` — or,
        // when a queued gate has just taken a card, the session it took.
        let named = sessionID ?? model.focusedGate?.sessionID
        guard let session = model.sessions.first(where: { $0.id == named }),
              let request = session.pendingPermission else { return }

        let text = GateAnnouncement.text(
            agent: session.agent.displayName,
            request: request,
            risk: RiskAssessor.assess(request),
            hotkey: agents.hotkeyEnabled ? agents.hotkey.spokenName : nil
        )

        // Posted from the panel rather than Apple's `NSApp.mainWindow`, which is
        // nil in an `LSUIElement` app — the panel is where the card is, and an
        // announcement attributed to nothing is dropped.
        let element: Any = notch?.windowController?.window ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                // High, not medium: the agent is stopped until this is answered.
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Everything we set on the WINDOW rather than on the notch object, applied
    /// to the window the kit has just built.
    ///
    /// The kit builds a fresh `NSPanel` in `initializeWindow` — on every expand
    /// from hidden and on every display change — so none of this survives on its
    /// own. `transition` calls it because it just caused one; `onWindowChanged`
    /// calls it for the rebuilds nobody here asked for, which change no state
    /// and would otherwise leave the panel at the kit's own `.screenSaver` with
    /// the system's appearance.
    private func adoptRebuiltPanel(for presentation: IslandPresentation? = nil) {
        // The kit parks its panel at .screenSaver, which is ABOVE the system's
        // dragging window — so a file dragged at the notch renders behind the
        // panel. .statusBar still clears the menu bar but sits under the drag
        // image.
        notch?.windowController?.window?.level = .statusBar
        // NOT `becomesKeyOnlyIfNeeded` — that was tried against the sink
        // bounce and measurably changed nothing, because it feeds NSPanel's
        // DEFAULT `canBecomeKey`, which the kit's panel overrides outright.
        // The eligibility switch lives on `DynamicNotchPanel.refusesKeyStatus`
        // (local modification 4), raised only inside `releaseKeyboard`.
        pinPanelAppearance(for: presentation)
        // The old window may have been key, and the new one is not. Nothing
        // posts a resign for a window that was closed rather than deactivated,
        // so ask instead of waiting to be told — the shortcuts a card prints
        // depend on this being true.
        syncKeyboardHeld()
    }

    /// Pinned open rather than peeked: a drag is a deliberate act, and the
    /// panel collapsing mid-drag would drop the file into nothing.
    /// Opens for ANY drag, supported or not. A refusal you can read beats a
    /// notch that ignores you — the person dragging a web image believes they
    /// are dragging an image.
    private func revealTrayForDrag(_ kind: TrayDropKind = .files) {
        uiState.selectedTab = .tray
        // Dragging an item off the shelf immediately re-enters the armed catcher;
        // highlighting the shelf as a destination for its own contents would be
        // nonsense.
        uiState.isDropTargeted = !uiState.isDraggingOut
        uiState.dropRejection = kind.isSupported ? nil : kind.explanation
        if !uiState.isDraggingOut { Moments.shared.announce(kind.isSupported ? .fileOver : .dropRefused, "over the notch") }
        hoverSuppressed = false
        pinForDrag()
    }

    /// Dragging an item OUT means moving the pointer off the panel, which is
    /// the same gesture that collapses it — the panel would vanish from under
    /// the drag. Pin it, and let mouse-up release.
    private func pinForDragOut() {
        uiState.isDraggingOut = true
        // SNAPSHOT the rail, and route the whole drag against this rather than
        // against live state. The armed window's frame is set once, and the shelf
        // reflows mid-drag whenever the folder watcher fires — so a live rect
        // against a frozen window is how a drop aimed at AirDrop resolves to
        // Trash. It also fixes the destinations for the gesture: a tile leaving
        // the shelf mid-flight cannot empty it out from under its own drag.
        armedRail = uiState.railFrame.map { (frame: $0, hasDestinations: !tray.isEmpty) }
        // Only the rail listens during this gesture. Everywhere else the drag
        // has to be free to land in another app — see `arm`.
        dropCatcher?.arm(rail: uiState.railFrame)
        pinForDrag()
        watchForDragOutEnd()
    }

    /// A drag that started here ends when the button comes up, and there is no
    /// callback that says so: SwiftUI's `.onDrag` hands over an item provider
    /// and stops talking. A GLOBAL event monitor was the first answer and is the
    /// wrong one — it is explicitly not shown our own application's events, so
    /// it fired when the drop landed in another app and stayed silent when it
    /// landed on us. The gesture that failed was exactly the gesture that left
    /// `isDraggingOut` stuck on, and with it the shelf refusing to light up for
    /// the rest of the session.
    ///
    /// The button itself is readable from anywhere, drag session or not.
    private func watchForDragOutEnd() {
        dragOutWatch?.cancel()
        dragOutWatch = Task { [weak self] in
            // Same 15s ceiling as the pin watchdog: a drag that never ends is a
            // bug elsewhere, and the panel must not stay pinned waiting for it.
            for _ in 0 ..< 150 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                guard NSEvent.pressedMouseButtons & 1 != 0 else { break }
            }
            guard !Task.isCancelled else { return }
            self?.dragOutFinished()
        }
    }

    private func dragOutFinished() {
        endDragOut()
        // Only now can this do its job — it stands down while a drag-out is in
        // flight, which is the whole point of the guard at the top of it.
        settleAfterDrag()
    }

    /// Everything `pinForDragOut` turned on, undone exactly once. Reached from
    /// the button watch and from every drag-settling path, because a flag that
    /// only one of them clears is a flag that gets stuck.
    private func endDragOut() {
        guard uiState.isDraggingOut else { return }
        dragOutWatch?.cancel()
        dragOutWatch = nil
        uiState.isDraggingOut = false
        armedRail = nil
        dropCatcher?.disarm()
    }

    private func pinForDrag() {
        stickyExpand = true
        apply()
        // A cancelled drag never reports back — without this the panel would
        // stay pinned open forever because nobody released the pin.
        dragPinTask?.cancel()
        dragPinTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.releaseDragPin()
            self?.apply()
        }
    }

    /// Where a drop the catcher received should go.
    ///
    /// While an item is on its way OFF the shelf the catcher covers the AirDrop
    /// box and nothing else, so anything it receives is on the box by
    /// construction — and the point it reports is then in a window that is no
    /// longer the panel's rectangle, which is the one assumption the hit test
    /// below rests on.
    /// Which destination a drop at this point lands on, or nil for "the shelf".
    ///
    /// Two coordinate spaces, because there are two windows. OUTBOUND, the armed
    /// window IS the rail, so the point is already rail-local and only needs the
    /// AppKit-to-SwiftUI y-flip — against the SNAPSHOT's height, not the live
    /// one. INBOUND, the catcher is grown to the panel, so the point flips
    /// against the screen exactly as `isOverRail` does, and is then compared
    /// against the published rail rect.
    ///
    /// The old `isDraggingOut ||` short-circuit is gone with it. It existed
    /// precisely because the armed window is a different space and a Bool answer
    /// did not have to care which part of the box it landed on. Three sub-targets
    /// care.
    private func railDestination(at pointInWindow: NSPoint) -> TrayRailDestination? {
        if uiState.isDraggingOut {
            guard let armed = armedRail else { return nil }
            let local = CGPoint(x: pointInWindow.x, y: armed.frame.height - pointInWindow.y)
            return TrayRailLayout.destination(atRailLocal: local,
                                              size: armed.frame.size,
                                              hasDestinations: armed.hasDestinations)
        }
        // INBOUND: the AirDrop hero and nothing else. Downloads and Trash act on
        // files the shelf owns, so keeping them unreachable from outside is a
        // structural guarantee rather than a guarded one — a file the shelf never
        // held cannot be moved or recycled by dropping it on the notch.
        guard let rail = uiState.railFrame, let screen = NotchScreen.catching else { return nil }
        let panelPoint = CGPoint(x: pointInWindow.x, y: screen.frame.height - pointInWindow.y)
        let hit = TrayRailLayout.destination(atPanelPoint: panelPoint, rail: rail,
                                             hasDestinations: !tray.isEmpty)
        return hit?.acceptsInbound == true ? hit : nil
    }

    /// The catcher, when grown to the panel, occupies exactly the same frame as
    /// the kit's — half the screen wide, full height, centred and top-flush.
    /// That means a drag point in catcher-window coordinates needs no screen
    /// conversion to compare against the panel's own layout; only the y-flip,
    /// since AppKit measures from the bottom and SwiftUI from the top.
    ///
    /// The height that performs the flip is the CATCHER's screen, because the
    /// point arrived in the catcher's window — and there can be no such point
    /// without a catcher, which is why this is `catching` and not `notched`
    /// with its fallbacks. After a display change the kit's panel is on that
    /// same screen (`screenProvider` → `NotchScreen.target`), so the two
    /// rectangles still coincide; `NotchScreenChoiceTests` is what holds that.
    private func isOverRail(_ pointInWindow: NSPoint) -> Bool {
        guard let zone = uiState.railFrame, let screen = NotchScreen.catching else { return false }
        let height = screen.frame.height
        let flipped = NSRect(x: zone.minX, y: height - zone.maxY,
                             width: zone.width, height: zone.height)
        return flipped.contains(pointInWindow)
    }

    /// Enough to tell a bad y-flip from a zone that was never published: if the
    /// zone is nil the frame never reached us, and if it's present but the point
    /// falls outside, the conversion is wrong.
    private func logDropRouting(_ point: NSPoint) {
        guard NotchGeometryProbe.isEnabled else { return }
        let zone = uiState.railFrame.map { "\($0)" } ?? "nil"
        // The same screen and the same height `isOverAirDropZone` flips against,
        // or the probe would agree with a conversion nobody performs. It printed
        // half this number until the window became full-height and the log did
        // not follow.
        let line = "drop at \(point) | railFrame(swiftui) = \(zone) "
            + "| windowHeight = \(NotchScreen.catching?.frame.height ?? 0) "
            + "| routed = \(railDestination(at: point)?.rawValue ?? "tray")\n"
        Log.notch.debug("\(line, privacy: .public)")
    }

    private func releaseDragPin() {
        dragPinTask?.cancel()
        dragPinTask = nil
        stickyExpand = false
        uiState.isDropTargeted = false
        // Belt and braces for the 15s watchdog above, which is the one caller
        // that can arrive here with a drag-out still nominally in flight.
        // Nothing this gesture turned on may outlive the pin it took.
        endDragOut()
    }

    /// A drag ended — dropped or abandoned. Handing this to the hover-out grace
    /// does NOT work: macOS suppresses mouse-moved events for the duration of a
    /// drag, so neither hover source ever changed and the collapse had nothing
    /// to fire it. The panel just sat there.
    ///
    /// So collapse on a timer instead, long enough to watch the item land, and
    /// stand down if the pointer turns out to be on the panel after all.
    private func settleAfterDrag() {
        // An outbound drag is NOT settled by the pointer leaving the AirDrop
        // box — it is still in flight, on its way to another app, and the panel
        // collapsing now would take the shelf away mid-gesture. That one ends
        // when the button comes up, and `dragOutFinished` owns it.
        guard !uiState.isDraggingOut else {
            uiState.overRailDestination = nil
            return
        }
        releaseDragPin()
        uiState.dropRejection = nil
        uiState.overRailDestination = nil
        dropCollapseTask?.cancel()
        dropCollapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            // Unconditional. Standing down while the pointer happened to rest on
            // the panel is what left it open after a drop — and hover will bring
            // it straight back if you actually reach for the item.
            hoverExpand = false
            stickyExpand = false
            apply()
        }
    }

    func toggle() {
        if applied == .expanded {
            collapseExplicitly()
        } else {
            stickyExpand = true
            apply()
        }
    }

    /// Open it, and leave it open. Distinct from `toggle()` because the caller —
    /// onboarding's "show me the notch" — means *show*, and a toggle would
    /// close the panel for anyone who had already found it.
    func reveal() {
        stickyExpand = true
        apply()
    }

    // MARK: - In-panel setup

    /// Run first-run setup inside the panel.
    ///
    /// The panel is pinned for the duration by `Holds.onboarding` rather than by
    /// `stickyExpand`, and the difference matters: a sticky pin is released by
    /// the next thing that collapses the panel, while this one is released only
    /// by finishing, skipping, or an explicit collapse — all three of which run
    /// through `endOnboarding`.
    ///
    /// `onClose` is rebound here because the same `OnboardingModel` is shared
    /// with the window controller, which points it at `window.close()`. Whoever
    /// presented it last owns the teardown.
    func beginOnboarding(_ onboarding: OnboardingModel) {
        onboarding.onClose = { [weak self] in self?.endOnboarding() }
        onboarding.settings.refresh()
        uiState.onboarding = onboarding
        // Home, because the wizard replaces the stack and the tab strip above it
        // stays live — landing on a tab the user never chose would make the
        // first thing they see after finishing a surprise.
        uiState.selectedTab = .home
        apply()
    }

    /// Take setup off the panel and settle the flag.
    ///
    /// Idempotent: `collapseExplicitly` calls it unconditionally, and
    /// `OnboardingModel.finish` routes back into it through `onClose`, so it has
    /// to be safe to arrive here twice for the same wizard.
    func endOnboarding() {
        guard uiState.onboarding != nil else { return }
        uiState.onboarding = nil
        // Every route out of the wizard is a finished setup — the same rule
        // `OnboardingWindowController.windowWillClose` applies to the window.
        // Without it, skipping means being asked again next launch.
        OnboardingModel.hasCompletedSetup = true
        apply()
    }

    /// What the clipboard hotkey does. Pressing it lands you on the clipboard
    /// tab from anywhere, including from hidden; pressing it again while you are
    /// already there closes up, so one key is both the way in and the way out.
    /// Arriving from another tab switches rather than closing — otherwise the
    /// shortcut would appear to do nothing whenever the panel happened to be
    /// open on Home.
    func toggleClipboard() {
        if applied == .expanded && uiState.selectedTab == .clipboard {
            collapseExplicitly()
            return
        }
        // Read BEFORE `apply`, which sets `applied` synchronously: afterwards a
        // panel that was already open and one that just opened look identical,
        // and only the second has a transition to hand the keyboard to.
        let wasExpanded = applied == .expanded
        uiState.selectedTab = .clipboard
        hoverSuppressed = false
        hotkeyExpand = true
        hoveredSinceHotkey = false
        wantsKeyboard = true
        apply()
        // `apply` only transitions when the presentation actually changes, so an
        // already-expanded panel gets no transition to hang this off — hence the
        // direct call. Taking the keyboard here means disarming it here too:
        // `transition` is the only other place that clears `wantsKeyboard`, and
        // left set it would fire on some later, unrelated expand — a peek, an
        // arriving gate, dictation — and take the keyboard nobody asked for.
        //
        // Deliberately NOT the freshly-expanded case: that one is mid-transition,
        // and from hidden the kit builds a whole new panel, so focusing now would
        // be focusing a window about to be thrown away. The flag is what survives
        // to the far side of that.
        if wasExpanded, applied == .expanded {
            wantsKeyboard = false
            focusForTyping()
        }
    }

    /// The island closed and open, as Settings' live picture (card
    /// Settings 2), with the same models the island itself is given.
    func preview() -> AnyView {
        everyModel?(AnyView(IslandPreview(registry: registry))) ?? AnyView(EmptyView())
    }

    /// Summon the typed command bar, or put it away if it is already up.
    ///
    /// The same shape as `toggleClipboard`, and for the same reason — read the
    /// long note there about why `wasExpanded` is sampled BEFORE `apply()` and
    /// why only the already-expanded case focuses directly. A bar that opened
    /// without the keyboard would be a text field you have to click, summoned by
    /// a shortcut you pressed to avoid reaching for the mouse.
    ///
    /// Unlike the clipboard this changes no tab: the bar is summoned rather than
    /// found, so it renders over whichever tab you were on.
    func toggleCommandBar() {
        // Traced because the one report this could not explain — "I pressed it
        // and the notch was not there" — is indistinguishable from three
        // different causes: the chord never reached us, it reached us and we
        // declined, or we opened something that was then not drawn. The trace
        // tells them apart; `apply` alone cannot, because a decline logs nothing.
        HoverTrace.note("commandBar hotkey fired  enabled=\(assistant.commandBarEnabled)"
            + " applied=\(applied.map(String.init(describing:)) ?? "none")"
            + " barOpen=\(assistant.isCommandBarOpen) presenting=\(assistant.isPresenting)")
        guard assistant.commandBarEnabled else {
            HoverTrace.note("commandBar declined — switched off")
            return
        }
        // FIRST, before anything else looks at the panel. The chord's own
        // modifier may have started a push-to-talk hold on the way down — see
        // `DictationModel.abandonHoldForChord`. Left running it would deliver an
        // empty transcript on top of the bar we are about to open.
        dictation.abandonHoldForChord()
        if applied == .expanded, assistant.isCommandBarOpen {
            assistant.closeCommandBar()
            collapseExplicitly()
            return
        }
        let wasExpanded = applied == .expanded
        assistant.openCommandBar()
        hoverSuppressed = false
        hotkeyExpand = true
        hoveredSinceHotkey = false
        wantsKeyboard = true
        apply()
        if wasExpanded, applied == .expanded {
            wantsKeyboard = false
            focusForTyping()
        }
    }

    /// Hand the panel the keyboard so the pending gate can be answered.
    ///
    /// THE REASON THIS IS A HOTKEY AND NOT AUTOMATIC. Every other place that
    /// takes the keyboard does so because the user just pressed something — the
    /// clipboard hotkey, invoking the assistant. A gate is the opposite: it
    /// arrives because an agent hit a permission check, at whatever moment that
    /// happens, which is usually mid-sentence somewhere else. Taking the
    /// keyboard then would not merely swallow keystrokes; the card binds ⌘Y, ⌘N,
    /// Escape and ⌘1–9, so a stray ⌘N meant for your editor would *deny* a
    /// request you had not read. On a surface whose whole job is asking before
    /// something risky runs, an accidental answer is worse than no answer.
    ///
    /// So the panel never grabs focus on its own. Press the key and it becomes
    /// answerable — and only from that moment does the card print its shortcuts.
    func focusPendingGate() {
        // TOGGLE FIRST, and unconditionally — gate pending or not.
        //
        // The previous version only toggled when nothing was pending, so with a
        // gate live every press took the other branch and re-set `stickyExpand`.
        // The panel could not be closed by the key that opened it, at all.
        //
        // Collapsing with a gate still pending is allowed and always was: the
        // island's contract is EDGE-triggered — "action required → expanded
        // (edge-triggered; resolving it collapses)" — so attention expands it
        // once, and a deliberate collapse stands until the NEXT gate arrives.
        // The compact island keeps its amber dot meanwhile, so nothing is lost.
        if applied == .expanded, uiState.selectedTab == .agents {
            collapseExplicitly()
            return
        }

        uiState.selectedTab = .agents

        // NOTHING PENDING — and this must not be silent.
        //
        // It used to `return` here, on the reasoning that there is no point
        // stealing the keyboard for an empty panel. True, and it made the
        // feature untestable: pressing the key with no gate looked EXACTLY like
        // a hotkey that had failed to register, so the first question anyone
        // asks — "is this working?" — had no answer. That is how this was found.
        //
        // So the key always does something. With no gate it opens the panel on
        // the Agents tab, where a gate would appear, and takes no keyboard: you
        // can see that nothing is waiting. Opening on a keypress is a user
        // action, so the island's expansion contract is untouched — the contract
        // is about expanding on its OWN.
        // Nothing pending: open on the Agents tab so you can SEE that nothing
        // is waiting, and take no keyboard. Pinned rather than peeked — the
        // first version borrowed the clipboard's hover-driven `hotkeyExpand`,
        // which only closes if a hover-IN fires after the keypress, so with the
        // pointer already near the notch it stuck open. The toggle above is now
        // the way out, and it depends on no hover event at all.
        guard model.attentionCount > 0 else {
            hoverSuppressed = false
            stickyExpand = true
            apply()
            return
        }
        hoverSuppressed = false
        wantsKeyboard = true
        gateHoldsKeyboard = true
        // The key means "take me to what is waiting", so it opens on that.
        uiState.askingYou = true
        // `stickyExpand` is already set by the attention edge in `apply`, and is
        // what keeps the panel open; `hotkeyExpand` is deliberately NOT set,
        // because its hover-out path releases the keyboard, and brushing the
        // pointer past the notch must not disarm the keys you just armed.
        stickyExpand = true
        apply()
        // Usually already expanded — the attention edge in `apply` got there
        // first — so there is no transition to hand `wantsKeyboard` to, and
        // `transition` is the only place that clears it. Taking the keyboard
        // here means disarming it here too; left set, it would fire on some
        // later, unrelated expand and take the keyboard nobody asked for.
        if applied == .expanded {
            wantsKeyboard = false
            focusForTyping()
        }
    }

    /// The question card's words field, clicked. Only on an open panel with
    /// something waiting, and marked as the gate's keyboard so answering the
    /// last card hands it straight back (see the attention edge in `apply`).
    private func takeKeyboardForAnswer() {
        guard applied == .expanded, model.attentionCount > 0 else { return }
        gateHoldsKeyboard = true
        focusForTyping()
        syncKeyboardHeld()
    }

    // MARK: - Full screen

    /// Re-asks whether the front app is full screen on the island's display,
    /// and re-applies when the answer changed. Not asked inside `apply`, which
    /// runs several times a second.
    private func refreshFullScreen() {
        // Airlock in front means the island was clicked, not that the film
        // ended; keep the last answer.
        guard !FullScreenFront.frontIsUs else { return }
        let now = NotchScreen.target.map(FullScreenFront.isFullScreen(on:)) ?? false
        guard now != frontIsFullScreen else { return }
        frontIsFullScreen = now
        HoverTrace.note("full screen in front: \(now)")
        apply()
    }

    /// Logs every stretch the main thread could not answer a 100ms timer for
    /// more than 300ms — a frozen panel, said in milliseconds. Trace only.
    private func watchMainThreadStalls() {
        guard HoverTrace.isEnabled, stallTimer == nil else { return }
        lastStallTick = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let gap = now.timeIntervalSince(self.lastStallTick)
                if gap > 0.3 { HoverTrace.note("main thread busy \(Int(gap * 1000))ms") }
                self.lastStallTick = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    // MARK: - Top edge

    /// Watch the pointer only while `screen` — the island's display, with its
    /// menu bar hidden — is set; nil stops watching and forgets the reveal.
    private func watchTopEdge(_ screen: NSScreen?) {
        guard screen != nil else {
            if !topEdgeMonitors.isEmpty {
                topEdgeMonitors.forEach(NSEvent.removeMonitor)
                topEdgeMonitors = []
                HoverTrace.note("top edge: not watching")
            }
            topEdgeRevealed = false
            return
        }
        guard topEdgeMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            topEdgeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            topEdgeMonitors.append(local)
        }
        HoverTrace.note("top edge: watching")
    }

    private func pointerMoved() {
        guard let frame = NotchScreen.target?.frame else { return }
        let revealed = TopEdgeReveal.isRevealed(was: topEdgeRevealed,
                                                pointer: NSEvent.mouseLocation, screen: frame)
        guard revealed != topEdgeRevealed else { return }
        topEdgeRevealed = revealed
        HoverTrace.note("top edge: \(revealed ? "revealed" : "left")")
        apply()
    }

    // MARK: - Hover (peek)

    /// Two regions, one pointer. The catcher owns the cutout and the panel owns
    /// everything below it, so the pointer is "on the notch" if either says so —
    /// otherwise crossing from one to the other would read as leaving.
    /// Both hover sources funnel through `HoverArbiter` (Core, tested), which
    /// owns the two rules that have caused bugs here: ORing the panel and the
    /// catcher so crossing between them is not an exit, and ignoring an exit
    /// the pointer did not actually make — SwiftUI reports "the view shrank out
    /// from under a still pointer" identically to "the user walked away".
    private func hoverChanged(_ source: HoverArbiter.Source, hovering: Bool) {
        let pointer = NSEvent.mouseLocation
        let change = hover.update(source, hovering: hovering, pointer: pointer)
        HoverTrace.note("hover \(source) hovering=\(hovering) → \(change) "
            + "at (\(Int(pointer.x)), \(Int(pointer.y)))")
        guard change != .unchanged else { return }

        hoverTask?.cancel()
        if change == .entered {
            // THE hover haptic — and this is why it lives here and not in the
            // kit's `hoverBehavior`, which is where anyone would look for it.
            //
            // `NotchDropCatcher`'s window is at `NSWindow.Level.statusBar + 1`
            // with `ignoresMouseEvents = false`, one level ABOVE the kit's panel
            // (forced to `.statusBar`), and its resting frame is exactly the
            // cutout. The kit's own haptic runs inside
            // `DynamicNotch.updateHoverState`, reachable only from SwiftUI
            // `.onHover` on that panel — so over the cutout the panel never sees
            // the pointer and the kit's tap never happens. It fires only on the
            // ~40pt shoulders the compact island extends past the notch. Aiming
            // at the notch, which is what everybody does, gave zero taps. That
            // fact will not be rediscovered: it is invisible in the kit, both
            // call sites look correct in isolation, and `swift test` has no
            // pointer and no actuator.
            //
            // Driven off the ARBITER's reconciled edge, never off a raw source.
            // Crossing catcher → panel reports an exit and an entry in the same
            // millisecond and `HoverArbiter` returns `.unchanged` for both, so
            // one crossing is one tap; the entries nobody made — a tracking area
            // rebuilt on resize, the panel shrinking under a still pointer — are
            // already filtered by the guard above. A tap wired to either source's
            // own callback would double on every crossing and buzz at the
            // island's own layout.
            //
            // Enter only, deliberately. Arrival is news — the tap is the notch
            // answering that it is a surface and not a bezel. Departure is not:
            // you know you left. And the exit branch below is delayed 450ms as a
            // micro-exit grace, so a tap fired there would land half a second
            // after the pointer had gone, which reads as a random buzz.
            //
            // Not when hidden — the kit guarded the same way. With no island on
            // screen the catcher still covers the cutout, and a bare bezel that
            // taps is feedback for a surface that is not there.
            //
            // A drag never reaches here at all: it arrives through the catcher's
            // `draggingEntered` → `revealTrayForDrag`, not through `onHover`.
            if let applied, applied != .hidden {
                Moments.shared.announce(.pointerArrived)
            }
            // Recorded even when already expanded — the early return below
            // skips the peek machinery, but a hotkey-opened panel is waiting
            // for precisely this event.
            if hotkeyExpand { hoveredSinceHotkey = true }
            if assistantExpand { hoveredSinceAnswer = true }
            guard !hoverSuppressed, applied == .compact else { return }
            hoverTask = Task { [weak self] in
                // INVARIANT, and the reason `PeekDwell` exists as a separate,
                // tested thing: **this path may only ever REFUSE a peek; it must
                // never be able to CAUSE an expansion.** The last version of
                // this loop believed that and was wrong — it evaluated
                // `!hoverSuppressed && applied == .compact` once, HERE, at arm
                // time, which was indistinguishable from checking them every
                // tick while the task only lived 300ms. Since the settle change
                // it lives until the pointer is reported gone, and a single lost
                // hover-out (the panel torn down under a stationary pointer)
                // leaves it waking at 6.7Hz forever and peeking off the first
                // two stationary samples — the island expanding on its own, with
                // the pointer parked somewhere else entirely.
                //
                // So nothing is decided here. Every precondition is re-supplied
                // on every tick, and the tick count is one of them: the loop is
                // bounded, because the conditions are reports from elsewhere and
                // the failure this guards against is one of them being wrong.
                //
                // Sampled, not slept through. A single 300ms sleep asked one
                // question when it woke — is the pointer still inside — and a
                // pointer crossing the notch on its way to the menu bar answers
                // yes for the whole crossing. Two samples in the same place is
                // the pointer having STOPPED, which is what aiming at the notch
                // looks like; the geometry of that lives in `HoverArbiter`.
                for tick in 0..<PeekDwell.maxTicks {
                    try? await Task.sleep(nanoseconds: PeekDwell.tickNanoseconds)
                    guard !Task.isCancelled, let self else { return }
                    // `isReported` rather than `isHovering`: the sources' own
                    // answer. An entry withdrawn in the same instant is exactly
                    // the withdrawal the arbiter swallows, so `isHovering` would
                    // still say yes.
                    switch PeekDwell.step(
                        tick: tick,
                        suppressed: self.hoverSuppressed,
                        presentation: self.applied,
                        pointerReported: self.hover.isReported,
                        pointerStopped: self.hover.hasStopped(at: NSEvent.mouseLocation)
                    ) {
                    case .abandon:
                        return
                    case .sample:
                        continue
                    case .peek:
                        self.hoverExpand = true
                        self.apply()
                        return
                    }
                }
            }
        } else {
            hoverSuppressed = false
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000) // grace: ignore micro-exits
                guard !Task.isCancelled, let self else { return }
                self.hoverExpand = false
                // A hotkey open ends here — but only once the pointer has
                // genuinely been on the notch. Edge-triggering alone was not
                // enough: an out event can arrive without a matching in, and
                // acting on it closed the panel the instant it opened.
                //
                // It also required an EMPTY query, to avoid closing on someone
                // mid-search. That was the wrong guard in the right place: a
                // query outlives the search, so once you had typed anything the
                // panel stopped responding to the pointer entirely and only
                // Escape would dismiss it. The case it was defending against —
                // filtering shrinks the list, the panel shrinks out from under a
                // stationary pointer, and `.onHover` reports that as an exit —
                // is already handled by `HoverArbiter`, which ignores an exit
                // the user did not physically make. A pointer that has actually
                // moved away is intent, query or no query.
                if self.hotkeyExpand && self.hoveredSinceHotkey {
                    self.hotkeyExpand = false
                    self.hoveredSinceHotkey = false
                    self.releaseKeyboard()
                }
                // An answer you have read and moved away from is finished with.
                // Until now only Escape or the 45-second timer cleared one, so
                // the panel sat over the top of the screen long after it had
                // been read — the pointer leaving is the plainest statement
                // that it has been.
                //
                // A PENDING CARD is exempt, and that exemption is the whole
                // reason this is not simply `assistant.dismiss()`. A card is a
                // question waiting on the user; the island contract reserves
                // expansion for exactly that, and dropping one because the
                // pointer wandered would answer it by walking away. `dismiss`
                // would log it `.deferred` and the agent would wait for its
                // own timeout.
                if AnswerDismissal.onPointerExit(
                    answerShowing: self.assistantExpand,
                    hoveredSinceAnswer: self.hoveredSinceAnswer,
                    hasPendingCard: self.assistant.pending != nil) {
                    self.hoveredSinceAnswer = false
                    self.assistant.dismiss()
                }
                self.apply() // collapses unless pinned by tap/attention
            }
        }
    }

    /// A hover source has gone away UNDER the pointer, so the exit that would
    /// normally end the peek is never coming.
    ///
    /// `DynamicNotch.hide()` deinitializes its window, and the kit rebuilds that
    /// window from scratch on a display change; the drop catcher does the same in
    /// `place()`. SwiftUI does not reliably report `.onHover(false)` for a view
    /// that was destroyed rather than exited, and an `NSTrackingArea` on a
    /// released window reports nothing at all. Left alone the arbiter goes on
    /// claiming the pointer is on the notch forever — which is the state the peek
    /// loop used to expand out of.
    ///
    /// All three parts are needed together. Resetting the arbiter WITHOUT
    /// clearing `hoverExpand` is worse than doing nothing: `reset()` makes the
    /// next real exit read as no change, so the `.left` that would have cleared
    /// the peek never arrives, and a peek held across a screen going away comes
    /// back as an expansion when it returns.
    private func forgetHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hover.reset()
        hoverExpand = false
    }

    #if AIRLOCK_GUIDE
    /// A guide is starting: everything that was holding the panel for the
    /// words that started it lets go, and the keyboard goes back to the app
    /// being guided — the next thing typed belongs in its form, not here.
    ///
    /// Not `collapseExplicitly`: that also settles onboarding and dismisses
    /// an answer as a decision, and a guide beginning is neither.
    private func yieldToGuide() {
        stickyExpand = false
        hoverExpand = false
        hotkeyExpand = false
        hoveredSinceHotkey = false
        dictationExpand = false
        if assistant.isPresenting { assistant.dismiss() }
        assistantExpand = false
        if assistant.isCommandBarOpen { assistant.closeCommandBar() }
        wantsKeyboard = false
        releaseKeyboard()
        apply()
    }

    /// Whether the guide held the panel at the last `guideChanged`.
    private var guideHeldPanel = false

    /// The guide changed. Copies what the island reads and re-resolves — but
    /// only when the pill or the hold actually moved: the guide reports once
    /// a second while it runs, and the card's own words reach the panel
    /// through observation, not through here.
    private func guideChanged() {
        let compact = guide.compact
        let holds = guide.panel != nil
        guard compact != uiState.guideCompact || holds != guideHeldPanel else { return }
        uiState.guideCompact = compact
        guideHeldPanel = holds
        apply()
    }
    #endif

    private func collapseExplicitly() {
        stickyExpand = false
        hoverExpand = false
        // Arranging is a mode you are in, not a preference you set. Left on, the
        // next thing you opened the panel for would be a list of widget names
        // instead of the widget you came to look at.
        uiState.isArranging = false
        // Cleared BEFORE `releaseKeyboard`, whose order-out fires a resign-key
        // notification that would otherwise loop straight back in here.
        hotkeyExpand = false
        hoveredSinceHotkey = false
        dictationExpand = false
        // Through the model, not just the flag: clearing `assistantExpand`
        // alone would leave it believing it is still on screen, so the next
        // answer would not re-trigger the expansion.
        if assistant.isPresenting { assistant.dismiss() }
        assistantExpand = false
        // Through the model too, so a drag left mid-flight cannot re-assert the
        // hold on its way out. An explicit collapse is a decision and outranks
        // a gesture — and the two cannot be concurrent anyway, since there is
        // one pointer and it is on the timeline.
        //
        // The flag goes first: `cancelScrub` calls back into `holdForScrub`,
        // which is edge-guarded, so clearing it here makes that callback a
        // no-op instead of an extra collapse transition inside this one.
        scrubExpand = false
        media.cancelScrub()
        // An explicit collapse during setup is the same decision as closing the
        // first-run window: a wizard you dismissed is a wizard you are done
        // with. Settled here rather than merely hidden, or Escape would mean
        // being greeted by setup again on the very next launch.
        endOnboarding()
        hoverSuppressed = true // don't re-peek until the pointer leaves once
        gateHoldsKeyboard = false
        releaseKeyboard()
        apply()
    }

    /// Hold the panel open for the length of a timeline drag, and no longer.
    ///
    /// Deliberately NOT a peek and NOT a pin: it lasts exactly as long as the
    /// button is down. Releasing it re-applies, so a drag that ended with the
    /// pointer somewhere else collapses immediately — the hover-out that fired
    /// mid-drag already cleared `hoverExpand`, and this is what lets that
    /// decision finally land.
    ///
    /// The pairing failure is a hold nobody releases, which is a panel stuck
    /// open forever. Two things close that off: `MediaSectionView`'s
    /// `.onDisappear` cancels a live scrub for exactly the case SwiftUI never
    /// sends `.onEnded` — the view going away underneath the gesture — and
    /// `collapseExplicitly` clears the flag outright, so a deliberate dismissal
    /// is never outvoted by a gesture that is no longer happening.
    private func holdForScrub(_ scrubbing: Bool) {
        guard scrubExpand != scrubbing else { return }
        scrubExpand = scrubbing
        apply()
    }

    /// Open while dictating, and get out of the way afterwards.
    private func showDictation(_ listening: Bool) {
        dictationExpand = listening
        // Raised before `apply()` so the collapse it starts shrinks the
        // dictation surface, not the Home tab. See the flag.
        uiState.holdDictationThroughCollapse = !listening
        if listening { hoverSuppressed = false }
        apply()
    }

    /// Open for an answer, and STAY open.
    ///
    /// Takes the keyboard so Escape can dismiss, using the same Spotlight
    /// arrangement as the clipboard hotkey — and hands it back on the way out,
    /// or the panel keeps eating keystrokes meant for the app you were in.
    private func showAssistant(_ presenting: Bool) {
        assistantExpand = presenting
        // Cleared on the way IN, so a hover from a previous answer cannot
        // dismiss this one before it has been seen.
        if presenting { hoveredSinceAnswer = false }
        if presenting {
            hoverSuppressed = false
            // Dictation ending as an answer arrives: the answer owns the panel.
            uiState.holdDictationThroughCollapse = false
            // A new answer means the previous one's hold-through-collapse is
            // over — this one owns the panel now.
            uiState.holdAnswerThroughCollapse = false
            focusForTyping()
        } else {
            // Keep the answer on screen through the collapse this dismissal is
            // about to cause — the alternative is the home tab mounting under
            // a shrinking panel. See `NotchUIState.holdAnswerThroughCollapse`.
            uiState.holdAnswerThroughCollapse = true
            releaseKeyboard()
        }
        apply()
    }

    /// Give the panel the keyboard, without activating the app.
    ///
    /// The kit only ever calls `orderFrontRegardless`, so the panel is visible
    /// but never key — every keystroke would go to whatever you were typing in.
    /// For the clipboard that is worse than useless: opening the search field by
    /// hotkey and typing would insert the query into your editor. A
    /// `.nonactivatingPanel` whose `canBecomeKey` is true can hold the keyboard
    /// while another app stays frontmost, which is exactly the Spotlight
    /// arrangement this wants.
    private func focusForTyping() {
        let window = notch?.windowController?.window
        // A release may have left the panel refusing key status moments ago —
        // an explicit take always clears it first, or this `makeKey` is a
        // silent no-op and the answer opens with a dead Escape.
        (window as? DynamicNotchPanel)?.refusesKeyStatus = false
        window?.makeKey()
    }

    /// And hand it back.
    ///
    /// Necessary because the panel is ONE window across expanded and compact —
    /// collapsing does not order it out, so without this we keep the keyboard
    /// after closing, and the synthetic ⌘V of auto-paste lands on ourselves
    /// instead of on your editor.
    ///
    /// **Never by ordering the panel out.** That was the first mechanism, and
    /// an order-out is the panel leaving the compositor — a visible blink at
    /// ANY moment. Both timings were tried and both were seen: released before
    /// the collapse it blanked a fully expanded panel ("the notch hides, then
    /// comes back compact"), and deferred 150ms into the collapse it truncated
    /// the shrink mid-animation ("I see it collapsing, then it completely
    /// hides"). There is no instant at which blinking a visible window is
    /// invisible, so the blink moves to a window that cannot be seen: key goes
    /// to the 1×1 clear sink, which then orders out, and the system hands the
    /// keyboard back to the app that had it. The panel never leaves the screen.
    ///
    /// Immediate on purpose — the clipboard's synthetic ⌘V fires 80ms after a
    /// pick, and the hand-off to the sink is synchronous, so the panel has
    /// stopped being key long before the paste lands. The bounce check exists
    /// because the sink hand-off is arranged rather than documented behaviour:
    /// if key ever lands back on the panel, the old visible order-out is still
    /// better than a panel that eats every keystroke.
    private func releaseKeyboard() {
        guard let window = notch?.windowController?.window, window.isKeyWindow else { return }
        let sink = ensureKeySink()
        HoverTrace.note("releaseKeyboard via sink")
        // Ineligible for the duration of the hand-back, or the reassignment
        // that follows the sink's order-out picks the panel right back —
        // measured as `sink BOUNCED` on every release until this line
        // existed, because the kit's `canBecomeKey` is otherwise an
        // unconditional yes. Cleared at the end of the hand-back and by any
        // explicit `focusForTyping`.
        (window as? DynamicNotchPanel)?.refusesKeyStatus = true
        sink.orderFrontRegardless()
        sink.makeKey()
        sink.orderOut(nil)
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let window else { return }
            (window as? DynamicNotchPanel)?.refusesKeyStatus = false
            guard window.isKeyWindow else { return }
            HoverTrace.note("releaseKeyboard sink BOUNCED — visible order-out fallback")
            window.orderOut(nil)
            window.orderFrontRegardless()
        }
    }

    private func ensureKeySink() -> KeySinkPanel {
        if let keySink { return keySink }
        let sink = KeySinkPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        sink.isReleasedWhenClosed = false
        sink.alphaValue = 0
        sink.ignoresMouseEvents = true
        sink.hasShadow = false
        sink.level = .statusBar
        sink.collectionBehavior = [.transient, .ignoresCycle]
        keySink = sink
        return sink
    }

    // MARK: - State

    private func apply() {
        // FIRST, and ONLY while one of the island's two transient windows is
        // still open. Everything below reads those windows against this, and
        // the deadline tasks at the bottom re-enter here to move it on.
        //
        // The write is gated because `NotchUIState` is `@Observable` and both
        // compact slots read `islandNow`: an unconditional store dirties both
        // of them on every hover, every repository tick and every session
        // event — invalidations `@Observable` would otherwise skip entirely.
        // Once both windows have closed, moving the clock cannot change a
        // slot, so not moving it costs nothing.
        //
        // `anyOpen(at:)` and not "is there a stamp": the stamps are
        // long-lived. `routeChangedAt` survives for the rest of the session
        // and `pausedAt` for as long as the track stays paused, so gating on
        // their existence would be gating on nothing an hour later.
        if islandWindows.anyOpen(at: uiState.islandNow) { uiState.islandNow = Date() }
        pulseTickOnCompletions()
        // Driven from here rather than from a second AppModel callback: this
        // already runs on every state change, and the model debounces, so the
        // git rows follow the sessions without another wire to keep in step.
        repository.update(workingDirectories: model.sessions.compactMap(\.cwd))

        let attention = model.attentionCount
        defer { lastAttention = attention }
        let promoted = model.promotedGate(since: lastCards)
        defer { lastCards = model.shownCards }
        // Action required → surface it, ON the agents tab. An interrupt that
        // opened the panel to Spotify while a gate is blocking would break the
        // island contract; taking over the view is what an interrupt is for.
        //
        // This runs even with the agents widget switched off, and the tab is
        // there to switch to because `AgentsWidget.demandsAttention` puts it
        // back for exactly as long as something is blocking. Suppressing it
        // would leave the agent waiting on an answer nobody can see.
        if attention > lastAttention {
            stickyExpand = true
            uiState.selectedTab = .agents
            uiState.askingYou = true
            announceGate()
            Moments.shared.announce(.gateArrived)
        } else if let promoted {
            // The next queued gate took a session's card. Nothing new arrived —
            // no sound, and the island is already open on it — but a listener
            // has no other way to learn the card under them changed.
            announceGate(sessionID: promoted.sessionID)
        }
        if attention == 0, lastAttention > 0 {
            stickyExpand = false // resolved → get out of the way
            uiState.askingYou = false
            // And give the keyboard back, but only if the gate is what took it.
            // Collapsing does not order the panel out (it is one window across
            // both presentations), so without this we keep the keyboard after
            // the card is gone and the next thing you type lands on us.
            if gateHoldsKeyboard {
                gateHoldsKeyboard = false
                releaseKeyboard()
            }
        }

        // A tab can vanish from under you — switching agents off in settings
        // while the panel is sitting on the Agents tab, or the gate that was
        // holding it there being answered. Landing on a tab no longer in the
        // strip is a blank panel with nothing to say why.
        if !registry.visibleTabs().contains(uiState.selectedTab) {
            uiState.selectedTab = .home
        }

        // Everything the compact island resolves against, built ONCE. Both slots
        // and "is the island on screen at all" now read the same value, which is
        // the point: the hand-written expression that used to live here was a
        // second copy of the ladder's reasoning, and a claimant the slots knew
        // about but it did not would simply have been invisible.
        //
        // `CompactIsland.hasContent` is where the driver/passenger distinction
        // lives — a critical battery and a route acknowledgement summon the
        // island; a shelf count or the keep-awake cup only fills a slot that is
        // already there.
        let island = model.compactIslandInput(media: media, calendar: calendar,
                                              agents: agents, battery: battery,
                                              tray: tray, output: audioOutput,
                                              sound: sound, controls: systemControls,
                                              ui: uiState)
        // The rule itself is `IslandPresentation` (Core, tested) — it is a
        // user-set product contract rather than an implementation detail, and
        // the test that matters says content alone never expands. Nothing in
        // this cluster inserts a hold, and nothing in it ever should.
        var holds: IslandPresentation.Holds = []
        if stickyExpand { holds.insert(.pinned) }
        if hoverExpand { holds.insert(.peeked) }
        if hotkeyExpand { holds.insert(.hotkey) }
        if dictationExpand { holds.insert(.dictating) }
        if assistantExpand { holds.insert(.answering) }
        if scrubExpand { holds.insert(.scrubbing) }
        // The one hold no gesture is propping up: setup runs in the panel, so
        // the collapse timer would otherwise eat the wizard mid-sentence.
        if uiState.onboarding != nil { holds.insert(.onboarding) }
        // The guide's first look, its card (layout B), or why it stopped.
        #if AIRLOCK_GUIDE
        if guide.panel != nil { holds.insert(.guiding) }
        #endif

        // Keep-awake while an agent works (card Awake 1) follows the same
        // facts the lamp does; the model ignores a pass that changed nothing.
        systemControls.agentsWorking(island.anyRunning)

        let showing = CompactIsland.hasContent(island)
        // Where the island may REST. Always over a camera housing; on a monitor
        // with the lid shut, only while that screen's menu bar shows — see
        // `VirtualCutout.canRest`. Anything waiting on the owner brings it up
        // regardless, and a gate or a question is exactly that.
        let target = NotchScreen.target
        let canRest = (target?.islandCanRest ?? false) && !frontIsFullScreen
        let awaitingOwner = attention > 0
        watchTopEdge(canRest ? nil : target)
        // Only the top edge BRINGS it back. Being on the island then KEEPS it,
        // the panel reaching far below the edge's keep band — but the catcher
        // under a hidden island is the whole notch strip, and letting that
        // count made a pass a centimetre below the top bring the island over
        // a full-screen video (2026-10-05).
        let pointerAtTop = !canRest
            && (topEdgeRevealed || (hover.isHovering && applied != nil && applied != .hidden))
        // The WALL clock, not `island.now`: that one only moves while a
        // transient window is open (see the top of this function), so a linger
        // measured on it would never run out.
        let clock = Date()
        // Recorded on every pass, so "when did it last have a reason" needs no
        // special-casing of Escape, or of a gate being answered — every route
        // out lands here, and `LastShown` stamps the pass that sees it go.
        lastShown.record(holds: holds, awaitingOwner: awaitingOwner, now: clock)

        let desired = IslandPresentation.resolve(
            hasTargetScreen: target != nil,
            canRest: canRest,
            holds: holds,
            hasContent: showing,
            awaitingOwner: awaitingOwner,
            pointerAtTop: pointerAtTop,
            lastShown: lastShown.date,
            now: clock)
        // The SLOTS, not just the decision — and ONLY WHEN THEY CHANGE.
        //
        // The kit has been confirmed to reach `.compact` correctly, so what is
        // left is what the island draws. Logged unconditionally this fired on
        // every pass, several times a second, and buried the one moment that
        // mattered under thousands of identical lines describing a healthy
        // island. A diagnostic nobody can read is not a diagnostic.
        let slots = "leading=\(CompactIsland.leading(island))"
            + " trailing=\(CompactIsland.trailing(island)) content=\(showing)"
        if slots != lastLoggedSlots {
            lastLoggedSlots = slots
            HoverTrace.note("slots  " + slots)
        }
        HoverTrace.note("apply  sticky=\(stickyExpand) peek=\(hoverExpand) hotkey=\(hotkeyExpand)"
            + " dictate=\(dictationExpand) answer=\(assistantExpand) scrub=\(scrubExpand)"
            + " suppressed=\(hoverSuppressed) rest=\(canRest) top=\(pointerAtTop)"
            + " → \(desired) (was \(applied.map(String.init(describing:)) ?? "none"))")
        transition(to: desired)
        scheduleIslandDeadlines(after: island.now)
        // Without this the island would hold `.compact` until something
        // unrelated moved — `apply` is event-driven and an expiring linger is
        // not an event.
        lingerTask?.cancel()
        lingerTask = wake(at: IslandPresentation.lingerDeadline(canRest: canRest,
                                                               holds: holds,
                                                               awaitingOwner: awaitingOwner,
                                                               lastShown: lastShown.date),
                          after: clock)
    }

    /// The instants the island's two transient windows close, or nil for a
    /// window that was never opened.
    ///
    /// ONE definition, read twice: `apply()` advances `islandNow` only while
    /// one of these is still ahead of it, and `scheduleIslandDeadlines` wakes
    /// at them. Two copies of "which stamp, plus which constant" is exactly the
    /// pair that drifts — and a gate that disagreed with the wake would either
    /// freeze the clock before a window closed or schedule a wake that changes
    /// nothing.
    private struct IslandWindows {
        var routeAcknowledgement: Date?
        var mediaRetirement: Date?
        var keepAwakeStop: Date?
        var usageNotice: Date?

        /// Whether either window still closes in the future of `clock`.
        /// Deliberately the exact negation of `wake`'s `remaining > 0` guard,
        /// so a skipped clock write never skips a wake that was due.
        func anyOpen(at clock: Date) -> Bool {
            [routeAcknowledgement, mediaRetirement, keepAwakeStop, usageNotice].contains { $0.map { $0 > clock } ?? false }
        }
    }

    private var islandWindows: IslandWindows {
        // Sound switched off takes the acknowledgement with it, matching what
        // `compactIslandInput` hands Core — an island that cannot draw the
        // route has no window to keep open for it.
        IslandWindows(
            routeAcknowledgement: (sound.isEnabled ? audioOutput.routeChangedAt : nil)?
                .addingTimeInterval(CompactIsland.routeAcknowledgement),
            mediaRetirement: media.islandPausedAt?
                .addingTimeInterval(CompactIsland.mediaRetirement),
            keepAwakeStop: systemControls.stoppedByCutoffAt?
                .addingTimeInterval(CompactIsland.keepAwakeStopNotice),
            // Gated like `compactIslandInput`: agents off, nothing to show.
            usageNotice: (agents.isEnabled ? model.usageAlerts.noticeAt : nil)?
                .addingTimeInterval(CompactIsland.usageNoticeDuration))
    }

    /// Wake once, at each island transient's deadline, purely to redraw.
    ///
    /// Something has to: nothing else fires. The media poll only runs while
    /// something is playing, so a paused track produces no events at all for
    /// fifteen minutes; and after a route change CoreAudio has nothing more to
    /// say. Two sleeps are the whole cost.
    ///
    /// **The tasks only cause a redraw; they never assert a state.** The truth
    /// is always `islandNow` against the stamp, so a cancelled or dropped timer
    /// degrades to "stale until the next redraw" and never to "stuck on". That
    /// is the difference from `completionTick`, where the Bool IS the truth and
    /// a cancelled task strands the tick on screen forever. Converting that one
    /// to this shape is worth doing and is deliberately out of scope here.
    ///
    /// Only ever scheduled for a deadline in the FUTURE. That guard is what
    /// stops apply → task → apply from looping.
    /// The kit's OWN panel, as the system sees it.
    ///
    /// **Reached through `notch.windowController`, not by scanning `NSApp.windows`.**
    /// The first version filtered for `level >= .statusBar` and took `.first`,
    /// which is the DROP CATCHER: it sits at `.statusBar + 1` (see
    /// `NotchDropCatcher.install`) and is installed before the kit panel exists,
    /// so every reading described a 186×32 always-visible window that has
    /// nothing to do with the island. A measurement pointed at the wrong object
    /// is worse than none, because it reads as evidence.
    ///
    /// Level is worth reading twice: a freshly rebuilt panel is still at
    /// `.screenSaver` until `adoptRebuiltPanel` lowers it, so a value of 1000
    /// here means the rebuild has not finished rather than that anything is
    /// wrong.
    private func describePanelWindow() -> String {
        guard let window = notch?.windowController?.window else { return "win=NONE" }
        let frame = window.frame
        // `#` is the CGWindowID, and it is here so the next person can get
        // PIXELS: `screencapture -l <n> out.png` captures exactly this window
        // (the terminal needs a Screen Recording grant). Every field above it
        // was measured healthy once while the screen showed nothing — state
        // logs end at the view hierarchy, and only a capture sees past it.
        return String(format: "win #%d vis=%@ key=%@ alpha=%.2f lvl=%d x=%.0f y=%.0f %.0fx%.0f screen=%@",
                      window.windowNumber,
                      window.isVisible ? "Y" : "N",
                      window.isKeyWindow ? "Y" : "N",
                      window.alphaValue,
                      window.level.rawValue,
                      frame.origin.x, frame.origin.y, frame.width, frame.height,
                      window.screen?.localizedName ?? "NONE")
    }

    private func scheduleIslandDeadlines(after now: Date) {
        let windows = islandWindows
        routeAckTask?.cancel()
        routeAckTask = wake(at: windows.routeAcknowledgement, after: now)
        mediaRetireTask?.cancel()
        mediaRetireTask = wake(at: windows.mediaRetirement, after: now)
        keepAwakeStopTask?.cancel()
        keepAwakeStopTask = wake(at: windows.keepAwakeStop, after: now)
        usageNoticeTask?.cancel()
        usageNoticeTask = wake(at: windows.usageNotice, after: now)
    }

    private func wake(at deadline: Date?, after now: Date) -> Task<Void, Never>? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    /// A session that just finished a turn (`AgentSession.finishedTurn`) —
    /// acknowledged with a compact ✓ pulse, never an expansion.
    private static let completionLog = Logger(subsystem: "com.airlock.app", category: "moment")

    private func pulseTickOnCompletions() {
        let current = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, $0) })
        defer { knownSessions = current }

        guard let finished = current.values.first(where: { $0.finishedTurn(since: knownSessions[$0.id]) })
        else { return }

        // The session id and the status only, never what was said: enough to
        // tell from the log which agent a chime was for.
        let who = "\(finished.id.prefix(8)) \(finished.status.rawValue)"
        if finished.finishIsNews(at: Date()) {
            Moments.shared.announce(.agentFinished, who)
        } else {
            Self.completionLog.notice("agentFinished quiet · \(who, privacy: .public) answered moments ago")
        }
        uiState.completionTick = true
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.uiState.completionTick = false
        }
    }

    /// Serialize kit calls: transitions chain so a fast flurry of state changes
    /// can't interleave expand/hide animations.
    private func transition(to desired: IslandPresentation) {
        guard desired != applied, let notch else {
            // The answer dismissed but no conversion followed — a hover or pin
            // is keeping the panel open. Then the tab genuinely should mount,
            // now, because the panel is staying.
            uiState.holdAnswerThroughCollapse = false
            uiState.holdDictationThroughCollapse = false
            return
        }
        // The panel is about to get SMALLER because we asked it to — a drop
        // settling, a tap, the chevron, a gate resolving. `.onHover` reports
        // that as an exit, and `HoverArbiter` is built to ignore an exit the
        // pointer did not perform. Here it did not, and the exit is still real:
        // the panel has gone from under it. Say so, or the arbiter keeps
        // believing the pointer is on the notch and eats the next hover-in.
        //
        // Scoped to presentation changes deliberately. A resize the CONTENT
        // caused — filtering the clipboard to one row — never gets here, so the
        // filter that exists for it is untouched.
        let shrinking = applied.map { desired < $0 } ?? false
        if shrinking { hover.forgetAnchor() }
        // Hidden is not a smaller panel, it is no panel: `hide()` deinitializes
        // the window, so there is nothing left to send the hover-out. Forget the
        // whole visit rather than just the anchor — see `forgetHover`.
        if desired == .hidden { forgetHover() }
        let opening = desired == .expanded && applied != .expanded
        let closing = applied == .expanded && desired != .expanded
        applied = desired
        if opening { Moments.shared.announce(.islandOpened) }
        if closing { Moments.shared.announce(.islandClosed) }
        // A picked day is a detour, not a mode — it snaps back rather than
        // becoming somewhere you can get stranded (see `CalendarWidgetModel`),
        // and closing the panel is the strongest "I am done here" there is.
        // Without this, reopening shows whatever day you poked at last Tuesday.
        //
        // Set AFTER `applied`, deliberately: `select` notifies, the notification
        // is `apply()`, and `apply()` comes straight back here — where the guard
        // above now sees the presentation it already has and returns, instead of
        // running the same transition a second time.
        if shrinking { calendar.select(day: nil) }
        // Closing ends the "an agent is asking" view: reopened by hand, the
        // panel is the tab you chose. The next gate's arrival sets it again.
        if shrinking { uiState.askingYou = false }
        // Same reasoning for the typing bar: it opened an empty notch, and a
        // bar left open under a collapse would reopen that empty notch on the
        // next hover, where the tab was expected.
        if shrinking, assistant.isCommandBarOpen { assistant.closeCommandBar() }
        // The system meters are drawn by a panel section and nothing else, so
        // this is the only signal that tells them whether anyone is reading.
        // Expanded, not merely visible: the compact island has never carried a
        // CPU figure. Sent from here because this is the single funnel every
        // presentation change passes through — `applied` is written on the line
        // above and nowhere else.
        system.setPanelVisible(desired == .expanded)
        // The levels card picks its shape here for the same reason, and takes
        // the count from here rather than reading it in `body`: a form chosen
        // during a redraw is a form that can change while it is being looked at.
        sound.setPanelVisible(desired == .expanded,
                              sourceCount: (audioOutput.volume != nil ? 1 : 0)
                                  + appVolume.slots.shown.count)
        let previous = transitionChain
        transitionChain = Task {
            await previous?.value
            // SUPERSEDED BEFORE WE GOT HERE — skip it.
            //
            // `applied` is committed synchronously above; the kit work is
            // queued behind whatever is already animating. So two `apply()`
            // calls in the same millisecond both commit, and the first one's
            // animation still runs in full even though its answer was obsolete
            // before it started. Measured, that is 0.81 seconds of the panel
            // collapsing to the island and growing back:
            //
            //     206.94  dictate=false answer=false → compact  (was expanded)
            //     206.94  dictate=false answer=true  → expanded (was compact)
            //     206.95  kit → compact  begins
            //     207.35  kit → compact  done in 0.40s
            //     207.35  kit → expanded begins
            //     207.76  kit → expanded done in 0.41s
            //
            // It happens whenever one hold hands over to another — dictation
            // ending as an answer arrives is the common one — and it reads as
            // the notch vanishing for a second.
            //
            // Safe to skip because `applied` is the latest intent and the
            // newest transition always runs: if the kit is already in the state
            // the survivor wants, `_expand`/`_compact` guard on `state` and
            // return immediately.
            guard self.applied == desired else {
                HoverTrace.note("kit → \(desired) SKIPPED, superseded by "
                    + "\(self.applied.map(String.init(describing:)) ?? "none")")
                return
            }
            // Hand the ground to our own view ONLY while expanded on glass.
            // Compact keeps the kit's black: the collapsed island is fused to
            // the camera cutout, which is black hardware — glass there would
            // read as a floating chip beside a black hole.
            applyGround(for: desired)
            // Traced because the presentation log and the SCREEN have disagreed
            // twice: `apply` records `.compact` while nothing is drawn. That
            // gap is inside these three calls — a kit-side intermediate hide, a
            // window rebuilt on the wrong screen, a conversion that never
            // started — and the decision log cannot see any of it.
            // Host-visible facts only. The kit's own `state` and
            // `effectiveStyle` are internal to it, and patching the vendored
            // copy to read them would make re-vendoring stop being a file copy.
            let began = Date()
            HoverTrace.note("kit → \(desired) begins  kitWas=\(notch.state)"
                + "  screen=\(NotchScreen.target?.localizedName ?? "NONE")"
                + " notched=\(NotchScreen.target.map { $0.safeAreaInsets.top > 0 } ?? false)")
            self.beginConversionGate()
            self.syncPanelMotion(growing: desired == .expanded)
            // A new change: any check still waiting on the last one is moot.
            self.frameCheckGeneration += 1
            let frames = self.watchesEveryFrame && desired != .hidden
                ? Task { @MainActor [weak self] in
                    await FrameWatch.sample(window: { self?.notch?.windowController?.window },
                                            duration: Self.conversionSettle + 0.45,
                                            notchSize: Self.notchSize())
                }
                : nil
            switch desired {
            case .hidden:
                await notch.hide()
            case .compact:
                if let screen = NotchScreen.target { await notch.compact(on: screen) }
            case .expanded:
                if let screen = NotchScreen.target { await notch.expand(on: screen) }
            }
            self.endConversionGateSoon()
            // The kit's OWN state, which is the thing the screen shows. When
            // this disagrees with `desired`, the controller's log has been
            // lying about what happened — which it did for six commits.
            // Appended AFTER formatting, never concatenated into the format
            // string: the window description carries a `%` the moment anything
            // in it is a percentage, and `String(format:)` would read it as a
            // specifier and print rubbish for the one line that matters.
            // REPAIR A STRANDED FADE, before reporting.
            //
            // `DynamicNotch._hide` arms a close task that sleeps, fades the
            // window to alpha 0, and only THEN re-checks cancellation. Both
            // `_expand` and `_compact` cancel that task at their top — so a
            // conversion arriving inside the fade window gets the correct
            // outcome from the cancel (the window is not deinitialized) and the
            // wrong one from the fade (the window it just kept is at alpha 0).
            // `showWindow`, which is the only thing that restores alpha, runs
            // only when a NEW window was created, so nothing puts it back.
            //
            // The result is a panel in the right state, at the right size, with
            // the right content, and invisible — which is precisely the symptom
            // that survived every other explanation.
            //
            // Repaired here rather than in the kit: it is one line, it is
            // idempotent, and it keeps re-vendoring a file copy.
            if desired != .hidden, let window = notch.windowController?.window,
               window.alphaValue < 1 {
                HoverTrace.note(String(format: "repairing stranded alpha %.2f → 1",
                                       window.alphaValue))
                window.alphaValue = 1
            }
            HoverTrace.note(String(format: "kit → %@ done in %.2fs  kitNow=%@%@  ",
                                   String(describing: desired),
                                   Date().timeIntervalSince(began),
                                   String(describing: notch.state),
                                   String(describing: notch.state)
                                       == String(describing: desired) ? "" : "  ⚠︎ DISAGREES")
                            + self.describePanelWindow())
            // Reapplied because the kit builds a fresh panel in
            // `initializeWindow`: `applyGround` ran before the transition, when
            // the window it pinned was the one about to be thrown away. The
            // ground it chose is still right — only the window is new. Same
            // work as the `onWindowChanged` hook does for the rebuilds we did
            // not cause, and deliberately the same function.
            self.adoptRebuiltPanel(for: desired)
            // Only now is there a window to take the keyboard, and only now is
            // it the one the kit will keep — `initializeWindow` builds a fresh
            // panel, so anything made key before this point was made key on a
            // window that no longer exists. That was the bug: the panel was
            // visible but never key, so ⌘4 went to Chrome and switched tabs.
            if desired == .expanded, self.wantsKeyboard {
                self.wantsKeyboard = false
                self.focusForTyping()
            }
            // WHAT THE PANEL COMPOSITES, not what its state claims — the
            // invisible-island bug read healthy in every state log while the
            // screen showed bare hardware, and this is the measurement that
            // ends that class of investigation. Twice: once now, and once
            // past the spring tail, because a strand created late in the
            // conversion is not there yet when "done" logs.
            self.probeLayers(when: "done")
            probeGeometry(desired, screen: NotchScreen.target ?? NotchScreen.notched)
            self.watchFrame(after: "\(desired)", presentation: desired, settle: Self.conversionSettle)
            if let frames {
                self.reportFrames(await frames.value, presentation: desired, context: "\(desired)")
            }
        }
    }

    /// The frame-by-frame verdict, and under HoverTrace the heights it read
    /// (`·` = nothing below the top bar yet).
    /// `timingElsewhere`: a tab's content fades in by design and is timed on
    /// its own turn, so only the motion is judged from these frames.
    private func reportFrames(_ samples: [FrameWatch.Sample], presentation: IslandPresentation,
                              context: String, timingElsewhere: Bool = false) {
        lastShapeHeight = samples.last?.height
        let gaps = zip(samples, samples.dropFirst()).map { $1.time - $0.time }
        HoverTrace.note(String(format: "frames, widest gap %.0fms, ", (gaps.max() ?? 0) * 1000)
                        + context + ": " + samples.map {
            String(format: "%.0f%@@%.0f", $0.height, $0.hasContent ? "" : "·", $0.time * 1000)
        }.joined(separator: " "))
        let found = FrameWatch.motionProblems(samples, presentation: presentation,
                                              glassGround: appearance.surface.isGlassGround(showing: presentation),
                                              reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        FrameWatch.report(timingElsewhere ? found.filter { $0 != .lateContent } : found,
                          context: context + " (frames)", reading: nil)
    }

    // MARK: - Frame watch (card C4)

    /// How long after the kit returns the island is judged: the conversion
    /// gate's margin and a little more, so the spring's tail has landed.
    static let conversionSettle: TimeInterval = 0.35
    /// A tab's fade starts a frame late and is a 0.3s spring.
    static let tabSettle: TimeInterval = 0.6
    /// The second look, for a strand created late in a change.
    static let lateLook: TimeInterval = 1.2
    /// A new tab fades up by design; it must have begun to show by then.
    static let tabContentBy: TimeInterval = 0.3

    /// Looks at the panel once the change has landed, and again later, and
    /// says only what is wrong — see `FrameWatch`. Stands down if a newer
    /// change starts in between: a picture mid-motion is not a verdict.
    private func watchFrame(after context: String, presentation: IslandPresentation,
                            settle: TimeInterval) {
        frameCheckGeneration += 1
        let generation = frameCheckGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1e9))
            guard let self, self.frameCheckGeneration == generation else { return }
            let first = self.readFrame(presentation)
            let early = FrameWatch.problems(first)
            FrameWatch.report(early, context: context, reading: first)
            try? await Task.sleep(nanoseconds: UInt64((Self.lateLook - settle) * 1e9))
            guard self.frameCheckGeneration == generation else { return }
            let second = self.readFrame(presentation)
            // Only what is new: a problem still there was said once already.
            let late = FrameWatch.problems(second).filter { !early.contains($0) }
            FrameWatch.report(late, context: context + " (late)", reading: second)
        }
    }

    private func readFrame(_ presentation: IslandPresentation) -> FrameWatch.Reading {
        let window = notch?.windowController?.window
        let kit = notch.map { String(describing: $0.state) } ?? "none"
        let reading = FrameWatch.read(window: window, presentation: presentation,
                               kitAgrees: kit == String(describing: presentation),
                               notchSize: Self.notchSize(),
                               overflow: presentation == .expanded ? uiState.panelOverflow : 0,
                               glassGround: appearance.surface.isGlassGround(showing: presentation),
                               hovering: notch?.isHovering ?? false)
        lastShapeHeight = reading.shape?.height
        return reading
    }

    /// The cutout the island is drawn around — the kit is handed the same.
    private static func notchSize() -> CGSize {
        guard let metrics = (NotchScreen.target ?? NotchScreen.notched)?.islandMetrics else { return .zero }
        return CGSize(width: metrics.notchWidth, height: metrics.notchHeight)
    }

    /// The scripted loop the card asks for: open, every tab, close, a full
    /// screen coming and going — `cycles` times, every change watched frame
    /// by frame as well as settled. Started by `--frame-loop <cycles>`.
    ///
    /// Drives the same funnel a person does (`toggle`, the tab, the full-screen
    /// flag `apply` reads) and waits for each change to land before the next,
    /// so what it measures is the island and not a pile-up of its own making.
    func runFrameLoop(cycles: Int) async {
        let log = Logger(subsystem: "com.airlock.app", category: "frame-loop")
        let before = FrameWatch.problemCount
        log.notice("frame loop: \(cycles, privacy: .public) cycles starting")
        watchesEveryFrame = true
        defer { watchesEveryFrame = false }
        var changes = 0
        func step(_ change: () -> Void, wait: TimeInterval) async {
            change()
            changes += 1
            await transitionChain?.value
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        }
        // Long enough for the settled check, short of the late one.
        let rest = Self.conversionSettle + 0.25
        for cycle in 1...max(cycles, 1) {
            if applied == .expanded { await step({ toggle() }, wait: rest) }
            await step({ toggle() }, wait: rest)
            for tab in registry.visibleTabs() where tab != uiState.selectedTab {
                await step({ uiState.selectedTab = tab }, wait: Self.tabSettle + 0.2)
            }
            await step({ toggle() }, wait: rest)
            await step({ frontIsFullScreen = true; apply() }, wait: rest)
            await step({ frontIsFullScreen = false; apply() }, wait: rest)
            if cycle % 25 == 0 {
                log.notice("frame loop: \(cycle, privacy: .public)/\(cycles, privacy: .public), problems \(FrameWatch.problemCount - before, privacy: .public)")
            }
        }
        // Back to whatever the real screen says.
        frontIsFullScreen = false
        refreshFullScreen()
        apply()
        let found = FrameWatch.problemCount - before
        log.notice("frame loop done: \(cycles, privacy: .public) cycles, \(changes, privacy: .public) changes, \(found, privacy: .public) problems, slowest look \(Int(FrameWatch.slowestMeasure), privacy: .public)ms")
        HoverTrace.note("frame loop done: \(cycles) cycles, \(changes) changes, \(found) problems")
    }

    /// Both halves of `LayerProbe`, HoverTrace-gated, now and at rest.
    ///
    /// The echo is the one that matters: the strand this hunts is created
    /// DURING a conversion, so the probe at "done" can run before it exists —
    /// 1.2s clears the conversion spring's tail and the gate margin both.
    private func probeLayers(when: String) {
        guard HoverTrace.isEnabled else { return }
        for line in LayerProbe.report(window: notch?.windowController?.window) {
            HoverTrace.note("probe(\(when)) " + line)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            for line in LayerProbe.report(window: self.notch?.windowController?.window) {
                HoverTrace.note("probe(+1.2s) " + line)
            }
        }
    }

    /// The window in which the compact slots must not begin a transition —
    /// see `NotchUIState.panelConverting` for what strands if they do.
    ///
    /// Opened before the kit call and closed a beat AFTER it returns, not at
    /// it: the kit resumes on a fixed 0.4s sleep, but its conversion is a
    /// spring (`.snappy(duration: 0.4)`) whose tail can still be finalizing
    /// the shoulder insertion when the sleep ends. The margin costs a swap
    /// landing in it the settle animation — it snaps instead — which cannot
    /// be seen; a transition landing there can strand, which is a blank
    /// island until the next content change.
    ///
    /// Begin/end pairs cannot interleave — `transition`s chain, each awaiting
    /// the previous — and a begin cancels the pending end, so a conversion
    /// starting inside the previous one's margin keeps the gate closed rather
    /// than having it yanked open mid-flight by a stale timer.
    private func beginConversionGate() {
        convertingSettleTask?.cancel()
        convertingSettleTask = nil
        uiState.panelConverting = true
    }

    private func endConversionGateSoon() {
        convertingSettleTask?.cancel()
        convertingSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.uiState.panelConverting = false
            // The collapse the dismissal caused is over; whatever the panel
            // shows next, it no longer shows the lingering answer.
            self?.uiState.holdAnswerThroughCollapse = false
            self?.uiState.holdDictationThroughCollapse = false
        }
    }

    /// Hands the ground to our own view ONLY while expanded on glass. Compact
    /// keeps the kit's black: the collapsed island is fused to the camera cutout,
    /// which is black hardware — glass there would read as a floating chip beside
    /// a black hole.
    private func applyGround(for presentation: IslandPresentation? = nil) {
        let showing = presentation ?? applied
        let glassGround = appearance.surface.isGlassGround(showing: showing)
        notch?.backgroundStyle = glassGround ? AnyShapeStyle(.clear) : AnyShapeStyle(.black)
        pinPanelAppearance(for: presentation)
    }

    /// The panel's appearance is the GROUND's, never the system's.
    ///
    /// Two things decide light-or-dark inside the panel and they were reading
    /// different sources. `Theme` resolves through the SwiftUI `colorScheme`,
    /// which `NotchRootView` sets from the chosen surface — so the palette always
    /// matched the setting. The glass ITSELF is AppKit material, and material
    /// resolves its variant from the window's `effectiveAppearance` — which
    /// nothing here set, so it followed System Settings. Measured on the live
    /// panel: surface `.darkGlass` on a Light Mode Mac, window `NSAppearanceNameAqua`.
    ///
    /// A ground and a palette disagreeing about which way round they are is the
    /// one thing neither can survive, and it lands on every widget at once
    /// because both are panel-wide. The black ground never showed it, which is
    /// why it survived this long — black is a literal colour and answers to no
    /// appearance at all.
    ///
    /// Pinning the window is what puts both back on one source. It is the window
    /// and not the view because material reads the window; and it is the GROUND
    /// and not the surface setting because a collapsed island is black hardware
    /// whatever the expanded panel is made of — see `applyGround`.
    private func pinPanelAppearance(for presentation: IslandPresentation? = nil) {
        let scheme = appearance.surface.groundScheme(showing: presentation ?? applied)
        notch?.windowController?.window?.appearance =
            NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }

    /// Off the transition chain on purpose: the probe waits for the opening
    /// animation to settle before reading the panel, and blocking the chain on
    /// that would put a delay in front of every state change.
    private func probeGeometry(_ desired: IslandPresentation, screen: NSScreen) {
        guard NotchGeometryProbe.isEnabled else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            NotchGeometryProbe.dump("\(desired)", screen: screen,
                                    panel: self?.notch?.windowController?.window)
        }
    }
}
