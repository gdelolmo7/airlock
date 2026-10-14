import AirlockCore
import Foundation
import Observation

/// What starts and stops the crash handler. `SentryCrashEngine` in the app,
/// a fake in the tests, so the rules in `CrashReporter` are tested without a
/// crash handler loose in the test process.
@MainActor
protocol CrashReportEngine: AnyObject {
    func start(dsn: String)
    func stop()
}

/// Crash reports, sent only after the person says yes.
///
/// **Off until they do.** The answer is a preference (`consentKey`), asked
/// for in three places: a switch on the last step of setup, a switch on
/// General in Settings, and once in the notch after a run that ended
/// unexpectedly (`hasQuestionWaiting`). Turning it off closes the crash
/// handler on the spot and removes any report not sent yet.
///
/// **Nothing starts without a DSN either.** The packaging script writes one
/// into the bundle only when it is given one (`dsnKey`), so `swift run`, the
/// tests, a development package and the public source never start the
/// handler and never show the question or the switch (`isAvailable`).
///
/// **The crash that prompts the question is not in a report.** With the
/// answer off the handler was not running, so it wrote nothing down. macOS
/// keeps its own report of it, which is the person's to send to Apple; this
/// does not go looking for it. Saying yes covers the next one.
@MainActor
@Observable
final class CrashReporter {
    static let shared = CrashReporter()

    /// The Info.plist key the packaging script writes the DSN under.
    nonisolated static let dsnKey = "ALSentryDSN"
    /// The person's answer. Absent is no.
    nonisolated static let consentKey = "crashReports.enabled"
    /// The question after an unexpected quit has been put, so it is not again.
    nonisolated static let askedKey = "crashReports.askedAfterQuit"
    /// A run ended unexpectedly and the question has not been put yet. Kept
    /// across launches, because the launch that notices may not have the
    /// panel to itself (setup or a new version's card can have it).
    nonisolated static let waitingKey = "crashReports.questionWaiting"

    /// The DSN this build carries, if it is one to start with. Nonisolated
    /// so Settings search can ask from anywhere.
    nonisolated static var bundleDSN: String? {
        CrashReportPolicy.usableDSN(Bundle.main.object(forInfoDictionaryKey: dsnKey),
                                    isBundled: AppBundle.isBundled)
    }

    /// The build could send a report: it carries a DSN. When false nothing
    /// here does anything and no surface offers the choice.
    let isAvailable: Bool

    /// The crash handler is running now.
    private(set) var isRunning = false

    /// The person's answer. Setting it saves it and starts or stops the
    /// handler at once.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            // A build that cannot send keeps no answer: the switch is not
            // shown there, and a "yes" saved by a development copy would be
            // read by the installed one if they shared a domain.
            guard isAvailable else { return }
            defaults.set(isEnabled, forKey: Self.consentKey)
            if isEnabled { defaults.removeObject(forKey: Self.waitingKey) }
            apply()
        }
    }

    @ObservationIgnored private let dsn: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine: CrashReportEngine
    @ObservationIgnored private let marker: CleanExitMarker
    @ObservationIgnored private var launched = false

    init(dsn: String?, defaults: UserDefaults, engine: CrashReportEngine, marker: CleanExitMarker) {
        self.dsn = dsn
        self.defaults = defaults
        self.engine = engine
        self.marker = marker
        isAvailable = dsn != nil
        isEnabled = dsn != nil && defaults.bool(forKey: Self.consentKey)
    }

    /// The app's own: the bundle's DSN, the real defaults, Sentry, and the
    /// marker next to the app's other files. Building it starts nothing.
    convenience init() {
        self.init(dsn: Self.bundleDSN, defaults: .standard,
                  engine: SentryCrashEngine(), marker: .standard)
    }

    /// At launch. Notes whether the last run ended the way a run should,
    /// and starts the handler if the person said yes. Once per run.
    func launch() {
        guard isAvailable, !launched else { return }
        launched = true
        let unexpected = marker.beginRun()
        if CrashReportPolicy.asksAfterUnexpectedQuit(
            available: isAvailable, consent: isEnabled,
            alreadyAsked: defaults.bool(forKey: Self.askedKey),
            lastRunEndedUnexpectedly: unexpected) {
            defaults.set(true, forKey: Self.waitingKey)
        }
        apply()
    }

    /// At a normal quit: the next launch will not count this run as one that
    /// went wrong.
    func noteCleanExit() {
        guard launched else { return }
        marker.endRun()
    }

    /// The notch has a question to put: a run ended unexpectedly, the answer
    /// is still off, and nobody has been asked yet.
    var hasQuestionWaiting: Bool {
        isAvailable && !isEnabled
            && defaults.bool(forKey: Self.waitingKey)
            && !defaults.bool(forKey: Self.askedKey)
    }

    /// The question is on screen. It counts as asked from now, answered or
    /// not: closing the card is an answer too.
    func questionShown() {
        defaults.set(true, forKey: Self.askedKey)
        defaults.removeObject(forKey: Self.waitingKey)
    }

    /// Starts or stops the handler to match the answer.
    private func apply() {
        let shouldRun = CrashReportPolicy.shouldRun(dsn: dsn, consent: isEnabled)
        if shouldRun, !isRunning, launched, let dsn {
            engine.start(dsn: dsn)
            isRunning = true
        } else if !shouldRun, isRunning {
            engine.stop()
            isRunning = false
        }
    }
}
