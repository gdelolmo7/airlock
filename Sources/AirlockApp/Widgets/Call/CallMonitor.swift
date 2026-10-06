import AirlockCore
import AppKit
import CoreAudio
import Observation
import os

/// Whether the user is on a call, for the island's call pill.
///
/// Reads CoreAudio's process list once a second — which apps hold the
/// microphone and which are playing — and lets `CallDetector` (Core, tested)
/// decide. A property read, never a tap: no permission, no audio touched.
///
/// Logs to category `call`: the calling app's bundle ID and how long the call
/// lasted. Never anything said on it — there is nothing here that could hear
/// it anyway.
@MainActor
@Observable
final class CallMonitor {
    private(set) var call: OngoingCall?

    /// Called when `call` changes, so the controller re-derives whether the
    /// island is on screen — a call is a driver.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var detector = CallDetector()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?
    /// Samples since the call was last saved, so it is written every few
    /// seconds rather than every second.
    @ObservationIgnored private var unsavedSamples = 0
    /// Daemon bundle IDs already logged once, so an unrecognised one is
    /// visible in the log without a line a second.
    @ObservationIgnored private var reportedUnowned: Set<String> = []

    private static let log = Logger(subsystem: "com.airlock.app", category: "call")
    private static let interval: TimeInterval = 1
    /// The call in progress, saved so a restart mid-call (an update, a
    /// reinstall) picks the timer back up. The app's ID and two dates; never
    /// anything about who is on the call.
    private static let savedCallKey = "call.inProgress"
    private static let saveEvery = 5

    func start() {
        guard timer == nil else { return }
        let saved = Self.loadSavedCall()
        detector = CallDetector(resuming: saved, now: Date())
        if detector.isResumePending, let saved {
            let seconds = Int(Date().timeIntervalSince(saved.seenAt))
            Self.log.log("resume pending \(saved.call.bundleID, privacy: .public), saved \(seconds)s ago")
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCall() }
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // Coalescing is fine: a second's slop on a call timer nobody reads to
        // the second costs nothing, and it lets the Mac batch the wake-up.
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        saveCall()
        timer?.invalidate()
        timer = nil
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
    }

    /// Brings the call's window forward. False when there is no call or its
    /// app is not running, so the caller can fall back to opening the panel.
    @discardableResult
    func bringForward() -> Bool {
        guard let call else { return false }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: call.bundleID).first {
            return app.activate()
        }
        // FaceTime's daemons hold the audio for an iPhone call, and the app
        // itself may not be running yet; opening it shows the call.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: call.bundleID)
        else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        return true
    }

    /// The calling app's icon IN COLOUR, or nil to draw the plain phone glyph.
    /// `CallPill` greys it since 2026-10-06, but greying the designer's artwork
    /// still keeps the logo's shape; greying the system's glass square does not.
    ///
    /// **Read from the app's own icon file, not asked of macOS.** Since macOS
    /// 26 the system hands out every icon in the user's chosen style — on the
    /// owner's Mac "Clear, dark", so WhatsApp came back as a grey glass square
    /// that said nothing in a 13pt slot. The file inside the bundle is still the
    /// designer's colour artwork, and colour is the only way a logo that small
    /// can be told apart. The system's version is the fallback, for an app that
    /// ships its icon only in an asset catalog.
    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = bundleIcon(for: bundleID) ?? systemIcon(for: bundleID)
        icons[bundleID] = icon
        return icon
    }

    /// One read per app per launch: the view asks on every redraw.
    private static var icons: [String: NSImage] = [:]

    private static func bundleIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url),
              let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        else { return nil }
        let file = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
        return NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/\(file)"))
    }

    private static func systemIcon(for bundleID: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func sample() {
        let wasPending = detector.isResumePending
        let change = detector.observe(micUsers(), at: Date())
        if wasPending, !detector.isResumePending, !Self.isResume(change) {
            Self.log.log("saved call not found again")
        }
        switch change {
        case .started(let call):
            Self.log.log("started \(call.bundleID, privacy: .public)")
            saveCall()
        case .resumed(let call):
            let seconds = Int(Date().timeIntervalSince(call.startedAt))
            Self.log.log("resumed \(call.bundleID, privacy: .public) at \(seconds)s")
            saveCall()
        case let .ended(call, at):
            let seconds = Int(at.timeIntervalSince(call.startedAt))
            Self.log.log("ended \(call.bundleID, privacy: .public) after \(seconds)s")
            saveCall()
        case nil:
            unsavedSamples += 1
            if detector.call != nil, unsavedSamples >= Self.saveEvery { saveCall() }
            return
        }
        call = detector.call
        onChange?()
    }

    private static func isResume(_ change: CallDetector.Change?) -> Bool {
        if case .resumed = change { return true }
        return false
    }

    /// Writes the call in progress, or clears it when there is none.
    private func saveCall() {
        unsavedSamples = 0
        let defaults = UserDefaults.standard
        guard let snapshot = detector.snapshot(at: Date()),
              let data = try? JSONEncoder().encode(snapshot) else {
            defaults.removeObject(forKey: Self.savedCallKey)
            return
        }
        defaults.set(data, forKey: Self.savedCallKey)
    }

    private static func loadSavedCall() -> CallSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: savedCallKey) else { return nil }
        return try? JSONDecoder().decode(CallSnapshot.self, from: data)
    }

    /// Every app holding the microphone right now, ours excluded.
    private func micUsers() -> [MicUser] {
        let objects = AudioProcesses.objects()
        guard !objects.isEmpty else { return [] }
        let running = NSWorkspace.shared.runningApplications
        let bundleIDs = running.compactMap(\.bundleIdentifier)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Grouped by app, because a call is often two processes — a browser
        // helper on the mic and another playing — and it is the APP that is
        // on the call, so "playing" is true if any of its processes plays.
        var apps: [String: (name: String, input: Bool, output: Bool)] = [:]
        for object in objects {
            let input = AudioProcesses.bool(object, kAudioProcessPropertyIsRunningInput)
            let output = AudioProcesses.bool(object, kAudioProcessPropertyIsRunningOutput)
            guard input || output, let pid = AudioProcesses.pid(object), pid != ownPID else { continue }
            let processBundle = AudioProcesses.string(object, kAudioProcessPropertyBundleID)

            let bundleID: String, name: String
            if let processBundle, let callApp = CallDetector.callApp(forDaemon: processBundle) {
                bundleID = callApp
                name = "FaceTime"
            } else if let app = AudioProcesses.owner(of: pid, bundleID: processBundle,
                                                     running: running, bundleIDs: bundleIDs),
                      app.activationPolicy == .regular,
                      let id = app.bundleIdentifier,
                      !AppMix.isSystemProcess(bundleID: id) {
                bundleID = id
                name = app.localizedName ?? id
            } else {
                if input, let processBundle, reportedUnowned.insert(processBundle).inserted {
                    Self.log.log("mic held by unowned \(processBundle, privacy: .public)")
                }
                continue
            }
            var entry = apps[bundleID] ?? (name, false, false)
            entry.input = entry.input || input
            entry.output = entry.output || output
            apps[bundleID] = entry
        }
        return apps.filter(\.value.input).map {
            MicUser(bundleID: $0.key, name: $0.value.name, playing: $0.value.output)
        }
    }
}
