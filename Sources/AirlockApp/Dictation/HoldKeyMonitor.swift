import AppKit
import AirlockCore

/// Watches a bare modifier key being held down and let go, system-wide.
///
/// A `CGEventTap` rather than a Carbon hot key, for two reasons that only became
/// obvious after trying the other way:
///
/// 1. **Carbon cannot bind a bare modifier at all.** `RegisterEventHotKey` needs
///    a real key plus modifiers, so the gesture becomes a chord like ⌥Space —
///    and since a listen-only tap does not consume anything, that chord would
///    *also* type its character. Dictating would have inserted a stray
///    non-breaking space into the document every single time.
/// 2. **The tap sees the actual key-up.** Carbon does deliver releases — that
///    was verified — but recovering a *missed* one drove me to
///    `CGEventSource.keyState`, which deadlocks the main thread inside SkyLight.
///    Watching `flagsChanged` needs no polling and no recovery: the release is
///    an event like any other.
///
/// **Needs Input Monitoring, and `start` returning true does not mean it has
/// it.** This comment used to say "needs Accessibility" and that
/// `CGEvent.tapCreate` returning nil without it "is the only signal there is".
/// Both halves were wrong, and together they cost an afternoon of resetting the
/// wrong permission: the gate is `kTCCServiceListenEvent`, and `tapCreate` hands
/// back a valid port to a process that will never receive a single event. Ask
/// `health()` — see `EventTapCheck` for what the system actually reports.
@MainActor
final class HoldKeyMonitor {
    /// Modifiers that type nothing on their own, so a listen-only tap can watch
    /// them without the keystroke also landing in your text.
    enum Key: String, CaseIterable, Identifiable, Codable, Sendable {
        case control, option, command, shift, function

        var id: String { rawValue }

        var flag: CGEventFlags {
            switch self {
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .command: return .maskCommand
            case .shift: return .maskShift
            case .function: return .maskSecondaryFn
            }
        }

        var displayName: String {
            switch self {
            case .control: return "⌃ Control"
            case .option: return "⌥ Option"
            case .command: return "⌘ Command"
            case .shift: return "⇧ Shift"
            case .function: return "fn"
            }
        }

