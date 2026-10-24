import AVFoundation
import AirlockCore
import Speech

/// Reads a recording somebody already has as a meeting in the room, as if
/// it had been heard live: the call languages from Settings, the same track
/// and language following, the same voice model and the same notes writer.
/// The window's "Add a recording" (`RecordingImporter`) and
/// `--notes-from-recording` (`RecordingReplay`) both read through this.
///
/// The file is only read, and none of its sound is kept: the meeting's
/// folder holds the transcript and the notes, like a live meeting's. The
/// record is saved before any listening, without an end, so the window lists
/// the meeting at once; it is given its end when every second has been heard.
///
/// The sound is passed on faster than it was said (`RecordingImport.speed`):
/// every time in the transcript comes from the audio, and the recogniser
/// keeps up with several times real time.
@MainActor
final class RecordingReader {
    enum Outcome {
        /// The notes are saved. `notes` is nil when none were written.
        case saved(folder: URL, record: MeetingRecord, notes: MeetingNotes?)
        /// `stop()` was called. The folder, if one was made, is gone.
        case stopped
        /// Nothing was made. What to say.
        case failed(String)
    }

    /// Every change of where the reading is, at most about once a second
    /// while it plays.
    var onProgress: (RecordingImport.Progress) -> Void = { _ in }
    /// The folder is made and the record saved in it, before any listening.
    var onFolder: (URL, MeetingRecord) -> Void = { _, _ in }
    /// The latest lines written down, oldest first.
    var onLines: ([MeetingSegment]) -> Void = { _ in }

    private let store: MeetingStore
    private let speed: Double
    private let settings: UserDefaults
    private let log: (String) -> Void
    private var stopped = false
    private var notes: Task<MeetingNotesModel.WrittenNotes, Never>?

    /// How many lines `onLines` is given.
    static let linesShown = 8

    init(store: MeetingStore = MeetingStore(), speed: Double = RecordingImport.speed,
         settings: UserDefaults = .standard, log: @escaping (String) -> Void) {
        self.store = store
        self.speed = max(1, speed)
        self.settings = settings
        self.log = log
    }

    /// Ends the reading as soon as it can and removes what it made. The
    /// file is untouched.
    func stop() {
        stopped = true
        notes?.cancel()
    }

    /// Reads `url` into a new meeting folder. `startedAt`, when given, is
    /// when the meeting began; otherwise the recording's own date says.
    func read(_ url: URL, startedAt given: Date? = nil) async -> Outcome {
        let name = url.lastPathComponent
        var progress = RecordingImport.Progress(fileName: name, seconds: 0)
        onProgress(progress)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            log("recording: can't read it as sound (\(url.pathExtension.lowercased()))")
            return .failed(RecordingImport.unreadable(name))
        }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard seconds >= 1 else {
            log("recording: no sound in it")
            return .failed(RecordingImport.unreadable(name))
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let recorded = await Self.recordedAt(url)
        let startedAt = given ?? RecordingImport.startedAt(recorded: recorded, modified: modified,
                                                           seconds: seconds, now: Date())
        let tellsVoices = CallVoiceModel.isOn(for: CloudNotesService.shared.plan(), in: settings)
        progress = RecordingImport.Progress(fileName: name, seconds: seconds, tellsVoices: tellsVoices,
                                            speed: speed)
        onProgress(progress)
        log(String(format: "recording: %.0f s, dated from %@, at %.0fx", seconds,
                   given != nil ? "the caller" : recorded != nil ? "its own date" : modified != nil
                       ? "its last change" : "now", speed))
        guard !stopped else { return .stopped }

        guard let (picked, format, listeners) = await MeetingNotesModel.speechSetup(settings: settings, log: log)
        else { return .failed(String(localized: "The speech model isn't installed for your language yet.")) }
        guard !stopped else { return .stopped }

        let call = OngoingCall.inPerson(at: startedAt)
        var record = MeetingRecord(bundleID: call.bundleID, appName: call.appName, startedAt: startedAt,
                                   languages: picked.map(\.identifier),
                                   recording: MeetingRecording(fileName: name, seconds: seconds),
                                   startedOn: CloudNotesService.shared.plan())
        let folder: URL
        do {
            folder = try store.makeFolder(for: record)
            try store.saveTranscript(record, in: folder)
        } catch {
            log("recording: folder FAILED: \(error.localizedDescription)")
            return .failed(String(localized: "Airlock couldn't save the notes in your Meetings folder."))
        }
        onFolder(folder, record)

        // The room, as a meeting in it is heard: one side, everybody "them".
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        var heard = record
        let onLines = onLines
        let track = MeetingTrack(speaker: .them, listeners: listeners, canRead: CallNotesWriter.canRead,
                                 vocabulary: MeetingNotesModel.typedWords(in: settings), log: log) { event in
            switch event {
            case .line(let segment):
                heard.add(segment)
            case .listening(let from, let language):
                heard.listen(.them, from: from, in: language)
                return
            case .switched(let seam, let language, let lines, let keptAs):
                heard.switchLanguage(of: .them, at: seam, to: language, lines: lines, keptAs: keptAs)
            case .shadow(let line):
                heard.addShadow(line)
                return
            }
            onLines(Array(heard.segments.suffix(Self.linesShown)))
        }
        track.begin(picked, format: format, offset: 0, input: input)
        var voices: CallVoiceListener?
        var voicesFrom: TimeInterval = 0
        if tellsVoices {
            let (stream, offset) = track.voiceInput()
            let listener = CallVoiceListener(offset: offset)
            await listener.start(stream)
            voices = listener
            voicesFrom = offset
        }

        progress.stage = .listening
        onProgress(progress)
        let played = await play(file, as: format, into: feed) { at in
            progress.heard = at
            self.onProgress(progress)
        }
        feed.finish()
        guard !stopped else {
            await track.abandon()
            await voices?.cancel()
            return removed(folder)
        }
        log(String(format: "recording: played %.0f s of sound", played))

        progress.stage = .voices
        onProgress(progress)
        await track.finish(within: .seconds(180))
        record = heard
        record.endedAt = startedAt.addingTimeInterval(seconds)
        if !track.languages.isEmpty { record.languages = track.languages }
        if let voices {
            let report = await voices.finish()
            let outcome = CallVoices.number(&record, from: voicesFrom, spans: report.spans, words: track.words)
            var line = "voices: \(outcome.people) people from \(outcome.heard) heard"
            line += ", \(outcome.folded) folded, \(outcome.split) line(s) cut"
            if !outcome.talk.isEmpty {
                line += ", talk " + outcome.talk.map { String(format: "%.1f", $0) }.joined(separator: "/") + "s"
            }
            if let reason = outcome.reason { line += " (\(reason))" }
            line += String(format: "; model %.1fs, load %.1fs", report.computeSeconds, report.loadSeconds)
            if let stopped = report.stopped { line += "; stopped: \(stopped)" }
            log(line)
        }
        await MeetingNotesModel.respell(&record, settings: settings, store: store, log: log)
        guard !stopped else { return removed(folder) }
        do {
            try store.saveTranscript(record, in: folder)
        } catch {
            log("recording: transcript save FAILED: \(error.localizedDescription)")
            _ = removed(folder)
            return .failed(String(localized: "Airlock couldn't save the notes in your Meetings folder."))
        }
        log("recording: \(record.segments.count) lines")

        progress.stage = .notes
        onProgress(progress)
        let started = Date()
        let writing = Task { [record, log] in await MeetingNotesModel.notesPage(for: record, log: log) }
        notes = writing
        let page = await writing.value
        let written = page.notes
        notes = nil
        guard !stopped else { return removed(folder) }
        do {
            try store.saveNotes(page.page, in: folder)
            if let writer = page.writer {
                try store.saveNotesWriter(writer, in: folder)
                // Waits for a date: the service looks again then.
                if writer.waitsForOnline, writer.notBefore != nil {
                    Task { await CloudNotesService.shared.planNextLook() }
                }
            }
        } catch {
            log("recording: notes save FAILED: \(error.localizedDescription)")
            return .failed(String(localized: "Airlock couldn't save the notes in your Meetings folder."))
        }
        do {
            try store.saveTopic(written?.title, in: folder)
        } catch {
            log("recording: title not saved: \(error.localizedDescription)")
        }
        log(String(format: "recording: notes saved in %.0f s", Date().timeIntervalSince(started)))
        return .saved(folder: folder, record: record, notes: written)
    }

