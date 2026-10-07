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
    @ObservationIgnored private var samplesSinceSiteCheck = 0
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
    private static let siteCheckEvery = 5

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
            refreshSiteIfDue()
            return
        }
        call = detector.call
        samplesSinceSiteCheck = 0
        if let current = call { call?.site = Self.site(of: current) }
        onChange?()
    }

    /// Looks again every few seconds until the call's site is known, because
    /// the first look can come before Meet has titled its tab, or while its
    /// tab is behind another. Once known it STAYS for the rest of the call:
    /// the Meet tab going behind another tab changes its window's title, not
    /// the call, which is still the same microphone hold.
    private func refreshSiteIfDue() {
        guard let current = call, current.site == nil else { return }
        samplesSinceSiteCheck += 1
        guard samplesSinceSiteCheck >= Self.siteCheckEvery else { return }
        samplesSinceSiteCheck = 0
        guard let site = Self.site(of: current) else { return }
        Self.log.log("site \(site.rawValue, privacy: .public)")
        call?.site = site
    }

    /// The service a browser call is on, read from the browser's window
    /// titles: the Mac reports a Meet call as Chrome holding the microphone,
    /// and only the tab's title says Meet. Needs Accessibility, which
    /// dictation's typing already asks for; without it the browser's own logo
    /// shows. Every window is read, but only the tab showing in each has a
    /// title, so a Meet tab behind another tab is found only once it has been
    /// seen (see `refreshSiteIfDue`). Titles are never logged: a meeting's
    /// name can be in one.
    private static func site(of call: OngoingCall) -> MeetingLink.Provider? {
        guard CallGlyph.isBrowser(call.bundleID), AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: call.bundleID).first
        else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung browser must not hang the notch: Accessibility waits 6 s by default.
        AXUIElementSetMessagingTimeout(element, 0.25)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        let titles = list.compactMap { window -> String? in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
            else { return nil }
            return title as? String
        }
        return CallGlyph.site(inWindowTitles: titles)
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
