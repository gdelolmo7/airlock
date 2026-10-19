import AirlockCore
import CryptoKit
import Foundation
import Observation
import Synchronization

/// Brings the voice model to a Mac on Plus or Pro by itself, once
/// (`CallVoiceModel`, `PlanLimits.tellsVoicesApart`).
///
/// **From useairlock.app, the app's own site**, in pieces of at most
/// `pieceSize`: a file there can be 25 MiB at most, and the model's weights
/// are 95. Every file is checked against the size and SHA-256 written in the
/// app, so a piece changed on the way, or a page served in place of one, is
/// refused rather than run. Nothing is sent but the request itself: no key,
/// no plan, nothing about a call. The privacy page lists it.
///
/// **Only when it will be used**: on Plus or Pro, with call notes and "Tell
/// voices apart" on, and never while a call is being written down. Never
/// over a metered or Low Data network by itself; "Try again" in Settings is
/// somebody asking, so that one may.
///
/// Built in a folder beside the model's and moved in whole, so a download
/// that stops halfway never leaves a model that half loads. The files it
/// finished are kept there for the next try.
@MainActor @Observable
final class CallVoiceDownload {
    static let shared = CallVoiceDownload()

    enum State: Equatable {
        /// Not needed, or not started yet.
        case idle
        /// How much has come, 0 to 1.
        case downloading(Double)
        /// The last try failed. Airlock tries again by itself later.
        case failed
        /// The model is here.
        case ready
    }

    private(set) var state: State = .idle

    /// One file of the model: where it goes under the model's folder, and
    /// what it must be.
    struct File: Equatable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    /// Fetches one address into a temporary file the caller then owns,
    /// saying how many bytes have come so far. `allowsMetered` lets it use a
    /// metered or Low Data network. The network in the app, a stand-in in
    /// tests, which never reach it.
    typealias Fetch = @Sendable (_ url: URL, _ allowsMetered: Bool,
                                 _ onBytes: @escaping @Sendable (Int64) -> Void) async throws -> URL

    /// Where the model comes from. Each file sits under it at its own path,
    /// a big one as `<path>.part1`, `<path>.part2`…
    nonisolated static let source = URL(string: "https://useairlock.app/downloads/voices/\(CallVoiceModel.preset)/")!
    /// The size of a piece: Pages' 25 MiB ceiling, with room to spare.
    nonisolated static let pieceSize = 20 * 1024 * 1024
    /// The whole model in megabytes, to the nearest ten, as Settings says it.
    nonisolated static var megabytes: Int {
        let bytes = CallVoiceModel.files.reduce(0) { $0 + $1.size }
        return Int((Double(bytes) / 1_000_000 / 10).rounded()) * 10
    }
    /// How long after a failed try the next one starts, while the app runs.
    static let retryAfter: Duration = .seconds(60 * 60)
    /// How long the first look waits after launch, so it never competes with
    /// it, and how often a download held back by a call looks again.
    static let settleFor: Duration = .seconds(30)

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let files: [File]
    @ObservationIgnored private let source: URL
    @ObservationIgnored private let pieceSize: Int
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let isWanted: @MainActor () -> Bool
    /// Whether a call is being written down, which holds a download back.
    /// Wired by the app delegate.
    @ObservationIgnored var isBusy: @MainActor () -> Bool
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private let verified: @MainActor () async -> Void
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var waiting: Task<Void, Never>?

    /// `isWanted`: whether this Mac should have the model now. `verified`
    /// tells the model its files were just checked, so its first load
    /// needn't check them again.
    init(folder: URL = CallVoiceModel.folder,
         files: [File] = CallVoiceModel.files.map { File(path: $0.path, size: $0.size, sha256: $0.sha256) },
         source: URL = CallVoiceDownload.source,
         pieceSize: Int = CallVoiceDownload.pieceSize,
         fetch: @escaping Fetch = CallVoiceDownload.network,
         isWanted: @escaping @MainActor () -> Bool = CallVoiceDownload.wantedNow,
         isBusy: @escaping @MainActor () -> Bool = { false },
         log: @escaping @MainActor (String) -> Void = MeetingDiagnostics.log,
         verified: @escaping @MainActor () async -> Void = CallVoiceModel.markVerified) {
        self.folder = folder
        self.files = files
        self.source = source
        self.pieceSize = pieceSize
        self.fetch = fetch
        self.isWanted = isWanted
        self.isBusy = isBusy
        self.log = log
        self.verified = verified
        if Self.isInstalled(files, in: folder) { state = .ready }
    }