    private func removed(_ folder: URL) -> Outcome {
        do {
            try store.remove(folder)
            log("recording: stopped, folder removed")
        } catch {
            log("recording: stopped, remove FAILED: \(error.localizedDescription)")
        }
        return .stopped
    }

    /// The recording's own date, from its metadata: a voice memo carries
    /// when it was recorded.
    private static func recordedAt(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// Reads `file` in half-second pieces, converts each to `format` and
    /// passes it on, never further ahead of the clock than `speed` allows,
    /// until the end or `stop()`. Tells `heard` how far it is about once a
    /// second. Returns the seconds of sound passed on.
    private func play(_ file: AVAudioFile, as format: AVAudioFormat,
                      into feed: AsyncStream<AnalyzerInput>.Continuation,
                      heard: (TimeInterval) -> Void) async -> Double {
        let source = file.processingFormat
        // Mixed to one channel first, then converted as the call tap does
        // (`CallAudioTap.convert`): nothing that isn't Sendable crosses
        // into the converter's input block.
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono, to: format) else {
            log("recording: can't convert \(source) to \(format)")
            return 0
        }
        let chunk = AVAudioFrameCount(source.sampleRate / 2)
        let begun = ContinuousClock.now
        var frames: Int64 = 0
        var toldAt = begun
        while file.framePosition < file.length, !stopped {
            guard let read = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
                  (try? file.read(into: read, frameCount: chunk)) != nil, read.frameLength > 0,
                  let channels = read.floatChannelData else { break }
            let count = Int(read.frameLength), channelCount = Int(source.channelCount)
            var samples = [Float](repeating: 0, count: count)
            for channel in 0..<channelCount {
                let data = channels[channel]
                for index in 0..<count { samples[index] += data[index] }
            }
            if channelCount > 1 {
                let scale = 1 / Float(channelCount)
                for index in 0..<count { samples[index] *= scale }
            }
            if let out = CallAudioTap.convert(samples, rate: source.sampleRate, with: converter, to: format) {
                feed.yield(AnalyzerInput(buffer: out))
            }
            frames += Int64(read.frameLength)
            let soundSeconds = Double(frames) / source.sampleRate
            let now = ContinuousClock.now
            if now - toldAt >= .seconds(1) {
                toldAt = now
                heard(soundSeconds)
            }
            let due = soundSeconds / speed
            let gone = now - begun
            let elapsed = Double(gone.components.seconds) + Double(gone.components.attoseconds) / 1e18
            if due > elapsed { try? await Task.sleep(for: .seconds(due - elapsed)) }
        }
        let total = Double(frames) / source.sampleRate
        heard(total)
        return total
    }
}
