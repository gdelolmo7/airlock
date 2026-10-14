import AVFoundation
import AirlockEcho
import Foundation
import Speech

// EchoProbe MIC REF [options] — runs the echo remover over a recording of
// the microphone (MIC) and of what the speakers played (REF), and prints
// the delay it found and how much quieter the microphone came out, second
// by second while the speakers played.
//
//   --ref-start SECONDS  the speakers' recording began this long after the
//                        microphone's (negative: before). Default 0.
//   --near FILE          a recording of someone near the Mac, added to the
//                        microphone: both talking at once, made by hand.
//   --near-gain DB       its level change first. Default 0.
//   --out FILE           where to write the cleaned microphone (16 kHz WAV).
//   --transcribe LOCALE  also print what the recogniser hears in the
//                        microphone before and after, e.g. es_ES.
//
// Like SpeakerProbe, a tool for looking, never in the bundle.

let rate = EchoRemover.sampleRate

func usage() -> Never {
    print("usage: EchoProbe MIC REF [--ref-start S] [--near FILE] [--near-gain DB] [--out FILE] [--transcribe LOCALE]")
    exit(2)
}

func readMono16k(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    guard let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: whole)
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
          let source = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: whole.frameLength),
          let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return [] }
    // Channels averaged into one.
    let channels = Int(format.channelCount)
    let frames = Int(whole.frameLength)
    for frame in 0..<frames {
        var sum: Float = 0
        for channel in 0..<channels { sum += whole.floatChannelData![channel][frame] }
        source.floatChannelData![0][frame] = sum / Float(channels)
    }
    source.frameLength = whole.frameLength
    if format.sampleRate == rate {
        return Array(UnsafeBufferPointer(start: source.floatChannelData![0], count: frames))
    }
    guard let converter = AVAudioConverter(from: mono, to: target),
          let out = AVAudioPCMBuffer(pcmFormat: target,
                                     frameCapacity: AVAudioFrameCount(Double(frames) * rate / format.sampleRate) + 4_096)
    else { return [] }
    nonisolated(unsafe) var given = false
    nonisolated(unsafe) let handOver = source
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if given {
            status.pointee = .endOfStream
            return nil
        }
        given = true
        status.pointee = .haveData
        return handOver
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

func write(_ samples: [Float], to path: String) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
    else { return }
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
    try file.write(from: buffer)
}

func transcribe(_ path: String, locale: Locale) async throws -> String {
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                        attributeOptions: [])
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let collect = Task {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters) + " "
        }
        return text
    }
    if let end = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: end)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collect.value.trimmingCharacters(in: .whitespaces)
}

func power(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)
}

func decibels(_ value: Double) -> Double { 10 * log10(max(value, 1e-20)) }

// MARK: - Arguments

var positional: [String] = []
var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    if argument.hasPrefix("--") {
        guard let value = arguments.next() else { usage() }
        options[String(argument.dropFirst(2))] = value
    } else {
        positional.append(argument)
    }
}
guard positional.count == 2 else { usage() }

var mic = try readMono16k(positional[0])
let reference = try readMono16k(positional[1])
let referenceStart = Double(options["ref-start"] ?? "0") ?? 0
if let nearPath = options["near"] {
    let gain = Float(pow(10, (Double(options["near-gain"] ?? "0") ?? 0) / 20))
    let near = try readMono16k(nearPath)
    for index in 0..<min(mic.count, near.count) { mic[index] += near[index] * gain }
}

// MARK: - Run

// Pieces as the app gets them: the microphone in tenths of a second, the
// speakers in thirtieths, each arriving when its last sample was captured.
enum Piece { case mic(Range<Int>), speakers(Range<Int>) }
var pieces: [(time: Double, piece: Piece)] = []
for from in stride(from: 0, to: mic.count, by: 1_600) {
    let to = min(mic.count, from + 1_600)
    pieces.append((Double(to) / rate, .mic(from..<to)))
}
for from in stride(from: 0, to: reference.count, by: 480) {
    let to = min(reference.count, from + 480)
    pieces.append((referenceStart + Double(to) / rate, .speakers(from..<to)))
}
pieces.sort { $0.time < $1.time }

let remover = EchoRemover()
var cleaned: [Float] = []
let started = Date()
for (time, piece) in pieces {
    switch piece {
    case .mic(let range): cleaned += remover.addMicrophone(Array(mic[range]), at: time)
    case .speakers(let range): remover.addReference(Array(reference[range]), at: time)
    }
}
cleaned += remover.finish()
let took = Date().timeIntervalSince(started)
let report = remover.currentReport

print(String(format: "%.1f s of microphone in %.2f s (%.0fx real time)",
             Double(mic.count) / rate, took, Double(mic.count) / rate / max(took, 1e-6)))
print("delay:", report.delayMilliseconds.map { String(format: "%.1f ms", $0) } ?? "not found",
      String(format: "(clarity %.1f, %d clear, moved %d times)", report.strength, report.estimates, report.realigned))
print(String(format: "speakers played %.1f s; quieter by %.1f dB after the filter, %.1f dB after everything",
             report.speakersSeconds, report.filterDB, report.totalDB))
print("blocks that went without the speakers' sound:", report.unmatchedBlocks)

// Second by second, on the microphone's clock: the speakers' level (where
// the clocks put it), and the microphone before and after.
print("\nsecond  speakers  mic before  after  quieter by")
let offset = Int((referenceStart * rate).rounded())
for second in 0..<(mic.count / Int(rate)) {
    let span = (second * Int(rate))..<((second + 1) * Int(rate))
    let speakersSpan = max(0, span.lowerBound - offset)..<max(0, min(reference.count, span.upperBound - offset))
    let speakers = decibels(power(reference[speakersSpan]))
    let before = decibels(power(mic[span]))
    let after = decibels(power(cleaned[span]))
    print(String(format: "%5d  %8.1f  %10.1f  %5.1f  %10.1f", second, speakers, before, after, before - after))
}

if let out = options["out"] {
    try write(cleaned, to: out)
    print("\nwrote", out)
}

if let locale = options["transcribe"] {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EchoProbe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = folder.appendingPathComponent("before.wav").path
    let after = folder.appendingPathComponent("after.wav").path
    try write(mic, to: before)
    try write(cleaned, to: after)
    print("\nheard before:", try await transcribe(before, locale: Locale(identifier: locale)))
    print("heard after: ", try await transcribe(after, locale: Locale(identifier: locale)))
}
