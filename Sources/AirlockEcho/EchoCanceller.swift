import Accelerate

/// Takes what the Mac's speakers played out of what its microphone heard,
/// one block of 16 ms at a time, at 16 kHz.
///
/// The microphone hears the speakers changed by the room: later, quieter,
/// coloured, with echoes off the walls. Two stages undo that.
///
/// **1. A filter that learns the room.** An adaptive filter, 256 ms long,
/// learns how the speakers' sound reaches the microphone and subtracts its
/// prediction. It works on spectra, in partitions of one block each (the
/// usual partitioned frequency-domain form), so a quarter of a second of
/// room costs a few small FFTs per block. It runs as two copies: one keeps
/// learning on every block, and one is used. The used copy takes over the
/// learner's numbers only while the learner is doing better, and hands its
/// own back when the learner goes wrong. That is what keeps it steady while
/// both people talk at once, which is when a learning filter drifts.
///
/// **Never louder than the microphone.** Taking a prediction away can only
/// make the microphone quieter when the prediction is right; a filter that
/// learned from your voice over a near-silent speaker predicts a roar the
/// next time the speakers play, and taking that away adds it, turned
/// around: the other side, louder than the microphone ever heard it, then
/// turned down by the suppressor to about the level of your voice. On a
/// call that wrote the other side down as you for minutes, the filter's
/// leftover thirty times the microphone's. So a block whose leftover comes
/// out louder than the microphone gives the microphone instead, and a
/// copy whose leftover stays louder than the microphone for a few tenths
/// of a second is wiped and learns again.
///
/// **2. A suppressor for what is left.** No filter takes all of it: the
/// speakers distort, the room moves. The suppressor estimates, per
/// frequency, how much of what is left is still the speakers, and turns that
/// frequency down by that share. Two estimates, the larger wins: how much
/// of the leftover the prediction still explains (their coherence: high
/// while the filter is still learning, or after the room changed), and the
/// smallest leftover-to-prediction ratio seen lately, which is what the
/// filter can never take out (a speaker's distortion), measured whenever
/// the speakers played alone. It works on the leftover, not the microphone,
/// so while both talk your voice is set against the little echo the filter
/// left, not against all of it.
///
/// The microphone's sound never waits on the speakers: with nothing played,
/// the filter predicts nothing, every coherence is 0, and what comes out is
/// what went in. Output is one block late, the price of the suppressor's
/// overlapping windows.
final class EchoCanceller {
    static let block = 256
    static let partitions = 16

    /// How fast the learning copy learns: a share of the way to the best
    /// numbers for this block, normalised by how loud the speakers were.
    static let stepSize: Float = 0.5
    /// The quietest the suppressor turns any frequency, about −30 dB.
    static let floorGain: Float = 0.03
    /// The suppressor assumes this much more leftover echo than it measured.
    static let overdrive: Float = 3
    /// Coherence of two unrelated sounds, measured over the suppressor's
    /// short memory, is about this, not 0; below it counts as none.
    static let coherenceBias: Float = 0.15
    /// How fast the leftover ratio may climb back while the speakers play
    /// without ever playing alone: 3 dB a second.
    static let ratioRise: Float = pow(10, 0.3 / 62.5)
    /// Speaker blocks quieter than this (mean square) teach the filter
    /// nothing: there is nothing in them to learn from.
    static let quietReference: Float = 1e-8
    /// How much of the long energies each block keeps: about a third of a
    /// second (`slowMic`).
    static let slowKeep: Float = 0.95
    /// A copy whose leftover stays this much louder than the microphone
    /// (about 1 dB) is wiped.
    static let worseThanMic: Float = 1.25

    private let n = block
    private let fft = EchoFFT(size: 2 * block)
    private var bins: Int { fft.bins }

    // The speakers' last `partitions` blocks as spectra, newest first.
    private var history: [Spectrum]
    private var previousReference: [Float]
    private var learning: [Spectrum]
    private var used: [Spectrum]
    private var referencePower: [Float]

