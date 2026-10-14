import AVFoundation
import AirlockCore
import AppKit
import ApplicationServices
import Speech
import Synchronization

/// Keeps your words out of the notes while you are muted in the call.
///
/// The microphone hears you either way (see `CallMuteLabels`), so this
/// looks at the call app's mute button a few times a second through
/// Accessibility, the permission dictation's typing already holds, and
/// writes what it sees into a `MuteTimeline`. The microphone's sound passes
/// through `CallMuteGate` on its way to the transcriber and comes out silent
/// for every stretch you were muted.
///
/// No button found (another language, an app it does not know,
/// Accessibility off) means nothing is silenced: the notes behave as they
/// did before this existed, and the log says so once.
@MainActor
final class CallMuteWatcher {
    static let interval: Duration = .milliseconds(300)

    /// A fresh one per call, so one call's mutes never reach the next.
    private(set) var gate = CallMuteGate()
    private let log: (String) -> Void
    private var loop: Task<Void, Never>?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func start(call: OngoingCall) {
        stop()
        gate = CallMuteGate()
        guard AXIsProcessTrusted() else {
            log("mute: can't see the call's mute button without Accessibility")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: call.bundleID).first
        else { return }
        let reader = CallMuteReader(pid: app.processIdentifier,
                                    family: CallGlyph.isBrowser(call.bundleID) ? .browser : .app)
        let gate = gate
        let log = log
        loop = Task {
            var shown: Bool?
            while !Task.isCancelled {
                let at = Date()
                let look = await reader.look()
                guard !Task.isCancelled else { return }
                gate.observe(look.muted, at: at)
                if let note = look.note { log("mute: \(note)") }
                if let muted = look.muted, muted != shown {
                    log(muted ? "you: muted" : "you: unmuted")
                    shown = muted
                }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}

/// The meeting point of the button watcher and the microphone's sound:
/// written a few times a second from one side, read for every piece of
/// sound from the other, so a `Mutex` and nothing else.
final class CallMuteGate: Sendable {
    /// How late the sound reaches the transcriber, so a mute counts from the
    /// look before it was seen (`MuteTimeline`). Longer than a look plus
    /// the time to read the button; nobody waits on finished sentences.
    static let delay: TimeInterval = 1

    private let timeline = Mutex(MuteTimeline())

    func observe(_ muted: Bool?, at date: Date) {
        timeline.withLock { timeline in
            timeline.observe(muted, at: date)
            timeline.forget(before: date.addingTimeInterval(-60))
        }
    }

    func isMuted(at date: Date) -> Bool {
        timeline.withLock { $0.isMuted(at: date) }
    }

    /// `source` a second late, silent wherever you were muted. Silence
    /// rather than nothing: the transcriber times its lines by counting
    /// samples, and a gap would move every line after it.
    func silencing(_ source: AsyncStream<AnalyzerInput>) -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let task = Task.detached { [self] in
            var waiting: [(heard: Date, input: AnalyzerInput)] = []
            func pass(_ item: (heard: Date, input: AnalyzerInput)) {
                if isMuted(at: item.heard) { Self.silence(item.input.buffer) }
                continuation.yield(item.input)
            }
            for await input in source {
                let now = Date()
                waiting.append((now, input))
                while let first = waiting.first, now.timeIntervalSince(first.heard) >= Self.delay {
                    pass(waiting.removeFirst())
                }
            }
            // The microphone stopped: the last second goes now, not never.
            waiting.forEach(pass)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func silence(_ buffer: AVAudioPCMBuffer) {
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
    }
}

/// Finds the call app's mute button and reads it. An actor because every
/// Accessibility call is a round trip to the call app and the first search
/// can take a second: none of it may run on the main thread.
actor CallMuteReader {
    struct Look: Sendable {
        var muted: Bool?
        /// A line for the log, when something worth saying happened.
        var note: String?
    }

    /// Elements looked at before a search gives up, and the time it may take.
    static let searchLimit = 8_000
    static let searchBudget: TimeInterval = 1.5
    /// Kinds of element a mute control can be.
    static let pressable: Set<String> = [
        "AXButton", "AXCheckBox", "AXMenuItem", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
    ]

    private let pid: pid_t
    private let family: CallMuteLabels.Family
    private var button: (element: AXUIElement, role: String)?
    /// After a search that found nothing, the next waits longer, up to 15 s,
    /// so a call app without a known button is not searched all call long.
    private var nextSearch = Date.distantPast
    private var backoff: TimeInterval = 1
    private var foundBefore = false
    private var saidNotFound = false
    private var oddWordings: Set<String> = []

    init(pid: pid_t, family: CallMuteLabels.Family) {
        self.pid = pid
        self.family = family
    }

    func look() -> Look {
        if let button {
            if let muted = read(button.element, role: button.role) { return Look(muted: muted) }
            // Gone or relabelled past recognition: find it again.
            self.button = nil
        }
        guard Date() >= nextSearch else { return Look() }
        let started = Date()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chrome and Electron apps build their page's tree only when asked
        // (as `FocusProbe` does for dictation).
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let found = search(app)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let hit = found.hit {
            button = (hit.element, hit.role)
            backoff = 1
            saidNotFound = false
            defer { foundBefore = true }
            return Look(muted: hit.muted,
                        note: foundBefore ? nil : "found \(hit.role) \"\(hit.label)\" (\(found.looked) elements, \(ms) ms)")
        }
        nextSearch = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 15)
        if let odd = found.oddWording, oddWordings.insert(odd).inserted {
            return Look(note: "the microphone button reads \"\(odd)\", wording not known yet")
        }
        if !saidNotFound {
            saidNotFound = true
            return Look(note: "no mute button found (\(found.looked) elements, \(ms) ms)")
        }
        return Look()
    }

    // MARK: - Reading

    private func read(_ element: AXUIElement, role: String) -> Bool? {
        let values = attributes(of: element, [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute])
        guard values.count == 3 else { return nil }
        let checked = role == "AXCheckBox" ? (values[2] as? NSNumber).map { $0.intValue == 1 } : nil
        for case let label as String in values.prefix(2) where !label.isEmpty {
            if let muted = CallMuteLabels.isMuted(label: label, checked: checked, in: family) { return muted }
        }
        return nil
    }

    private struct Hit {
        let element: AXUIElement
        let role: String
        let label: String
        let muted: Bool
    }

    /// Breadth first through the windows, then the menu bar for an app of
    /// its own (Zoom keeps "Mute audio" there too). Windows first because a
    /// menu's wording can lag until the menu is opened.
    private func search(_ app: AXUIElement) -> (hit: Hit?, looked: Int, oddWording: String?) {
        var queue: [AXUIElement] = []
        if let windows = attributes(of: app, [kAXWindowsAttribute]).first as? [AXUIElement] {
            queue += windows
        }
        if family == .app, let bar = attributes(of: app, [kAXMenuBarAttribute]).first,
           CFGetTypeID(bar as CFTypeRef) == AXUIElementGetTypeID() {
            queue.append(bar as! AXUIElement)
        }
        let deadline = Date().addingTimeInterval(Self.searchBudget)
        var index = 0
        var oddWording: String?
        while index < queue.count, index < Self.searchLimit, Date() < deadline {
            let element = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, 0.25)
            let values = attributes(of: element, [kAXRoleAttribute, kAXDescriptionAttribute,
                                                  kAXTitleAttribute, kAXValueAttribute, kAXChildrenAttribute])
            guard values.count == 5 else { continue }
            let role = values[0] as? String ?? ""
            if Self.pressable.contains(role) {
                let checked = role == "AXCheckBox" ? (values[3] as? NSNumber).map { $0.intValue == 1 } : nil
                for case let label as String in [values[1], values[2]] where !label.isEmpty {
                    if let muted = CallMuteLabels.isMuted(label: label, checked: checked, in: family) {
                        return (Hit(element: element, role: role, label: label, muted: muted), index, nil)
                    }
                    if family == .browser, CallMuteLabels.looksLikeMeetMicButton(label) { oddWording = label }
                }
            }
            if let children = values[4] as? [AXUIElement], queue.count < Self.searchLimit * 2 {
                queue += children
            }
        }
        return (nil, index, oddWording)
    }

    /// Several attributes in one round trip. A missing one comes back as an
    /// error value, which no cast below accepts.
    private func attributes(of element: AXUIElement, _ names: [String]) -> [Any] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let list = values as? [Any] else { return [] }
        return list
    }
}
