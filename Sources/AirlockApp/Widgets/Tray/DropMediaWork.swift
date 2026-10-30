import AVFoundation
import AirlockCore
import Foundation
import ImageIO
import Speech
import UniformTypeIdentifiers
import os

/// The drop box's work on films and sound, with AVFoundation, and writing out
/// what is said in a recording with the Mac's own speech model. Nothing is
/// sent anywhere.
enum DropMediaWork {
    /// A GIF's frames a second and longest side: smooth enough to read as
    /// motion, small enough to send.
    static let gifFramesPerSecond = 10
    static let gifSide: CGFloat = 480

    static func mp4(_ url: URL, at destination: URL) async throws {
        try await export(AVURLAsset(url: url), preset: AVAssetExportPresetHighestQuality,
                         as: .mp4, to: destination)
    }

    /// 720p, or a lower bit rate for a film that is already that small. Not
    /// made when it would come out no smaller.
    ///
    /// The 720p copy is the older, less efficient codec, so a film recorded
    /// in HEVC at a modest bit rate (an iPhone's) can come out several times
    /// BIGGER. Then the lower bit rate is tried before giving up.
    static func smaller(_ url: URL, at destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DropWork.Failure.unreadable
        }
        let size = try await track.load(.naturalSize)
        let presets = max(abs(size.width), abs(size.height)) > 1280
            ? [AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality]
            : [AVAssetExportPresetMediumQuality]
        let before = DropPictureWork.fileSize(url)
        for preset in presets {
            try? FileManager.default.removeItem(at: destination)
            try await export(asset, preset: preset, as: fileType(destination), to: destination)
            guard let before, let after = DropPictureWork.fileSize(destination), after >= before else { return }
        }
        throw DropWork.Failure.alreadySmall
    }

    /// The film with its sound left out. The picture is copied as it is, not
    /// encoded again, so it loses nothing and takes a moment.
    static func withoutSound(_ url: URL, at destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let copy = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw DropWork.Failure.unwritable
            }
            try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        guard !composition.tracks.isEmpty else { throw DropWork.Failure.unreadable }
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, as: fileType(destination),
                             to: destination)
        } catch {
            // Some films can't be copied into another container as they are.
            try? FileManager.default.removeItem(at: destination)
            try await export(composition, preset: AVAssetExportPresetHighestQuality, as: fileType(destination),
                             to: destination)
        }
    }

    /// The sound alone, or a sound file, as an M4A.
    static func m4a(_ url: URL, at destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw DropWork.Failure.noSound }
        try await export(asset, preset: AVAssetExportPresetAppleM4A, as: .m4a, to: destination)
    }

    /// The first `DropChoice.gifSeconds` of a film as a looping GIF.
    static func gif(of url: URL, at destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        let seconds = min(try await asset.load(.duration).seconds, Double(DropChoice.gifSeconds))
        guard seconds > 0 else { throw DropWork.Failure.unreadable }
        let step = 1 / Double(gifFramesPerSecond)
        let times = stride(from: 0.0, to: seconds, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: gifSide, height: gifSide)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString,
                                                           times.count, nil) else { throw DropWork.Failure.unwritable }
        CGImageDestinationSetProperties(writer, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary
        var added = 0
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            CGImageDestinationAddImage(writer, image, frame)
            added += 1
        }
        guard added > 0 else { throw DropWork.Failure.unreadable }
        guard CGImageDestinationFinalize(writer) else { throw DropWork.Failure.unwritable }
    }

    /// A sound file as WAV or AIFF: 16-bit, at its own rate and channels,
    /// which is what every program that asks for one of these expects.
    static func pcm(_ url: URL, as format: AudioFormat, at destination: URL) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url) } catch { throw DropWork.Failure.unreadable }
        let source = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: source.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: source.commonFormat, interleaved: source.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 65_536) else {
            throw DropWork.Failure.unwritable
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// What is said in a recording, as plain text a paragraph per pause,
    /// in the language it is spoken in.
    ///
    /// Apple's recogniser cannot tell a language by ear, so the recording is
    /// heard in the call languages (dictation's when none are picked) and
    /// the recogniser's own confidence picks the take (`TranscriptRace`).
    /// When the words of that take read as another language this Mac knows,
    /// as a Spanish voice message heard in English does, it is heard again
    /// in that one and the two races again (`CallLanguage.hearAgain`).
    static func writtenOut(_ url: URL) async throws -> String {
        guard let (picked, _, listeners) = await MeetingNotesModel.speechSetup(
            settings: .standard, log: { line in log.info("drop box: \(line, privacy: .public)") })
        else { throw DropWork.Failure.noSpeech }
        let primary = picked[0].identifier
        var takes = try await heard(url, by: picked)
        guard var best = TranscriptRace.winner(among: takes.map(\.candidate), primary: primary) else {
            throw DropWork.Failure.noSpeech
        }
        let reading = CallLanguage.reading(of: best.text)
        if let code = CallLanguage.hearAgain(heardIn: best.localeIdentifier, reading: reading,
                                             known: listeners.codes),
           let again = await CallListening.resolved(Locale(identifier: code)),
           !picked.contains(again), await CallListening.prepare(again) {
            takes += try await heard(url, by: [again])
            // The first hearing keeps the tie: the words' language is a
            // guess, the recogniser's confidence is a measurement.
            best = TranscriptRace.winner(among: takes.map(\.candidate), primary: best.localeIdentifier) ?? best
            log.info("drop box: heard again in \(again.identifier, privacy: .public), \(takes.map { "\($0.candidate.localeIdentifier) \(String(format: "%.2f", $0.candidate.confidence))" }.joined(separator: " · "), privacy: .public) → \(best.localeIdentifier, privacy: .public)")
        }
        guard let lines = takes.first(where: { $0.candidate.localeIdentifier == best.localeIdentifier })?.lines,
              !lines.isEmpty else { throw DropWork.Failure.noSpeech }
        return lines.joined(separator: "\n\n")
    }

    private static let log = Logger(subsystem: "com.airlock.app", category: "shelf")

    /// One recogniser's hearing of a recording: its lines and its score.
    private struct Take {
        var candidate: TranscriptRace.Candidate
        var lines: [String]
    }

    /// The recording heard by each of `listeners` at once, on one analyzer.
    private static func heard(_ url: URL, by listeners: [CallLanguageFollow.Listener]) async throws -> [Take] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw DropWork.Failure.unreadable }
        let modules = listeners.map { CallListening.module(for: $0) }
        let analyzer = SpeechAnalyzer(modules: modules)
        let collecting = zip(listeners, modules).map { listener, module in
            Task { () throws -> Take in
                var lines: [String] = []
                var weighted = 0.0
                var scored = 0
                func keep(_ text: AttributedString) {
                    let line = String(text.characters).trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty else { return }
                    lines.append(line)
                    let score = CallListening.confidence(of: text)
                    weighted += score.weighted
                    scored += score.scored
                }
                if let speech = module as? SpeechTranscriber {
                    for try await result in speech.results where result.isFinal { keep(result.text) }
                } else if let dictation = module as? DictationTranscriber {
                    for try await result in dictation.results where result.isFinal { keep(result.text) }
                }
                let confidence = scored > 0 ? weighted / Double(scored) : 0
                return Take(candidate: .init(localeIdentifier: listener.identifier,
                                             text: lines.joined(separator: " "),
                                             confidence: CallLanguageFollow.lifted(confidence, listener.module)),
                            lines: lines)
            }
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        var takes: [Take] = []
        for task in collecting { takes.append(try await task.value) }
        return takes
    }

    // MARK: -

    private static func export(_ asset: AVAsset, preset: String, as type: AVFileType,
                               to destination: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw DropWork.Failure.unwritable
        }
        try await session.export(to: destination, as: type)
    }

    private static func fileType(_ destination: URL) -> AVFileType {
        switch destination.pathExtension.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }
}
