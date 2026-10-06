import AirlockCore
import AppKit
import AVFoundation
import EventKit
import Foundation

/// Gathers the facts `DiagnosticsFormatter` prints.
///
/// Everything here is a question to macOS or to a model — no formatting, no
/// decisions. The decisions are in Core, where they can be read in a test, and
/// this file exists only because none of these questions can be asked from
/// there: EventKit, AVFoundation, the Accessibility API, `NSScreen` and
/// `sysctl` are all off limits to a UI-free, testable target.
///
/// **Nothing secret can be added here by accident**: `DiagnosticsReport` has
/// nowhere to put a key, a token, a path or a session name.
@MainActor
enum SupportDiagnostics {

    static func report(settings: SettingsModel,
                       updater: UpdaterModel,
                       license: LicenseModel,
                       widgets: [DiagnosticsReport.WidgetState]) -> DiagnosticsReport {
        DiagnosticsReport(
            version: settings.versionLabel,
            macOS: systemVersion(),
            hardware: hardwareModel(),
            hasNotch: NotchScreen.physicallyNotched != nil,
            displayCount: NSScreen.screens.count,
            permissions: permissions(),
            hooks: settings.agents.map { .init($0.name, .init($0.status)) },
            updater: updaterState(updater),
            license: .init(license.entitlement),
            widgets: widgets,
            // Not a permission and not a setting of ours — a fact about the
            // session that silently disables chord detection. See `SecureInput`.
            secureInput: SecureInput.state())
    }

    // MARK: - Permissions

    /// The three macOS will answer, and the one it will not.
    ///
    /// **Screen recording appears only while the guide is turned on.** The
    /// guide (`GuideCapture`) is the one thing in the app that captures a
    /// window, and it is off unless someone switched it on in a hidden
    /// setting. For everybody else a row would be a fact about a permission
    /// the app does not use — and a reader who saw it denied would go and
    /// grant something for nothing.
    ///
    /// Audio capture is what people mistake for it. That one is real (the wave
    /// tap and per-app volume both need it) and macOS exposes no way to read it
    /// short of creating a tap, so it is reported as what it is rather than
    /// guessed at.
    private static func permissions() -> [DiagnosticsReport.Permission] {
        var permissions: [DiagnosticsReport.Permission] = [
            .init("Calendar", calendarState()),
            .init("Microphone", microphoneState()),
            .init("Accessibility", TypeService.isTrusted ? .allowed : .notAllowed),
            // Separate from Accessibility because it IS separate, and a support
            // report that conflated them would reproduce the confusion it exists
            // to shorten: a dead dictation key with Accessibility allowed is the
            // exact pair of facts that took a day to tell apart.
            .init("Input monitoring", inputMonitoringPermission()),
            .init("Audio capture", .asksOnFirstUse),
        ]
        #if AIRLOCK_GUIDE
        if GuideSwitch.isOn {
            permissions.append(.init("Screen recording (guide)", GuideCapture.isPermitted ? .allowed : .notAllowed))
        }
        #endif
        return permissions
    }

    /// The two states the Permissions pane has to draw differently.
    ///
    /// `restricted` is an administrator's decision, not the user's: a profile on
    /// the Mac blocks it, and every button this app could offer would do
    /// nothing. Exposed so the pane can say that instead of showing a Grant
    /// button that cannot work.
    static func calendarPermission() -> DiagnosticsReport.PermissionState { calendarState() }
    static func microphonePermission() -> DiagnosticsReport.PermissionState { microphoneState() }

    /// On file is not the same as working: a record left by an earlier,
    /// differently signed Airlock reads as granted while the taps it should
    /// feed stay inert. No tap at all (dictation off) proves nothing either
    /// way, so it keeps what macOS has on file.
    static func inputMonitoringPermission() -> DiagnosticsReport.PermissionState {
        guard InputMonitoring.isGranted else { return .notAllowed }
        if case .inert = HoldKeyMonitor.health() { return .notWorking }
        return .allowed
    }

    private static func calendarState() -> DiagnosticsReport.PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .allowed
        case .denied: return .notAllowed
        case .restricted: return .restricted
        case .notDetermined: return .notAsked
        // Write-only, and whatever a later macOS adds. Not enough to read a
        // calendar with, so it is not "allowed" for anything Airlock does.
        default: return .notAllowed
        }
    }

    private static func microphoneState() -> DiagnosticsReport.PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .denied: return .notAllowed
        case .restricted: return .restricted
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    // MARK: - Updater

    /// Bundled, and given both halves at packaging. Either key missing means the
    /// build shipped without an updater on purpose — `package-app.sh` says so
    /// and moves on — and that is a different answer from one that is failing.
    private static func updaterState(_ updater: UpdaterModel) -> DiagnosticsReport.UpdaterState {
        guard updater.isAvailable else { return .notBundled }
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard feed?.isEmpty == false, key?.isEmpty == false else { return .notConfigured }
        return .configured(automaticChecks: updater.checksAutomatically)
    }

    // MARK: - The machine

    /// "15.3.1 (24D70)". The build number is the half that identifies a specific
    /// macOS, and `operatingSystemVersion` alone does not carry it.
    private static func systemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var number = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { number += ".\(version.patchVersion)" }
        let build = sysctlString("kern.osversion")
        return build.isEmpty ? number : "\(number) (\(build))"
    }

    /// `hw.model` — "Mac16,7". Which Mac, not whose.
    private static func hardwareModel() -> String {
        let model = sysctlString("hw.model")
        return model.isEmpty ? "unknown" : model
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