    /// On Plus or Pro, with call notes and "Tell voices apart" on.
    static func wantedNow() -> Bool {
        CloudNotesService.shared.plan().limits.tellsVoicesApart && MeetingNotesModel.isOn
            && CallVoiceModel.isSwitchedOn()
    }

    /// Looks again in a moment: after launch, after a plan change. Nothing
    /// happens unless this Mac should have the model and doesn't.
    func startSoon() {
        guard running == nil, waiting == nil, !isHere else { return }
        wait(Self.settleFor)
    }

    /// Starts now if this Mac should have the model and doesn't. `asked` is
    /// somebody pressing "Try again", which may use a metered network.
    func startIfWanted(asked: Bool = false) {
        if isHere {
            state = .ready
            return
        }
        guard running == nil, isWanted() else { return }
        if !asked, isBusy() {
            wait(Self.settleFor)
            return
        }
        waiting?.cancel()
        waiting = nil
        state = .downloading(0)
        running = Task { [weak self] in
            await self?.run(allowsMetered: asked)
            self?.running = nil
        }
    }

    /// Settles a run for tests.
    func finish() async {
        await running?.value
    }

    private var isHere: Bool { Self.isInstalled(files, in: folder) }

    private func wait(_ duration: Duration) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.waiting = nil
            self.startIfWanted()
        }
    }

    // MARK: - One run

    private func run(allowsMetered: Bool) async {
        let staging = folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent + "-download", isDirectory: true)
        let total = Double(files.reduce(0) { $0 + $1.size })
        log("voices: downloading the model, \(Int(total / 1_000_000)) MB")
        let started = Date()
        var finished = 0
        do {
            for file in files {
                let target = staging.appendingPathComponent(file.path)
                if await Self.matches(target, file) {
                    finished += file.size
                    state = .downloading(Double(finished) / total)
                    continue
                }
                let before = finished
                let shown = Shown()
                try await fetchFile(file, to: target, allowsMetered: allowsMetered) { [weak self] bytes in
                    let fraction = Double(before + Int(bytes)) / total
                    guard shown.isNewStep(fraction) else { return }
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(min(fraction, 1))
                    }
                }
                guard await Self.matches(target, file) else {
                    try? FileManager.default.removeItem(at: target)
                    throw Failure.notTheModel(file.path)
                }
                finished += file.size
                state = .downloading(Double(finished) / total)
            }
            try Self.install(staging, as: folder)
            await verified()
            state = .ready
            log(String(format: "voices: model downloaded and checked in %.0f s", Date().timeIntervalSince(started)))
        } catch {
            state = .failed
            log("voices: download failed (\(Self.describe(error))), trying again in an hour")
            wait(Self.retryAfter)
        }
    }

    /// Fetches `file` piece by piece into `<target>.partial`, then puts it
    /// at `target`. `onBytes` hears the bytes of this file so far.
    private func fetchFile(_ file: File, to target: URL, allowsMetered: Bool,
                           onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let partial = target.appendingPathExtension("partial")
        try await Self.offMain {
            let manager = FileManager.default
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: partial)
            guard manager.createFile(atPath: partial.path, contents: nil) else { throw Failure.cannotWrite }
        }
        var written: Int64 = 0
        for url in Self.pieces(of: file, from: source, pieceSize: pieceSize) {
            let base = written
            let piece = try await fetch(url, allowsMetered) { bytes in onBytes(base + bytes) }
            written += try await Self.offMain { try Self.append(piece, to: partial) }
        }
        try await Self.offMain {
            let manager = FileManager.default
            try? manager.removeItem(at: target)
            try manager.moveItem(at: partial, to: target)
        }
    }

    // MARK: - Files

    /// Every address `file` comes from: itself, or its pieces in order.
    nonisolated static func pieces(of file: File, from source: URL, pieceSize: Int = pieceSize) -> [URL] {
        let whole = source.appendingPathComponent(file.path)
        guard file.size > pieceSize else { return [whole] }
        let count = (file.size + pieceSize - 1) / pieceSize
        return (1...count).map {
            whole.deletingLastPathComponent().appendingPathComponent(whole.lastPathComponent + ".part\($0)")
        }
    }

    /// Every file present at its size. Cheap; the hashes are checked as each
    /// file comes, and once a launch before the model runs.
    nonisolated static func isInstalled(_ files: [File], in folder: URL) -> Bool {
        files.allSatisfy { size(of: folder.appendingPathComponent($0.path)) == $0.size }
    }

    /// Whether the file at `url` is `file`: its size, then its hash.
    nonisolated static func matches(_ url: URL, _ file: File) async -> Bool {
        guard size(of: url) == file.size else { return false }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
        }.value
    }

    private nonisolated static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    /// Adds the piece at `piece` to the end of `file` and deletes the piece.
    /// Returns its length.
    private nonisolated static func append(_ piece: URL, to file: URL) throws -> Int64 {
        defer { try? FileManager.default.removeItem(at: piece) }
        let data = try Data(contentsOf: piece, options: .mappedIfSafe)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return Int64(data.count)
    }

    /// Moves the finished model in whole, over whatever half a copy was there.
    nonisolated static func install(_ staging: URL, as folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: folder.path) {
            _ = try manager.replaceItemAt(folder, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: folder)
        }
    }

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try work() }.value
    }

    // MARK: - Why

    enum Failure: Error, Equatable {
        /// The server answered with something other than the file.
        case status(Int)
        /// A file came whole but is not the one the app knows.
        case notTheModel(String)
        case cannotWrite
        case empty
    }

    /// For meetings.log: a reason, never an address with anything in it.
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let failure as Failure:
            switch failure {
            case let .status(code): "the server said \(code)"
            case let .notTheModel(path): "\((path as NSString).lastPathComponent) did not match"
            case .cannotWrite: "couldn't write it"
            case .empty: "nothing came"
            }
        case let error as URLError:
            switch error.networkUnavailableReason {
            case .expensive?: "waiting for a network that isn't metered"
            case .constrained?: "waiting for a network without Low Data Mode"
            default: "network \(error.code.rawValue)"
            }
        default:
            "\(type(of: error))"
        }
    }

    /// Whether a fraction is a new whole percent, so the bar moves smoothly
    /// without a redraw for every few kilobytes.
    private final class Shown: Sendable {
        private let step = Mutex(-1)

        func isNewStep(_ fraction: Double) -> Bool {
            let now = Int(fraction * 100)
            return step.withLock { step in
                guard now != step else { return false }
                step = now
                return true
            }
        }
    }

    // MARK: - The network

    /// One address into a temporary file. Nothing kept on disk: no cache, no
    /// cookies.
    nonisolated static let network: Fetch = { url, allowsMetered, onBytes in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.allowsExpensiveNetworkAccess = allowsMetered
        configuration.allowsConstrainedNetworkAccess = allowsMetered
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        let fetcher = PieceFetcher(onBytes: onBytes)
        let session = URLSession(configuration: configuration, delegate: fetcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await fetcher.fetch(url, in: session)
    }
}

