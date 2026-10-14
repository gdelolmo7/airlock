import Foundation
@testable import AirlockEcho

/// A room in numbers: something like speech, a speaker that reaches the
/// microphone late, quieter and with echoes off the walls, and the two
/// streams handed to the remover in pieces, as the Mac hands them over.
///
/// Everything is drawn from a seeded generator, so a failure is the same
/// failure on every run.
struct SimulatedRoom {
    static let rate = 16_000

    struct Generator: RandomNumberGenerator {
        var state: UInt64
        /// Seeds next to each other give unrelated sequences.
        init(state seed: UInt64) {
            var mixed = (seed &+ 0x9E37_79B9_7F4A_7C15) &* 0xBF58_476D_1CE4_E5B9
            mixed ^= mixed >> 31
            state = mixed == 0 ? 1 : mixed
        }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func gaussian() -> Float {
            let u1 = Float.random(in: Float.ulpOfOne..<1, using: &self)
            let u2 = Float.random(in: 0..<1, using: &self)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// Noise shaped like talk: darker than white, in syllables four times
    /// a second, in spurts of one to three seconds with pauses between.
    /// `level` is the loudness while talking (root mean square, roughly).
    static func talk(seconds: Double, level: Float, seed: UInt64, startsTalking: Bool = true) -> [Float] {
        var generator = Generator(state: seed)
        let count = Int(seconds * Double(rate))
        var out = [Float](repeating: 0, count: count)
        var low: Float = 0
        var talking = startsTalking
        var spurtLeft = Int(Double.random(in: 1...3, using: &generator) * Double(rate))
        let syllable = Double.random(in: 3.5...5, using: &generator)
        for index in 0..<count {
            if spurtLeft == 0 {
                talking.toggle()
                let length = talking ? Double.random(in: 1...3, using: &generator)
                                     : Double.random(in: 0.3...1.2, using: &generator)
                spurtLeft = Int(length * Double(rate))
            }
            spurtLeft -= 1
            low = 0.85 * low + 0.15 * generator.gaussian()
            guard talking else { continue }
            let phase = Double(index) / Double(rate) * syllable
            let envelope = Float(pow(abs(sin(.pi * phase)), 0.7))
            out[index] = low * envelope * level * 3
        }
        return out
    }

    /// A speaker `delay` samples away: the direct sound at `gain`, then a
    /// tail of reflections dying away over about 60 ms.
    static func room(delay: Int, gain: Float, seed: UInt64) -> [Float] {
        var generator = Generator(state: seed)
        let tail = 2_400
        var response = [Float](repeating: 0, count: delay + tail)
        response[delay] = gain
        for index in 1..<tail {
            let decay = exp(-Float(index) / 400)
            response[delay + index] += gain * 0.35 * decay * generator.gaussian()
        }
        return response
    }

    static func convolve(_ signal: [Float], with response: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: signal.count)
        let taps = response.enumerated().filter { $0.element != 0 }
        for (lag, weight) in taps {
            var index = lag
            while index < signal.count {
                out[index] += signal[index - lag] * weight
                index += 1
            }
        }
        return out
    }

    static func noise(count: Int, level: Float, seed: UInt64) -> [Float] {
        var generator = Generator(state: seed)
        return (0..<count).map { _ in generator.gaussian() * level }
    }

    static func add(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map(+)
    }

    /// Hands `mic` and `reference` to a remover in pieces, in the order
    /// they would arrive: the microphone in `micPiece`-sample pieces, the
    /// speakers in `referencePiece`-sample ones starting `referenceStart`
    /// seconds after the microphone (negative: before). Each piece arrives
    /// the moment its last sample was captured, plus up to `jitter` seconds.
    /// Returns the cleaned microphone, finished.
    static func run(_ remover: EchoRemover, mic: [Float], reference: [Float]?,
                    referenceStart: Double = 0, micPiece: Int = 1_600, referencePiece: Int = 480,
                    jitter: Double = 0, seed: UInt64 = 7) -> [Float] {
        var generator = Generator(state: seed)
        enum Piece { case mic(Range<Int>), reference(Range<Int>) }
        var pieces: [(time: Double, piece: Piece)] = []
        func spread(_ count: Int, by size: Int, start: Double, _ make: (Range<Int>) -> Piece) {
            var from = 0
            while from < count {
                let to = min(count, from + size)
                let time = start + Double(to) / Double(rate)
                    + Double.random(in: 0...max(jitter, 0), using: &generator)
                pieces.append((time, make(from..<to)))
                from = to
            }
        }
        spread(mic.count, by: micPiece, start: 0) { .mic($0) }
        if let reference {
            spread(reference.count, by: referencePiece, start: referenceStart) { .reference($0) }
        }
        pieces.sort { $0.time < $1.time }
        var out: [Float] = []
        for (time, piece) in pieces {
            switch piece {
            case .mic(let range):
                out += remover.addMicrophone(Array(mic[range]), at: time)
            case .reference(let range):
                remover.addReference(Array(reference![range]), at: time)
            }
        }
        return out + remover.finish()
    }

    static func power(_ signal: ArraySlice<Float>) -> Double {
        guard !signal.isEmpty else { return 0 }
        return signal.reduce(0) { $0 + Double($1) * Double($1) } / Double(signal.count)
    }

    static func decibels(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-30)) }

    /// Seconds to sample indices.
    static func span(_ from: Double, _ to: Double) -> Range<Int> {
        Int(from * Double(rate))..<Int(to * Double(rate))
    }
}
