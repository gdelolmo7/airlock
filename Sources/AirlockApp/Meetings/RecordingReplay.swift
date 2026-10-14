import AirlockCore
import Foundation

/// "Add a recording" from the command line (`RecordingReader`), for judging
/// the notes against a real meeting without the window: the owner's
/// languages and voice switch, read from the app's own settings.
///
/// Reached only from `--notes-from-recording <file>` (with `--speed` and
/// `--started`), and gone before the app starts: nothing listens, no socket
/// is opened. The meeting is written into the meetings folder like any
/// other, so the running app lists it.
@MainActor
enum RecordingReplay {
    struct Request {
        let file: URL
        /// Times the speed it was said at.
        let speed: Double
        /// When the meeting began; the recording's own date when not given.
        let startedAt: Date?
    }

    static func requested(in arguments: [String] = CommandLine.arguments) -> Request? {
        guard let flag = arguments.firstIndex(of: "--notes-from-recording"),
              arguments.index(after: flag) < arguments.endIndex else { return nil }
        let file = URL(fileURLWithPath: arguments[arguments.index(after: flag)])
        let speed = value(after: "--speed", in: arguments).flatMap(Double.init) ?? RecordingImport.speed
        let started = value(after: "--started", in: arguments).flatMap { try? Date($0, strategy: .iso8601) }
        return Request(file: file, speed: max(1, speed), startedAt: started)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex
        else { return nil }
        return arguments[arguments.index(after: index)]
    }

    /// Runs `request` and ends the process with its outcome.
    static func runAndExit(_ request: Request) -> Never {
        Task { @MainActor in
            exit(await run(request) ? 0 : 1)
        }
        dispatchMain()
    }

    private static func say(_ message: String) {
        print("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        fflush(stdout)
    }

    static func run(_ request: Request) async -> Bool {
        // The languages the owner's app would listen in, from its own settings.
        let settings = UserDefaults(suiteName: "com.airlock.app") ?? .standard
        let reader = RecordingReader(speed: request.speed, settings: settings, log: { say($0) })
        var stage: RecordingImport.Stage?
        var minutesSaid = 0
        reader.onProgress = { progress in
            if progress.stage != stage {
                stage = progress.stage
                say("\(progress.doing.lowercased()), \(progress.timeLeftShort)")
            }
            let minute = Int(progress.heard / 60)
            if minute >= minutesSaid + 5 {
                minutesSaid = minute
                say("… \(progress.heardWords)")
            }
        }
        reader.onFolder = { folder, _ in say("folder: \(folder.lastPathComponent)") }
        switch await reader.read(request.file, startedAt: request.startedAt) {
        case .saved(_, let record, let notes):
            say("saved: \(record.segments.count) lines, \(notes?.todos.count ?? 0) to-do(s)")
            return true
        case .stopped:
            return false
        case .failed(let reason):
            say(reason)
            return false
        }
    }
}
