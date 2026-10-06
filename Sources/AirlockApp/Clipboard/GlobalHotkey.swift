import AppKit
import Carbon.HIToolbox
import os

/// A system-wide hotkey, via Carbon's `RegisterEventHotKey`.
///
/// Carbon because it is the only route that does **not** require Accessibility.
/// `NSEvent.addGlobalMonitorForEvents` would need the same trust as a keylogger,
/// which is an absurd price for "open a panel" — and it would mean the app could
/// not have a hotkey at all until the user granted it. This API is ancient and
/// undeprecated for exactly this reason.
///
/// Written rather than pulled in: the package has no external dependencies and
/// this is eighty lines.
@MainActor
final class GlobalHotkey {
    /// A key combination, stored as Carbon codes so it round-trips through
    /// defaults without a translation layer.
    struct Binding: Hashable, Codable, Sendable {
        var keyCode: UInt32
        var carbonModifiers: UInt32

        /// Maccy's own combination. Taken deliberately — see the note in
        /// `ClipboardPane` about what happens if both apps are running.
        static let commandShiftC = Binding(keyCode: UInt32(kVK_ANSI_C),
                                           carbonModifiers: UInt32(cmdKey | shiftKey))
        static let commandShiftV = Binding(keyCode: UInt32(kVK_ANSI_V),
                                           carbonModifiers: UInt32(cmdKey | shiftKey))
        static let optionCommandV = Binding(keyCode: UInt32(kVK_ANSI_V),
                                            carbonModifiers: UInt32(cmdKey | optionKey))
        static let controlOptionCommandV = Binding(keyCode: UInt32(kVK_ANSI_V),
                                                   carbonModifiers: UInt32(cmdKey | optionKey | controlKey))

        /// The command bar's default, and the two chords it is not.
        ///
        /// It was `⌘⇧Space` for one build: 1Password claims that on a great
        /// many Macs, so it registered and then never fired. Before that it was
        /// `⌥Space`, which fought dictation's own ask gesture.
        ///
        /// It is `⌥Space` again because the second problem was fixed properly
        /// rather than dodged — see `DictationModel.abandonHoldForChord`. A
        /// chord sharing a modifier with a hold key no longer leaves a hold
        /// running, so the chord people already reach for is available again.
        static let optionSpace = Binding(keyCode: UInt32(kVK_Space),
                                         carbonModifiers: UInt32(optionKey))

        /// Offered in Settings for anyone whose ⌥Space is taken (Alfred, and
        /// some launchers). Not the default: 1Password owns it widely.
        static let commandShiftSpace = Binding(keyCode: UInt32(kVK_Space),
                                               carbonModifiers: UInt32(cmdKey | shiftKey))

        /// The fallback with no Space in it at all, for when both are spoken for.
        static let commandShiftK = Binding(keyCode: UInt32(kVK_ANSI_K),
                                           carbonModifiers: UInt32(cmdKey | shiftKey))

        /// The gate hotkey's default. Two keys, after the three-key version was
        /// tried and rejected as too awkward to reach for.
        ///
        /// It was `⌃⌥⌘A`, chosen because a global hotkey outranks an app's own
        /// menu shortcut and a two-key chord therefore takes a key people
        /// already press: `⌘⇧A` is Finder's Applications folder. That reasoning
        /// is still true and it is now a stated trade rather than an avoided
        /// one — a shortcut nobody can be bothered to press protects nothing,
        /// and this one has to be reachable one-handed while an agent waits.
        ///
        /// Same trade the clipboard already makes with `⌘⇧C`, which is Maccy's
        /// default, and says so in Settings. `⌃⌥⌘A` is still offered there for
        /// anyone who wants Finder's shortcut back.
        static let controlOptionCommandA = Binding(keyCode: UInt32(kVK_ANSI_A),
                                                   carbonModifiers: UInt32(cmdKey | optionKey | controlKey))
        static let commandShiftA = Binding(keyCode: UInt32(kVK_ANSI_A),
                                           carbonModifiers: UInt32(cmdKey | shiftKey))
        static let commandShiftG = Binding(keyCode: UInt32(kVK_ANSI_G),
                                           carbonModifiers: UInt32(cmdKey | shiftKey))

        /// Keep-awake's shortcut, off until switched on in Settings. Three keys
        /// so that switching it on takes nothing an app already uses.
        static let controlOptionCommandW = Binding(keyCode: UInt32(kVK_ANSI_W),
                                                   carbonModifiers: UInt32(cmdKey | optionKey | controlKey))