/// One download task, told as an `async` call with its progress. The
/// session's delegate queue and the caller share only `waiting`, behind its
/// lock.
private final class PieceFetcher: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct Waiting {
        var continuation: CheckedContinuation<URL, Error>?
        /// The file moved out of the session's hands, or why there is none.
        var kept: Result<URL, Error>?
    }

    private let onBytes: @Sendable (Int64) -> Void
    private let waiting = Mutex(Waiting())

    init(onBytes: @escaping @Sendable (Int64) -> Void) {
        self.onBytes = onBytes
    }

    func fetch(_ url: URL, in session: URLSession) async throws -> URL {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The file is deleted once this returns, so it moves now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let kept: Result<URL, Error>
        if status == 200 {
            let moved = FileManager.default.temporaryDirectory
                .appendingPathComponent("airlock-voices-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: moved)
                kept = .success(moved)
            } catch {
                kept = .failure(error)
            }
        } else {
            kept = .failure(CallVoiceDownload.Failure.status(status))
        }
        waiting.withLock { $0.kept = kept }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, kept) = waiting.withLock { waiting in
            defer { waiting = Waiting() }
            return (waiting.continuation, waiting.kept)
        }
        let result: Result<URL, Error>
        if let error {
            if case let .success(moved)? = kept { try? FileManager.default.removeItem(at: moved) }
            result = .failure(error)
        } else {
            result = kept ?? .failure(CallVoiceDownload.Failure.empty)
        }
        continuation?.resume(with: result)
    }
}
