import AirlockCore
import AVFoundation
import Foundation
import Observation
import Speech

/// The History list's files: one small record per dictation, and beside it
/// the recording Try again listens to.
///
/// `~/Library/Application Support/Airlock/Dictation History`, the folder
/// owner-only (0700) and every file in it 0600, like the rest of what this app
/// writes. Nothing here leaves the Mac. The rules (how long, what a search
/// matches, what Try again keeps) are `DictationHistory`, in Core.
///
/// The record is written when the microphone opens and marked finished once the
/// words reach somewhere. A record left unfinished at the next launch is a
/// dictation that was cut off on its way, and `DictationModel` brings it back
/// from its recording (`recoverCutOff`).
@MainActor
@Observable
final class DictationHistoryStore {
    static let shared = DictationHistoryStore()

    static let keepsHistoryKey = "dictation.keepsHistory"
    static let keepsRecordingsKey = "dictation.keepsRecordings"
    static let pastesLastKey = "dictation.pasteLast.enabled"
    static let pasteLastBindingKey = "dictation.pasteLast.hotkey"

    /// Both on unless switched off in Settings.
    static var keepsHistory: Bool {
        UserDefaults.standard.object(forKey: keepsHistoryKey) as? Bool ?? true
    }
    static var keepsRecordings: Bool {
        keepsHistory && (UserDefaults.standard.object(forKey: keepsRecordingsKey) as? Bool ?? true)
    }

    /// Newest first.
    private(set) var entries: [DictationEntry] = []
    /// Entries being listened to again right now, for the row's spinner.
    var retrying: Set<UUID> = []

    @ObservationIgnored let directory: URL
    @ObservationIgnored private var loaded = false

    init(directory: URL? = nil) {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/Dictation History",
                                    isDirectory: true)
    }

    // MARK: - Reading

    /// Reads every record once. Records that fail to decode are left on disk
    /// untouched rather than deleted: a newer build may know them.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let decoder = JSONDecoder()
        var found: [DictationEntry] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  var entry = try? decoder.decode(DictationEntry.self, from: data) else { continue }
            // A recording that went missing is no longer one to try again.
            if entry.hasRecording, !manager.fileExists(atPath: recordingURL(entry.id).path) {
                entry.hasRecording = false
            }
            found.append(entry)
        }
        entries = DictationHistory.newestFirst(found)
    }

    func entry(_ id: UUID) -> DictationEntry? { entries.first { $0.id == id } }

    func recordingURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).caf")
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Writing

    /// A new, unfinished record, written before a word is heard. Nil when
    /// history is off.
    func begin(app: String?, recording: Bool) -> DictationEntry? {
        guard Self.keepsHistory, prepareDirectory() else { return nil }
        loadIfNeeded()
        let entry = DictationEntry(date: Date(), app: app, hasRecording: recording)
        put(entry)
        return entry
    }

    /// Saves `entry` in place of the record with its id, or as a new one.
    func put(_ entry: DictationEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries = DictationHistory.newestFirst(entries + [entry])
        }
        write(entry)
    }

    /// Removes a record and its recording. Used for a dictation that heard
    /// nothing, one into a password field, and the row's own Remove.
    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        let manager = FileManager.default
        try? manager.removeItem(at: recordURL(id))
        try? manager.removeItem(at: recordingURL(id))
    }

    /// Drops only the recording, keeping the text.
    func removeRecording(_ id: UUID) {
        try? FileManager.default.removeItem(at: recordingURL(id))
        guard var entry = entry(id), entry.hasRecording else { return }
        entry.hasRecording = false
        put(entry)
    }

    /// "Clear history": every record and every recording.
    func clear() {
        let manager = FileManager.default
        if let names = try? manager.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasSuffix(".json") || name.hasSuffix(".caf") {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        entries = []
        retrying = []
    }

    /// "Keep recordings" switched off: the ones already kept go too.
    func removeAllRecordings() {
        for entry in entries where entry.hasRecording { removeRecording(entry.id) }
    }

    /// Applies the 200 / 30 days / 7 days rules.
    func prune(now: Date = Date()) {
        loadIfNeeded()
        let pruning = DictationHistory.pruning(entries, now: now)
        guard !pruning.isEmpty else { return }
        for id in pruning.entries { remove(id) }
        for id in pruning.recordings { removeRecording(id) }
    }

    @discardableResult
    private func prepareDirectory() -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return true
        } catch {
            dictationLog("history: could not make its folder — \(error.localizedDescription)")
            return false
        }
    }

    private func write(_ entry: DictationEntry) {
        guard prepareDirectory() else { return }
        let url = recordURL(entry.id)
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            dictationLog("history: could not save a record — \(error.localizedDescription)")
        }
    }
}

/// Writes the microphone's buffers to a file as they arrive, off the main
/// thread, so a dictation cut off mid-sentence still has its audio.
///
/// CAF because a CAF whose writer never closed it is still readable to its
/// last written packet: that is exactly the file a crash leaves.
actor DictationRecorder {
    private let url: URL
    private var file: AVAudioFile?
    private var failed = false

    init(url: URL) { self.url = url }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        do {
            if file == nil {
                let format = buffer.format
                file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try file?.write(from: buffer)
        } catch {
            failed = true
            file = nil
        }
    }

    /// Stops writing for good and removes what was written: a password field,
    /// or a hold that was thrown away.
    func discard() {
        failed = true
        file = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Closes the file. True when it holds audio.
    func close() -> Bool {
        let wrote = file != nil && !failed
        file = nil
        return wrote
    }

    /// Feeds `source` on to the recogniser and, a buffer behind, to the file.
    /// The recogniser never waits on the disk.
    nonisolated static func tee(_ source: AsyncStream<AnalyzerInput>,
                                into recorder: DictationRecorder?) -> AsyncStream<AnalyzerInput> {
        guard let recorder else { return source }
        let (output, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        Task.detached(priority: .userInitiated) {
            for await input in source {
                continuation.yield(input)
                await recorder.append(input.buffer)
            }
            continuation.finish()
            _ = await recorder.close()
        }
        return output
    }

    /// A saved recording, as buffers in the format the recogniser asks for.
    /// Nil when the file can't be read.
    nonisolated static func buffers(from url: URL, as target: AVAudioFormat) -> [AVAudioPCMBuffer]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                          interleaved: false) else { return nil }
        let source = file.processingFormat
        let chunk: AVAudioFrameCount = 16_000
        var read: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { return nil }
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            if buffer.frameLength == 0 { break }
            read.append(buffer)
        }
        guard !read.isEmpty else { return nil }
        if source == target { return read }
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        var out: [AVAudioPCMBuffer] = []
        for buffer in read {
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            // The converter calls this block on the calling thread, once per
            // convert; nothing else touches either.
            nonisolated(unsafe) var given = false
            nonisolated(unsafe) let handOver = buffer
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return handOver
            }
            if error != nil { return nil }
            if converted.frameLength > 0 { out.append(converted) }
        }
        return out.isEmpty ? nil : out
    }
}