    // Two-path bookkeeping: smoothed energies of the microphone and of
    // each copy's leftover.
    private var micEnergy: Float = 0
    private var usedEnergy: Float = 0
    private var learningEnergy: Float = 0
    // The same over about a third of a second: what tells a copy gone
    // wrong from one block it got wrong.
    private var slowMic: Float = 0
    private var slowUsed: Float = 0
    private var slowLearning: Float = 0

    // Suppressor: smoothed spectra of the leftover and the prediction,
    // their cross-spectrum, the leftover ratio per frequency, and the
    // overlap carried between windows.
    private var leftoverPower: [Float]
    private var predictionPower: [Float]
    private let cross: Spectrum
    private var residualRatio: [Float]
    private var previousPrediction: [Float]
    private var previousLeftover: [Float]
    private var overlap: [Float]
    private let window: [Float]

    // Working buffers, allocated once.
    private var frame: [Float]
    private var time: [Float]
    private let echoSpectrum: Spectrum
    private let work: Spectrum
    private let work2: Spectrum
    private let predictionSpectrum: Spectrum
    private let leftoverSpectrum: Spectrum
    private var power: [Float]
    private var step: [Float]
    private var gain: [Float]

    /// Sums for the log, while the speakers played.
    private(set) var heard: Double = 0
    private(set) var leftAfterFilter: Double = 0
    private(set) var leftAfterAll: Double = 0
    private(set) var takeovers = 0
    private(set) var handbacks = 0
    /// Copies wiped for making the microphone louder, and blocks given
    /// back as the microphone for it.
    private(set) var wipes = 0
    private(set) var passedThrough = 0

    init() {
        let bins = Self.block
        func spectra() -> [Spectrum] { (0..<Self.partitions).map { _ in Spectrum(bins: bins) } }
        history = spectra()
        learning = spectra()
        used = spectra()
        previousReference = [Float](repeating: 0, count: Self.block)
        referencePower = [Float](repeating: 0, count: bins)
        leftoverPower = [Float](repeating: 0, count: bins)
        predictionPower = [Float](repeating: 0, count: bins)
        cross = Spectrum(bins: bins)
        residualRatio = [Float](repeating: 1, count: bins)
        previousPrediction = [Float](repeating: 0, count: Self.block)
        previousLeftover = [Float](repeating: 0, count: Self.block)
        overlap = [Float](repeating: 0, count: Self.block)
        // Square root of a periodic Hann, before and after: the two halves
        // of overlapping windows add back to exactly one.
        window = (0..<(2 * Self.block)).map { index in
            Float(sin(Double.pi * Double(index) / Double(2 * Self.block)))
        }
        frame = [Float](repeating: 0, count: 2 * Self.block)
        time = [Float](repeating: 0, count: 2 * Self.block)
        echoSpectrum = Spectrum(bins: bins)
        work = Spectrum(bins: bins)
        work2 = Spectrum(bins: bins)
        predictionSpectrum = Spectrum(bins: bins)
        leftoverSpectrum = Spectrum(bins: bins)
        power = [Float](repeating: 0, count: bins)
        step = [Float](repeating: 0, count: bins)
        gain = [Float](repeating: 1, count: bins)
    }

    /// Forgets the room: after the timing moved, what was learned is about
    /// the wrong moment.
    func forgetTheRoom() {
        for index in 0..<Self.partitions {
            history[index].zero()
            learning[index].zero()
            used[index].zero()
        }
        for index in 0..<n { previousReference[index] = 0 }
        for index in 0..<bins {
            referencePower[index] = 0
            residualRatio[index] = 1
        }
        micEnergy = 0
        usedEnergy = 0
        learningEnergy = 0
        slowMic = 0
        slowUsed = 0
        slowLearning = 0
    }