        /// Just the symbol, for a keycap with no room for the word.
        ///
        /// Separate from `displayName` rather than sliced off it: `fn` has no
        /// glyph and is its own name, so taking the first character would print
        /// a lone "f".
        var glyph: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .command: return "⌘"
            case .shift: return "⇧"
            case .function: return "fn"
            }
        }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var key: Key = .control
    private var isDown = false
    /// Set once a hold has been disqualified by a chord, and held until the
    /// modifier is physically released — otherwise the eventual key-up would be
    /// delivered as a finished dictation.
    private var cancelled = false
    private var onDown: (() -> Void)?
    private var onUp: (() -> Void)?
    private var onCancel: (() -> Void)?

    var isRunning: Bool { tap != nil }

    /// What every tap here asks to see.
    ///
    /// Hoisted out of `start` so the liveness check can ask about *exactly* what
    /// was requested. A check against a hand-copied mask would drift from the
    /// one in use and then quietly report a healthy tap as narrowed, which is
    /// the same class of lie this check exists to stop.
    ///
    /// `keyDown` and the mouse buttons matter as much as `flagsChanged`, and
    /// watching only the latter was a bug with teeth: holding ⌥ to delete
    /// several words at a time outlasts `HoldGesture.minimumHold`, so the app
    /// opened the microphone and delivered a transcript for a chord the user
    /// was using to edit text. A bare-modifier gesture is only a gesture when
    /// the modifier is alone.
    ///
    /// **Nothing about these events is read.** The callback looks at the type
    /// and at nothing else — not the key code, not the character, not the
    /// click location. All it needs to know is that something else happened.
    ///
    /// **The mouse half of that was described and never wired.** The mask was
    /// `flagsChanged | keyDown`, so ⌃-click — which is right-click on this
    /// platform — opened the microphone and delivered a hold on release, and
    /// so did ⌥-drag and ⌃-scroll (screen zoom). The comment above claimed
    /// otherwise and `hasOtherModifier` pointed at a `handleOtherInput` that
    /// did not exist, which is how a gap survives review: it reads as covered.
    ///
    /// Scroll is in for zoom specifically. It is the one high-frequency event
    /// here, and it costs nothing: the handler returns immediately unless a
    /// hold is actually open.
    static let eventMask: UInt64 = (1 << CGEventType.flagsChanged.rawValue)
        | (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.scrollWheel.rawValue)

    /// Whether the taps this process created are actually being fed.
    ///
    /// Process-wide rather than per-monitor, because the permission is: the hold
    /// tap and the ask tap stand or fall together, and `CGGetEventTapList`
    /// offers no way to recognise one of our own ports in the list anyway.
    static func health() -> EventTapHealth {
        EventTapCheck.health(of: InputMonitoring.tapsOwnedByThisProcess(),
                             requested: eventMask)
    }

    /// False means `CGEvent.tapCreate` refused outright — rare, and **not** the
    /// permission check. A true return means a port exists and nothing more;
    /// `health()` is what says whether events will arrive.
    @discardableResult
    func start(key: Key, onDown: @escaping () -> Void, onUp: @escaping () -> Void,
               onCancel: @escaping () -> Void) -> Bool {
        stop()
        self.key = key
        self.onDown = onDown
        self.onUp = onUp
        self.onCancel = onCancel

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            // Listen-only: we observe the modifier, we never swallow it, so
            // holding it goes on behaving exactly as it always did.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(Self.eventMask),
            callback: holdKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
        cancelled = false
        onDown = nil
        onUp = nil
        onCancel = nil
        onCancelReason = nil
    }

    /// Called from the tap callback, already on the main run loop.
    fileprivate func handle(flags: CGEventFlags) {
        let held = flags.contains(key.flag)

        if isDown {
            guard held else {
                // Released. A hold already disqualified by a chord ends silently
                // — delivering it would type the words the chord was editing.
                isDown = false
                if cancelled { cancelled = false } else { onUp?() }
                return
            }
            // A second modifier joined: ⌥ became ⌘⌥. That is a shortcut, not
            // speech.
            if !cancelled, hasOtherModifier(flags) {
                cancelled = true
                onCancelReason?(String(format: "another modifier joined (flags=0x%llx)",
                                       flags.rawValue))
                onCancel?()
            }
            return
        }

        // Only starts when the modifier is alone. Coming down as part of an
        // existing chord never begins a hold at all.
        if held, !hasOtherModifier(flags) {
            isDown = true
            cancelled = false
            onDown?()
        }
    }

    /// A key, click or scroll while the modifier is held means it was a chord.
    fileprivate func handleOtherInput() {
        guard isDown, !cancelled else { return }
        cancelled = true
        onCancelReason?("another input arrived")
        onCancel?()
    }

    /// Names the cause, because "cancelled" on its own is unfalsifiable — a
    /// dictation that dies mid-sentence needs to say which check killed it.
    var onCancelReason: ((String) -> Void)?

    /// The four modifiers people actually build shortcuts from.
    ///
    /// `.maskSecondaryFn` is deliberately absent: macOS sets it for arrow keys,
    /// function keys and forward-delete, so treating it as a disqualifier risked
    /// a keyboard where the fn bit is set often enough to stop every hold from
    /// ever starting. Chords involving fn are caught by `handleOtherInput`
    /// instead, since they all involve a real key.
    private func hasOtherModifier(_ flags: CGEventFlags) -> Bool {
        let chordable: [CGEventFlags] = [.maskControl, .maskAlternate,
                                         .maskCommand, .maskShift]
        return chordable.contains { $0 != key.flag && flags.contains($0) }
    }

    /// The system disables a tap that takes too long, or on some user input.
    /// Re-enabling is not optional: a disabled tap goes silent with no error,
    /// and dictation would simply stop working until the app restarted.
    fileprivate func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

/// A C function pointer: no captures, so the monitor arrives via `userInfo`.
private let holdKeyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HoldKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { monitor.reEnable() }
    case .flagsChanged:
        let flags = event.flags
        MainActor.assumeIsolated { monitor.handle(flags: flags) }
    case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
        // The TYPE only. Nothing about the event's content is read — not the
        // key code, not the character, not the click location, not the scroll
        // delta. All it needs to know is that something else happened.
        MainActor.assumeIsolated { monitor.handleOtherInput() }
    default:
        break
    }
    // Always passed through untouched — this is an observer, not a filter.
    return Unmanaged.passUnretained(event)
}
