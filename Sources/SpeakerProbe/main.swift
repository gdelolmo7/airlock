import AVFoundation
import AirlockCore
import FluidDiarizer
import CoreML
import Foundation
import Synchronization

// Runs the call-voices model over sound files played one after another, the
// way a call feeds it (a tenth of a second at a time), and prints who it
// heard when, what that cost, and how each file's line would be numbered.
//
//   swift run SpeakerProbe [--model DIR] [--gap SECONDS] [--units all/ane/gpu/cpu] a_1.aiff b_1.aiff a_2.aiff
//
// A file's label is its name up to the first "_": files with the same label
// are the same voice, so the probe can say whether the model agreed. Make
// some with `say -v Samantha -o samantha_1.aiff "…"`.

let preset = "c128-split-w8a8"
var arguments = Array(CommandLine.arguments.dropFirst())
var model = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/Airlock/Models/voices", isDirectory: true)
var gap = 0.4
var units = MLComputeUnits.all
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    guard let value = arguments.first else { break }
    arguments.removeFirst()
    switch first {
    case "--model": model = URL(fileURLWithPath: value, isDirectory: true)
    case "--gap": gap = Double(value) ?? gap
    case "--units":
        switch value {
        case "cpu": units = .cpuOnly
        case "gpu": units = .cpuAndGPU
        case "ane": units = .cpuAndNeuralEngine
        default: units = .all
        }
    default: FileHandle.standardError.write(Data("unknown option \(first)\n".utf8)); exit(2)
    }
}
guard !arguments.isEmpty else {
    print("usage: SpeakerProbe [--model DIR] [--gap SECONDS] file…")
    exit(2)
}

/// The file as 16 kHz mono floats: its first channel, resampled.
func read(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let rate = file.processingFormat.sampleRate
    guard let whole = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: whole)
    guard let channel = whole.floatChannelData?[0] else { return [] }
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(whole.frameLength)))
    guard rate != 16_000 else { return samples }
    guard let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                     interleaved: false),
          let converter = AVAudioConverter(from: source, to: target),
          let out = AVAudioPCMBuffer(pcmFormat: target,
                                     frameCapacity: AVAudioFrameCount(Double(samples.count) * 16_000 / rate) + 1024)
    else { return [] }
    // Built inside the block, from plain samples: the block is `@Sendable`.
    let once = Once()
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        guard once.claim(), let input = AVAudioPCMBuffer(pcmFormat: source,
                                                         frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else {
            status.pointee = .endOfStream
            return nil
        }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        status.pointee = .haveData
        return input
    }
    if let error { throw error }
    guard let data = out.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
}

final class Once: Sendable {
    private let done = Atomic<Bool>(false)
    func claim() -> Bool { !done.exchange(true, ordering: .relaxed) }
}

struct Part {
    let label: String
    let start: Double
    let end: Double
}

var audio: [Float] = []
var parts: [Part] = []
for path in arguments {
    let samples = try read(path)
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let label = String(name.split(separator: "_").first ?? Substring(name))
    let start = Double(audio.count) / 16_000
    audio += samples
    parts.append(Part(label: label, start: start, end: Double(audio.count) / 16_000))
    audio += [Float](repeating: 0, count: Int(gap * 16_000))
}
print(String(format: "%d file(s), %.1f s of sound", parts.count, Double(audio.count) / 16_000))

let config = Nemotron3Config.preset(named: preset)!
let loadStart = Date()
let models = try await Nemotron3Models.load(config: config, directory: model, computeUnits: units)
let diarizer = Nemotron3Diarizer(config: config, models: models)
print(String(format: "model loaded in %.2f s", Date().timeIntervalSince(loadStart)))

var tracker = CallVoices.Tracker(origin: 0)
var compute = 0.0
var steps = 0
@MainActor func take(_ results: [Nemotron3ChunkResult]) {
    for result in results {
        tracker.add(result.probabilities, frames: result.frameCount, voices: result.numSpeakers)
        steps += 1
    }
}
let piece = 1_600
var at = 0
while at < audio.count {
    diarizer.appendAudio(Array(audio[at..<min(at + piece, audio.count)]))
    at += piece
    let started = Date()
    let results = try diarizer.processBufferedAudio()
    let took = Date().timeIntervalSince(started)
    if !results.isEmpty { print(String(format: "  step at %5.1f s took %.2f s", Double(at) / 16_000, took)) }
    take(results)
    compute += took
}
let started = Date()
take(try diarizer.finishStream())
compute += Date().timeIntervalSince(started)
tracker.finish()
let seconds = Double(audio.count) / 16_000
print(String(format: "%d step(s), model %.2f s for %.1f s of sound (%.3fx real time)",
             steps, compute, seconds, compute / seconds))

print("\nheard:")
for span in tracker.spans {
    print(String(format: "  voice %d  %6.2f – %6.2f", span.voice, span.start, span.end))
}

// Each file as one line from the other side, numbered as the app would.
var record = MeetingRecord(bundleID: "probe", appName: "Probe", startedAt: Date(),
                           segments: parts.map { MeetingSegment(speaker: .them, start: $0.start, end: $0.end,
                                                                 text: $0.label) })
let outcome = CallVoices.number(&record, spans: tracker.spans, words: [])
print("\nnumbered: \(outcome.people) people from \(outcome.heard) heard, \(outcome.folded) folded"
      + (outcome.reason.map { " (\($0))" } ?? ""))
var byLabel: [String: Set<String>] = [:]
var byPerson: [String: Set<String>] = [:]
for (part, segment) in zip(parts, record.segments) {
    let person = record.label(for: segment)
    print(String(format: "  %6.2f – %6.2f  %@ → %@", part.start, part.end, part.label, person))
    byLabel[part.label, default: []].insert(person)
    byPerson[person, default: []].insert(part.label)
}
let split = byLabel.filter { $0.value.count > 1 }.keys.sorted()
let merged = byPerson.filter { $0.value.count > 1 }.keys.sorted()
print("\none voice given more than one number: \(split.isEmpty ? "none" : split.joined(separator: ", "))")
print("one number given more than one voice: \(merged.isEmpty ? "none" : merged.joined(separator: ", "))")
exit(split.isEmpty && merged.isEmpty ? 0 : 1)