    /// One block in (`mic` and the speakers' `reference`, lined up, `block`
    /// samples each), the previous block out, cleaned.
    func process(mic: UnsafeBufferPointer<Float>, reference: UnsafeBufferPointer<Float>,
                 into out: UnsafeMutableBufferPointer<Float>) {
        precondition(mic.count == n && reference.count == n && out.count == n)
        let referenceLevel = Self.meanSquare(reference)

        // The speakers' newest two blocks, as the newest spectrum.
        let newest = history.removeLast()
        for index in 0..<n {
            frame[index] = previousReference[index]
            frame[n + index] = reference[index]
            previousReference[index] = reference[index]
        }
        fft.forward(frame, into: newest)
        history.insert(newest, at: 0)

        // What each copy predicts the microphone heard.
        let predictionUsed = predict(with: used)
        let leftoverUsed = (0..<n).map { mic[$0] - predictionUsed[$0] }
        let predictionLearning = predict(with: learning)
        let leftoverLearning = (0..<n).map { mic[$0] - predictionLearning[$0] }

        if referenceLevel > Self.quietReference {
            learn(from: leftoverLearning)
        }

        // Two paths: the used copy follows the learner only while the
        // learner is clearly better; a learner gone wrong is reset.
        let micNow = Self.sumOfSquares(mic)
        let usedNow = Self.sumOfSquares(leftoverUsed)
        let learningNow = Self.sumOfSquares(leftoverLearning)
        micEnergy = 0.6 * micEnergy + 0.4 * micNow
        usedEnergy = 0.6 * usedEnergy + 0.4 * usedNow
        learningEnergy = 0.6 * learningEnergy + 0.4 * learningNow
        let keep = Self.slowKeep
        slowMic = keep * slowMic + (1 - keep) * micNow
        slowLearning = keep * slowLearning + (1 - keep) * learningNow
        var leftover = leftoverUsed
        var prediction = predictionUsed
        if learningEnergy < 0.85 * usedEnergy && learningEnergy < micEnergy && slowLearning <= slowMic {
            for index in 0..<Self.partitions { used[index].copy(from: learning[index]) }
            usedEnergy = learningEnergy
            leftover = leftoverLearning
            prediction = predictionLearning
            takeovers += 1
        } else if learningEnergy > 4 * usedEnergy && learningEnergy > micEnergy {
            for index in 0..<Self.partitions { learning[index].copy(from: used[index]) }
            learningEnergy = usedEnergy
            slowLearning = slowUsed
            handbacks += 1
        }
        slowUsed = keep * slowUsed + (1 - keep) * Self.sumOfSquares(leftover)

        // Never louder than the microphone: a copy that stays louder is
        // wiped, and a block that comes out louder is the microphone.
        if slowLearning > Self.worseThanMic * slowMic {
            for index in 0..<Self.partitions { learning[index].zero() }
            learningEnergy = micEnergy
            slowLearning = slowMic
            wipes += 1
        }
        if slowUsed > Self.worseThanMic * slowMic {
            for index in 0..<Self.partitions { used[index].zero() }
            usedEnergy = micEnergy
            slowUsed = slowMic
            wipes += 1
        }
        if Self.sumOfSquares(leftover) > Self.worseThanMic * micNow {
            leftover = Array(mic)
            prediction = [Float](repeating: 0, count: n)
            passedThrough += 1
        }

        suppress(prediction: prediction, leftover: leftover,
                 speakersPlayed: referenceLevel > Self.quietReference, into: out)

        if referenceLevel > Self.quietReference {
            heard += Double(micNow)
            leftAfterFilter += Double(Self.sumOfSquares(leftover))
            leftAfterAll += Double(Self.sumOfSquares(UnsafeBufferPointer(out)))
        }
    }

    /// Overlap-save: the last block of the inverse of the filter times the
    /// speakers' history.
    private func predict(with filter: [Spectrum]) -> [Float] {
        echoSpectrum.zero()
        for index in 0..<Self.partitions {
            echoSpectrum.addProduct(filter[index], history[index])
        }
        fft.inverse(echoSpectrum, into: &time, work: work)
        return Array(time[n..<(2 * n)])
    }

