import CryptoKit
import Foundation
import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// The voice model's download on Plus and Pro (`CallVoiceDownload`): pieces
/// joined in order, every file checked before it is used, files already
/// fetched kept, and nothing started when it isn't wanted or while a call is
/// being written down. A stand-in network and a temporary folder: nothing
/// here reaches the internet or the real model's folder.
@MainActor
final class CallVoiceDownloadTests: XCTestCase {
    private var root: URL!
    private let source = URL(string: "https://example.invalid/voices/test/")!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlock-voice-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: URL { root.appendingPathComponent("voices", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("voices-download", isDirectory: true) }

    // MARK: - A pretend model and server

    /// Two files: one big enough to come in three pieces of 4 bytes, one
    /// small, in a folder of its own.
    private let weights = Data("0123456789".utf8)
    private let small = Data("tiny".utf8)

    private func file(_ path: String, _ data: Data) -> CallVoiceDownload.File {
        CallVoiceDownload.File(path: path, size: data.count,
                               sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private var files: [CallVoiceDownload.File] {
        [file("model/weights.bin", weights), file("small.bin", small)]
    }

    /// What the server holds, by address, and what it was asked for.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: Data] = [:]
        private var asked: [(url: String, metered: Bool)] = []

        init(_ held: [String: Data]) { self.held = held }

        var requests: [String] { lock.withLock { asked.map(\.url) } }
        var metered: [Bool] { lock.withLock { asked.map(\.metered) } }

        func fetch(_ url: URL, _ metered: Bool, _ onBytes: @Sendable (Int64) -> Void) throws -> URL {
            let data = try lock.withLock { () throws -> Data in
                asked.append((url.absoluteString, metered))
                guard let data = held[url.absoluteString] else { throw CallVoiceDownload.Failure.status(404) }
                return data
            }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("airlock-voice-piece-\(UUID().uuidString)")
            try data.write(to: out)
            onBytes(Int64(data.count))
            return out
        }
    }

    /// The pretend model as the website would serve it: the weights in
    /// pieces of 4 bytes, the small file whole.
    private func server(weights: Data? = nil) -> Server {
        let weights = weights ?? self.weights
        return Server([
            source.absoluteString + "model/weights.bin.part1": weights.prefix(4),
            source.absoluteString + "model/weights.bin.part2": weights.dropFirst(4).prefix(4),
            source.absoluteString + "model/weights.bin.part3": weights.dropFirst(8),
            source.absoluteString + "small.bin": small,
        ])
    }

    private func download(_ server: Server, wanted: Bool = true, busy: Bool = false,
                          log: @escaping @MainActor (String) -> Void = { _ in }) -> CallVoiceDownload {
        CallVoiceDownload(folder: folder, files: files, source: source, pieceSize: 4,
                          fetch: { url, metered, onBytes in try server.fetch(url, metered, onBytes) },
                          isWanted: { wanted }, isBusy: { busy }, log: log, verified: {})
    }

    // MARK: - Pieces

    func testABigFileComesInNumberedPiecesAndASmallOneWhole() {
        let big = CallVoiceDownload.File(path: "a/weight.bin", size: 2 * CallVoiceDownload.pieceSize + 1,
                                         sha256: "")
        XCTAssertEqual(CallVoiceDownload.pieces(of: big, from: source).map(\.absoluteString), [
            source.absoluteString + "a/weight.bin.part1",
            source.absoluteString + "a/weight.bin.part2",
            source.absoluteString + "a/weight.bin.part3",
        ])
        let exact = CallVoiceDownload.File(path: "b.bin", size: CallVoiceDownload.pieceSize, sha256: "")
        XCTAssertEqual(CallVoiceDownload.pieces(of: exact, from: source).map(\.absoluteString),
                       [source.absoluteString + "b.bin"], "a file of exactly one piece comes whole")
    }

    /// The real model: its weights in five pieces, each under the website's
    /// 25 MiB ceiling, the rest whole. The website's folder has to match.
    func testTheRealModelsWeightsComeInFivePieces() {
        let pieces = CallVoiceModel.files.map {
            CallVoiceDownload.pieces(of: CallVoiceDownload.File(path: $0.path, size: $0.size, sha256: $0.sha256),
                                     from: CallVoiceDownload.source)
        }
        XCTAssertEqual(pieces.map(\.count), [5, 1, 1, 1, 1, 1])
        XCTAssertLessThan(CallVoiceDownload.pieceSize, 25 * 1024 * 1024)
        XCTAssertEqual(CallVoiceDownload.source.host, "useairlock.app")
        XCTAssertTrue(CallVoiceDownload.source.path.contains(CallVoiceModel.preset))
    }

    func testSettingsSaysAbout100MB() {
        XCTAssertEqual(CallVoiceDownload.megabytes, 100)
    }

    // MARK: - A run

    func testPiecesAreJoinedCheckedAndMovedInWhole() async throws {
        let server = server()
        let download = download(server)
        download.startIfWanted()
        XCTAssertEqual(download.state, .downloading(0))
        await download.finish()

        XCTAssertEqual(download.state, .ready)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("model/weights.bin")), weights)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("small.bin")), small)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the staging folder became the model")
        XCTAssertEqual(server.requests.count, 4)
        XCTAssertEqual(server.metered, [false, false, false, false], "never a metered network by itself")
    }

    func testAFileThatDoesNotMatchIsRefusedAndNothingIsInstalled() async {
        var said: [String] = []
        let download = download(server(weights: Data("0123456780".utf8))) { said.append($0) }
        download.startIfWanted()
        await download.finish()

        XCTAssertEqual(download.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("model/weights.bin").path),
                       "the wrong file isn't kept for the next try")
        XCTAssertTrue(said.contains { $0.contains("weights.bin did not match") }, "\(said)")
    }

    func testAServerErrorFailsAndSaysSo() async {
        var said: [String] = []
        let download = download(Server([:])) { said.append($0) }
        download.startIfWanted()
        await download.finish()

        XCTAssertEqual(download.state, .failed)
        XCTAssertTrue(said.contains { $0.contains("the server said 404") }, "\(said)")
        XCTAssertTrue(said.allSatisfy { !$0.contains("example.invalid") }, "the log never carries an address")
    }

    func testFilesFinishedBeforeAreNotFetchedAgain() async throws {
        let kept = staging.appendingPathComponent("model/weights.bin")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try weights.write(to: kept)
        let server = server()
        let download = download(server)
        download.startIfWanted()
        await download.finish()

        XCTAssertEqual(download.state, .ready)
        XCTAssertEqual(server.requests, [source.absoluteString + "small.bin"])
    }

    func testAHalfCopyIsReplacedInWhole() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("small.bin"))
        try Data("left over".utf8).write(to: folder.appendingPathComponent("stray.bin"))
        let download = download(server())
        download.startIfWanted()
        await download.finish()

        XCTAssertEqual(download.state, .ready)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("small.bin")), small)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stray.bin").path))
    }

    // MARK: - When it starts

    func testAModelAlreadyHereIsReadyAndFetchesNothing() async throws {
        for (file, data) in zip(files, [weights, small]) {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let server = server()
        let download = download(server)
        XCTAssertEqual(download.state, .ready)
        download.startIfWanted(asked: true)
        await download.finish()
        XCTAssertEqual(server.requests, [])
    }

    func testNothingStartsWhenItIsNotWanted() async {
        let server = server()
        let download = download(server, wanted: false)
        download.startIfWanted()
        download.startIfWanted(asked: true)
        await download.finish()
        XCTAssertEqual(download.state, .idle)
        XCTAssertEqual(server.requests, [])
    }

    func testACallBeingWrittenDownHoldsItBackUnlessSomebodyAsks() async {
        let server = server()
        let download = download(server, busy: true)
        download.startIfWanted()
        await download.finish()
        XCTAssertEqual(download.state, .idle, "held back while notes are taken")
        XCTAssertEqual(server.requests, [])

        download.startIfWanted(asked: true)
        await download.finish()
        XCTAssertEqual(download.state, .ready)
        XCTAssertEqual(Set(server.metered), [true], "Try again may use a metered network")
    }

    // MARK: - The plan

    func testFreeNeverUsesTheModel() throws {
        let settings = try XCTUnwrap(UserDefaults(suiteName: "airlock-tests-voices-\(UUID().uuidString)"))
        settings.set(true, forKey: CallVoiceModel.enabledKey)
        XCTAssertFalse(CallVoiceModel.isOn(for: .free, in: settings))
        XCTAssertFalse(CallVoiceModel.isOn(for: PlanSnapshot(plan: .free, isPaid: true), in: settings))
    }

    func testTheSwitchIsOnUntilTurnedOff() throws {
        let settings = try XCTUnwrap(UserDefaults(suiteName: "airlock-tests-voices-\(UUID().uuidString)"))
        XCTAssertTrue(CallVoiceModel.isSwitchedOn(in: settings))
        settings.set(false, forKey: CallVoiceModel.enabledKey)
        XCTAssertFalse(CallVoiceModel.isSwitchedOn(in: settings))
        XCTAssertFalse(CallVoiceModel.isOn(for: PlanSnapshot(plan: .pro, isPaid: true), in: settings))
    }
}
