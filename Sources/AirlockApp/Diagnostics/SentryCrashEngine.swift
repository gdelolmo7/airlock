import AirlockCore
import Darwin
import Foundation
import Sentry
import SystemConfiguration

/// The one file that talks to Sentry, and what it is told.
///
/// **Crashes and hangs, nothing else.** Sentry can also record what the app
/// was doing before a crash (breadcrumbs: clicks, network calls, log lines),
/// time how long things take, profile, count sessions, take screenshots and
/// send its own usage numbers. Every one of those is off below, and the
/// ones that work by swizzling are off at the root (`enableSwizzling`).
///
/// **Nothing personal, checked on the way out.** `sendDefaultPii` is off,
/// which is Sentry's own rule for not attaching a user, an IP address or
/// request details. Then every report passes through `scrub(_:with:)`
/// before it is sent: the Mac's name, the account name and home-folder
/// paths are replaced (`CrashReportScrubber`), the installation id Sentry
/// makes up for counting users is removed, and the facts about the machine
/// are cut down to the version, model and macOS. The server still sees the
/// address a report comes from, as any server does: the Sentry project's
/// "Prevent Storing of IP Addresses" setting is what keeps it from being
/// stored, and it has to be on. Sentry also looks that address up to note
/// the town, setting or not, unless the report already says where it comes
/// from; every report says "nowhere" (an empty place) so the lookup never
/// runs.
///
/// **Five a day at most** from one Mac (`CrashReportAllowance`), so a Mac
/// that crashes at every launch cannot use up the monthly allowance Airlock
/// shares with another app at Sentry.
///
/// **Hangs after five seconds.** Sentry's default is two, which a busy Mac
/// reaches by itself; five is long enough that a report means the app really
/// stopped answering. Hang reports go through the same scrubbing.
///
/// Uncaught Objective-C exceptions are left to AppKit, which logs and
/// carries on. Sentry would report them by telling AppKit to crash on them
/// instead, which would trade an app that survives for a report.
@MainActor
final class SentryCrashEngine: CrashReportEngine {
    /// Where Sentry keeps reports until they are sent: the app's own caches
    /// folder, not the `io.sentry` folder every other app using Sentry
    /// outside the App Store would share.
    nonisolated static var defaultCacheFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Airlock", isDirectory: true)
            .appendingPathComponent("CrashReports", isDirectory: true)
    }

    /// Seconds without an answer from the main thread before it is a hang.
    nonisolated static let hangThreshold: TimeInterval = 5

    private let cacheFolder: URL
    private let allowance: CrashReportAllowance

    init(cacheFolder: URL = SentryCrashEngine.defaultCacheFolder,
         allowance: CrashReportAllowance = CrashReportAllowance()) {
        self.cacheFolder = cacheFolder
        self.allowance = allowance
    }

    func start(dsn: String) {
        SentrySDK.start(options: Self.options(dsn: dsn, cacheFolder: cacheFolder,
                                              scrubber: Self.scrubberForThisMac(),
                                              allowance: allowance))
        // Sentry has just put its own handler on SIGPIPE. See `reclaim`.
        BrokenPipeGuard.reclaim()
    }

    /// Closes the handler now, without waiting for anything in flight, and
    /// removes reports not sent yet: off means nothing else leaves.
    ///
    /// Takes up to a second, on the main thread whichever thread calls it:
    /// Sentry closes on the main queue and waits there for its crash
    /// handler's background thread, which checks for the stop once a second.
    /// Measured at 1.0 s straight after a start. It happens only when the
    /// person turns the switch off, so it is left synchronous: "off" is then
    /// true by the time the switch has moved.
    func stop() {
        SentrySDK.close()
        try? FileManager.default.removeItem(at: cacheFolder)
    }

    /// Everything Sentry is told. Built outside the main actor on purpose:
    /// a closure made in a main-actor function is checked to run there, and
    /// Sentry calls `beforeSend` from whichever thread is sending.
    nonisolated static func options(dsn: String, cacheFolder: URL,
                                    scrubber: CrashReportScrubber,
                                    allowance: CrashReportAllowance) -> Options {
        let options = Options()
        options.dsn = dsn
        options.debug = false
        options.cacheDirectoryPath = cacheFolder.path
        // Closing is for "stop now", not for finishing a send.
        options.shutdownTimeInterval = 0

        // What it is for.
        options.enableCrashHandler = true
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = hangThreshold

        // Nothing personal by Sentry's own rule, then by ours, and no more
        // than the day's allowance.
        options.sendDefaultPii = false
        options.beforeSend = { event in
            allowance.take() ? scrub(event, with: scrubber) : nil
        }

        // No record of what happened before the crash.
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.maxBreadcrumbs = 0
        options.beforeBreadcrumb = { _ in nil }

        // No watching the app at work: no swizzling, tracing, profiling,
        // network capture, sessions, metrics, logs or usage counts.
        options.enableSwizzling = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        options.enableCaptureFailedRequests = false
        options.tracePropagationTargets = []
        options.tracesSampleRate = nil
        options.configureProfiling = nil
        options.enableAutoSessionTracking = false
        options.enableWatchdogTerminationTracking = false
        options.sendClientReports = false
        options.enableMetrics = false
        options.enableLogs = false
        options.enableMetricKit = false
        options.enableSpotlight = false

        // No memory contents beside the stack trace.
        options.enableMemoryIntrospection = false
        // See the type's comment.
        options.enableUncaughtNSExceptionReporting = false
        // A quit from outside is not a crash.
        options.enableSigtermReporting = false
        return options
    }

    /// The report as it may leave the Mac. See the type's comment.
    nonisolated static func scrub(_ event: Event, with scrubber: CrashReportScrubber) -> Event {
        event.serverName = nil
        // No one, from nowhere. Without a place of its own, a report gets
        // the town Sentry finds for the address it came from; an empty one
        // is kept as it is. Checked against Sentry itself: a report without
        // a user arrived with the town, one with this arrived without.
        let nobody = User()
        nobody.geo = Geo()
        event.user = nobody
        event.request = nil
        event.breadcrumbs = nil
        event.modules = nil
        event.transaction = nil
        event.context = scrubber.scrub(contexts: event.context)
        event.extra = event.extra.map { scrubber.scrub(dictionary: $0) }
        event.tags = event.tags?.mapValues { scrubber.scrub($0) }

        if let message = event.message {
            let scrubbed = SentryMessage(formatted: scrubber.scrub(message.formatted))
            scrubbed.message = message.message.map { scrubber.scrub($0) }
            scrubbed.params = message.params?.map { scrubber.scrub($0) }
            event.message = scrubbed
        }

        for exception in event.exceptions ?? [] {
            exception.value = exception.value.map { scrubber.scrub($0) }
            exception.type = exception.type.map { scrubber.scrub($0) }
            exception.module = exception.module.map { scrubber.scrub($0) }
            if let mechanism = exception.mechanism {
                mechanism.desc = mechanism.desc.map { scrubber.scrub($0) }
                mechanism.data = mechanism.data.map { scrubber.scrub(dictionary: $0) }
            }
            scrub(exception.stacktrace, with: scrubber)
        }

        for thread in event.threads ?? [] {
            thread.name = thread.name.map { scrubber.scrub($0) }
            scrub(thread.stacktrace, with: scrubber)
        }
        scrub(event.stacktrace, with: scrubber)

        // Where each library was loaded from: `/Users/<name>/Applications/…`
        // for an app kept in the home folder.
        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map { scrubber.scrub($0) }
        }
        return event
    }

    private nonisolated static func scrub(_ stacktrace: SentryStacktrace?, with scrubber: CrashReportScrubber) {
        for frame in stacktrace?.frames ?? [] {
            frame.package = frame.package.map { scrubber.scrub($0) }
            frame.fileName = frame.fileName.map { scrubber.scrub($0) }
            frame.function = frame.function.map { scrubber.scrub($0) }
            frame.module = frame.module.map { scrubber.scrub($0) }
            // Source lines and variables are never collected on a Mac app;
            // dropped anyway, so a future default cannot add them.
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }

    /// The names that identify this Mac and this person, read the cheap way.
    /// `Host.current()` and `ProcessInfo.hostName` can wait on the network to
    /// answer, which is the wrong thing to do at launch.
    nonisolated static func scrubberForThisMac() -> CrashReportScrubber {
        var computers: [String] = []
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            computers.append(name)
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            computers += [local, local + ".local"]
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            computers.append(host)
            if let first = host.split(separator: ".").first { computers.append(String(first)) }
        }
        return CrashReportScrubber(computerNames: computers,
                                   userNames: [NSUserName(), NSFullUserName()])
    }
}
