import AVFoundation
import AirlockCore
import CoreML
import CryptoKit
import FluidDiarizer
import Speech

/// The voice model's files on this Mac, and whether call notes use them.
///
/// NVIDIA's Nemotron 3 speaker model, converted for Core ML by Fluid
/// Inference (OpenMDW-1.1, see THIRD-PARTY-LICENSES.txt): about 100 MB, not
/// in the app. It tells up to eight voices apart within one stretch of
/// audio, by sound alone. It knows nobody, and nothing it hears is kept:
/// what it says lives in memory for one call and is gone once the call's
/// lines are numbered (`CallVoices`).
enum CallVoiceModel {
    /// 10.24 s of audio a step, ten and a half seconds behind the call:
    /// the model's best quality for a stream. People are told apart in the
    /// side window ten to twenty seconds after they speak, and the end of a
    /// call waits on its last step.
    static let preset = "c128-split-w8a8"

    static var config: Nemotron3Config {
        // The name is one of the vendored file's own presets.
        Nemotron3Config.preset(named: preset)!
    }

    /// `~/Library/Application Support/Airlock/Models/voices`.
    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/Models/voices", isDirectory: true)
    }

    /// Every file the model needs, with its size and SHA-256 as Fluid
    /// Inference published them (the compiled program's, which their
    /// listing does not give, measured from the download).
    static let files: [(path: String, size: Int, sha256: String)] = [
        ("Nemotron3Diarizer_c128_split_w8a8.mlmodelc/weights/weight.bin", 99_249_792,
         "9a4c5de6ba011560713206b76c357d99ee596d1f1a58c66368b82834f9e12f95"),
        ("Nemotron3Diarizer_c128_split_w8a8.mlmodelc/model.mil", 759_134,
         "fdc429dae043fd0e10c9c91408a6002df6b90c71ef5c30877c56f7796abb6c53"),
        ("Nemotron3Diarizer_c128_split_w8a8.mlmodelc/coremldata.bin", 605,
         "777c6c6240baef5973b99b6984e9bb3a1f6a4812de28d3c65317be8911491421"),
        ("Nemotron3Diarizer_c128_split_w8a8.mlmodelc/analytics/coremldata.bin", 243,
         "9522ac23edf90deb9bc4d3ef97ca435a90df499d346c4806351784b5a8decb60"),
        ("learnable_sil_emb.bin", 2_048, "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
        ("pre_encode_proj_t.bin", 2_097_152, "eb15b89e7af9813331a7d8db02e83e30bf97463d272c748e72086bafd4e81c60"),
    ]

    /// The person's switch. Unset means on once the model is here: today
    /// the only way it gets here is being put here on purpose.
    static let enabledKey = "meetings.voices.enabled"

    /// Every file present at its size. Cheap; the hashes are `verified`.
    static var isInstalled: Bool {
        files.allSatisfy { file in
            let path = folder.appendingPathComponent(file.path).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int
            return size == file.size
        }
    }

    static var isOn: Bool { isOn(in: .standard) }

    /// `isOn`, with the switch read from `settings`.
    static func isOn(in settings: UserDefaults) -> Bool {
        (settings.object(forKey: enabledKey) as? Bool ?? true) && isInstalled
    }

    /// Whether every file matches its hash, read once per launch: a model
    /// changed on disk is refused rather than run.
    static func verified() async -> Bool {
        if let known = await VerifiedOnce.shared.result { return known }
        let folder = folder
        let ok = await Task.detached(priority: .utility) {
            files.allSatisfy { file in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(file.path),
                                           options: .mappedIfSafe) else { return false }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return digest == file.sha256
            }
        }.value
        await VerifiedOnce.shared.set(ok)
        return ok
    }

    private actor VerifiedOnce {
        static let shared = VerifiedOnce()
        var result: Bool?
        func set(_ value: Bool) { result = value }
    }
}