        /// The Cocoa equivalent of `carbonModifiers`, for checking whether the
        /// chord is still held without touching `CGEventSource` — see the
        /// deadlock note in `DictationModel.startWatchdog`.
        var cocoaModifiers: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            return flags
        }

        var displayName: String {
            var parts = ""
            if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
            if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
            if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
            if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
            return parts + (Self.keyNames[keyCode] ?? "?")
        }

        /// Spelled out, for speech.
        ///
        /// VoiceOver does read the modifier glyphs, but "⌃⌥⌘A" spoken as symbols
        /// is easy to lose in a sentence — and this is the one place the key is
        /// announced to somebody who cannot see it printed anywhere.
        var spokenName: String {
            var parts: [String] = []
            if carbonModifiers & UInt32(controlKey) != 0 { parts.append("Control") }
            if carbonModifiers & UInt32(optionKey) != 0 { parts.append("Option") }
            if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
            if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
            parts.append(Self.keyNames[keyCode] ?? "?")
            return parts.joined(separator: "-")
        }

        /// Every letter and digit, because the recorder accepts any of them and
        /// a chord it cannot name would show as "?".
        private static let keyNames: [UInt32: String] = {
            let letters: [(Int, String)] = [
                (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
                (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
                (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
                (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
                (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
                (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
                (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
                (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
                (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
                (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"), (kVK_Space, "Space"),
            ]
            return Dictionary(uniqueKeysWithValues: letters.map { (UInt32($0.0), $0.1) })
        }()
    }

    /// Keyed by hotkey id, because the Carbon callback is a bare C function
    /// pointer with no room for a captured self.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installedHandler: EventHandlerRef?

    private var reference: EventHotKeyRef?
    private var id: UInt32?

    /// Non-nil when the last `register` failed. Surfaced in Settings rather than
    /// logged: a hotkey that silently does nothing is the single most confusing
    /// way for this feature to break, and the usual cause — another app already
    /// holds the combination — is invisible from here.
    private(set) var lastError: String?

    /// The combination is a scarce global resource. If another app already owns
    /// it, `RegisterEventHotKey` fails and we say so instead of pretending.
    @discardableResult
    func register(_ binding: Binding, action: @escaping () -> Void) -> Bool {
        unregister()
        Self.installSharedHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else {
            Self.log.error("hotkey refused, status \(status, privacy: .public)")
            lastError = Self.failureMessage(binding, status: status)
            return false
        }

        Self.handlers[id] = action
        self.reference = reference
        self.id = id
        lastError = nil
        return true
    }

    /// What Settings shows for a refused combination. Its own function so the
    /// state gallery prints the same words without registering anything.
    private nonisolated static let log = Logger(subsystem: "com.airlock.app", category: "hotkey")

    /// The status code is for us, so it goes to the log, not the sentence.
    static func failureMessage(_ binding: Binding, status: OSStatus) -> String {
        "\(binding.displayName) is already used by another app. Pick a different shortcut."
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let id { Self.handlers.removeValue(forKey: id) }
        reference = nil
        id = nil
    }

    // No deinit: `EventHotKeyRef` is a non-Sendable `OpaquePointer`, so a
    // nonisolated deinit cannot legally touch it. `unregister()` is the teardown
    // — called on every rebind — and the registration is owned for the app's
    // lifetime, where the process exiting releases it anyway.

    private static let signature: FourCharCode = {
        let chars = Array("agnt".utf8)
        return chars.reduce(FourCharCode(0)) { ($0 << 8) + FourCharCode($1) }
    }()

    /// Press only.
    ///
    /// `kEventHotKeyReleased` is real and IS delivered — measured on this
    /// machine, 2.3s and 3.1s after the press, matching how long the key was
    /// held. It is not registered here because nothing needs it: dictation, the
    /// only hold gesture in the app, uses a `CGEventTap` instead, since Carbon
    /// cannot bind a bare modifier at all. See `HoldKeyMonitor`.
    private static func installSharedHandlerIfNeeded() {
        guard installedHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotkeyCallback, 1, &spec, nil, &installedHandler)
    }

    fileprivate static func fire(_ id: UInt32) {
        handlers[id]?()
    }
}

/// A C function pointer: it captures nothing, so the hotkey id is the only way
/// back to the closure.
private let hotkeyCallback: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    // Carbon already dispatches on the main thread; the hop is what lets the
    // compiler prove it rather than take our word.
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GlobalHotkey.fire(id) }
    }
    return noErr
}