    /// One normalised step of the learning copy towards a smaller leftover,
    /// each partition's change kept to the filter's own length (the
    /// gradient constraint, without which the circular sums wrap around).
    private func learn(from leftover: [Float]) {
        // The step per frequency: smaller where the speakers were loud.
        for index in 0..<bins { power[index] = 0 }
        for spectrum in history {
            spectrum.power(into: &step)
            for index in 0..<bins { power[index] += step[index] }
        }
        var mean: Float = 0
        vDSP_meanv(power, 1, &mean, vDSP_Length(bins))
        for index in 0..<bins {
            referencePower[index] = 0.7 * referencePower[index] + 0.3 * power[index]
            step[index] = Self.stepSize / (referencePower[index] + 0.01 * mean + 1e-9)
        }

        for index in 0..<n {
            frame[index] = 0
            frame[n + index] = leftover[index]
        }
        let errorSpectrum = leftoverSpectrum
        fft.forward(frame, into: errorSpectrum)
        for index in 0..<Self.partitions {
            work2.setConjugateProduct(history[index], errorSpectrum)
            work2.scale(by: step)
            fft.inverse(work2, into: &time, work: work)
            for tap in n..<(2 * n) { time[tap] = 0 }
            fft.forward(time, into: work2)
            learning[index].add(work2)
        }
    }

    /// Stage two: per frequency, the leftover turned down by the share of
    /// it that is still the speakers. Windows overlap by half; out comes
    /// the block before this one.
    private func suppress(prediction: [Float], leftover: [Float], speakersPlayed: Bool,
                          into out: UnsafeMutableBufferPointer<Float>) {
        windowed(previousPrediction, prediction, into: predictionSpectrum)
        // The top frequency is kept here, so that with nothing to take out
        // the microphone comes back exactly as it went in; it is set aside
        // while the spectrum is measured.
        windowed(previousLeftover, leftover, into: leftoverSpectrum, keepTop: true)
        for index in 0..<n {
            previousPrediction[index] = prediction[index]
            previousLeftover[index] = leftover[index]
        }
        let top = leftoverSpectrum.imag[0]
        leftoverSpectrum.imag[0] = 0

        let keep: Float = 0.8
        leftoverSpectrum.power(into: &power)
        for index in 0..<bins {
            leftoverPower[index] = keep * leftoverPower[index] + (1 - keep) * power[index]
        }
        predictionSpectrum.power(into: &power)
        for index in 0..<bins {
            predictionPower[index] = keep * predictionPower[index] + (1 - keep) * power[index]
        }
        work.setConjugateProduct(predictionSpectrum, leftoverSpectrum)
        for index in 0..<bins {
            cross.real[index] = keep * cross.real[index] + (1 - keep) * work.real[index]
            cross.imag[index] = keep * cross.imag[index] + (1 - keep) * work.imag[index]
        }

        for index in 0..<bins {
            let left = leftoverPower[index]
            let predicted = predictionPower[index]
            guard left > 0, predicted > 0 else {
                gain[index] = 1
                continue
            }
            let shared = cross.real[index] * cross.real[index] + cross.imag[index] * cross.imag[index]
            let coherence = max(0, (min(1, shared / (left * predicted)) - Self.coherenceBias)
                                   / (1 - Self.coherenceBias))
            if speakersPlayed {
                residualRatio[index] = min(residualRatio[index] * Self.ratioRise, left / predicted, 1)
            }
            let echo = max(coherence * left, Self.overdrive * residualRatio[index] * predicted)
            gain[index] = max(Self.floorGain, 1 - echo / left)
        }

        leftoverSpectrum.scale(by: gain)
        leftoverSpectrum.imag[0] = top * gain[bins - 1]
        fft.inverse(leftoverSpectrum, into: &time, work: work)
        for index in 0..<n {
            out[index] = overlap[index] + time[index] * window[index]
            overlap[index] = time[n + index] * window[n + index]
        }
    }

    private func windowed(_ first: [Float], _ second: [Float], into spectrum: Spectrum, keepTop: Bool = false) {
        for index in 0..<n {
            frame[index] = first[index] * window[index]
            frame[n + index] = second[index] * window[n + index]
        }
        fft.forward(frame, into: spectrum, keepTop: keepTop)
    }

    static func sumOfSquares(_ values: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        vDSP_svesq(values.baseAddress!, 1, &sum, vDSP_Length(values.count))
        return sum
    }

    static func sumOfSquares(_ values: [Float]) -> Float {
        values.withUnsafeBufferPointer { sumOfSquares($0) }
    }

    static func meanSquare(_ values: UnsafeBufferPointer<Float>) -> Float {
        values.isEmpty ? 0 : sumOfSquares(values) / Float(values.count)
    }
}