/// Listens to the other side of a call for who is speaking when, beside
/// the recognisers and on the same audio (`MeetingTrack.voiceInput`).
///
/// It runs ten seconds behind the call in steps of ten, on the Neural
/// Engine where it can, and keeps only stretches of "voice 3 from 12:04.2
/// to 12:09.8" (`CallVoices.Tracker`). Nothing is written anywhere. The
/// lines are numbered from those stretches as the call goes on, and once
/// more when it ends.
actor CallVoiceListener {
    /// What it heard and what that cost, for the numbering and the log.
    struct Report: Sendable {
        var spans: [CallVoices.Span]
        /// Seconds of call audio the model was given.
        var audioSeconds: Double
        /// Seconds the model spent on it: divided by `audioSeconds`, how
        /// much of one core's time the voices cost (the real-time factor).
        var computeSeconds: Double
        var loadSeconds: Double
        /// Why it stopped early, if it did. For the log only, never shown.
        var stopped: String?
    }

    private let offset: TimeInterval
    private var diarizer: Nemotron3Diarizer?
    private var tracker: CallVoices.Tracker?
    private var samples = 0
    private var computeSeconds = 0.0
    private var loadSeconds = 0.0
    private var stopped: String?
    private var running: Task<Void, Never>?
    private var converter: AVAudioConverter?

    /// `offset`: how far into the meeting the stream's start is.
    init(offset: TimeInterval) {
        self.offset = offset
    }

    /// Loads the model and listens to `input` until it ends.
    func start(_ input: AsyncStream<AnalyzerInput>) {
        running = Task { await self.listen(to: input) }
    }

    /// Waits for the stream's end (the track closing ends it), finishes the
    /// last step, and hands over what was heard. The model is let go.
    func finish() async -> Report {
        await running?.value
        if let diarizer, stopped == nil {
            do {
                try step { try diarizer.finishStream() }
            } catch {
                stopped = "last step: \(String(describing: error))"
            }
        }
        tracker?.finish()
        diarizer = nil
        return Report(spans: tracker?.spans ?? [], audioSeconds: Double(samples) / 16_000,
                      computeSeconds: computeSeconds, loadSeconds: loadSeconds, stopped: stopped)
    }

    /// What it has heard so far, and how far into the meeting: for
    /// numbering the lines while the call goes on. Nil before the model
    /// has heard anything.
    func soFar() -> (spans: [CallVoices.Span], through: TimeInterval)? {
        guard let tracker, tracker.frames > 0 else { return nil }
        return tracker.soFar
    }

    /// Stops listening and forgets everything: a call too short to keep.
    func cancel() {
        running?.cancel()
        diarizer = nil
        tracker = nil
    }

    private func listen(to input: AsyncStream<AnalyzerInput>) async {
        let started = ContinuousClock.now
        let config = CallVoiceModel.config
        do {
            guard await CallVoiceModel.verified() else {
                stopped = "model files do not match"
                return
            }
            let models = try await Nemotron3Models.load(config: config, directory: CallVoiceModel.folder)
            diarizer = Nemotron3Diarizer(config: config, models: models)
        } catch {
            stopped = "load: \(String(describing: error))"
            return
        }
        loadSeconds = (ContinuousClock.now - started).seconds
        for await item in input {
            if Task.isCancelled { return }
            guard let diarizer else { return }
            if tracker == nil {
                let start = item.bufferStartTime.map(\.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
                tracker = CallVoices.Tracker(origin: offset + start)
            }
            guard let floats = mono16k(item.buffer), !floats.isEmpty else { continue }
            samples += floats.count
            diarizer.appendAudio(floats)
            do {
                try step { try diarizer.processBufferedAudio() }
            } catch {
                stopped = "step: \(String(describing: error))"
                self.diarizer = nil
                return
            }
        }
    }

    private func step(_ run: () throws -> [Nemotron3ChunkResult]) throws {
        let started = ContinuousClock.now
        let results = try run()
        computeSeconds += (ContinuousClock.now - started).seconds
        for result in results {
            tracker?.add(result.probabilities, frames: result.frameCount, voices: result.numSpeakers)
        }
    }

    /// The buffer as 16 kHz mono floats, whatever the analyzer's format:
    /// its first channel, resampled only when it is not 16 kHz already.
    private func mono16k(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let format = buffer.format
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        let stride = format.isInterleaved ? Int(format.channelCount) : 1
        let samples: [Float]
        if let data = buffer.floatChannelData {
            samples = (0..<count).map { data[0][$0 * stride] }
        } else if let data = buffer.int16ChannelData {
            samples = (0..<count).map { Float(data[0][$0 * stride]) / 32_768 }
        } else {
            return nil
        }
        let rate = format.sampleRate
        guard rate != 16_000 else { return samples }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false),
              let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
        if converter?.inputFormat.sampleRate != rate {
            converter = AVAudioConverter(from: source, to: target)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(count) * 16_000 / rate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        // The input buffer is made inside the block, from plain samples, as
        // in `CallAudioTap`: the block is imported `@Sendable`.
        let once = OneShot()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            guard once.claim(), let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)),
                  let channel = input.floatChannelData?[0] else {
                status.pointee = .noDataNow
                return nil
            }
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: count) }
            input.frameLength = AVAudioFrameCount(count)
            status.pointee = .haveData
            return input
        }
        guard status == .haveData || status == .inputRanDry, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

private extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
