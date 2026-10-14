import Accelerate

/// How late the speakers' sound reaches the microphone, found by lining the
/// two up.
///
/// The cross-correlation of the two, with every frequency weighted the same
/// (the phase transform, "GCC-PHAT"): loud low voices would otherwise smear
/// the peak over tens of milliseconds, and a room's colouring with it. What
/// is left is a sharp peak at the delay when the speakers are what the
/// microphone hears, and noise when they are not (headphones, or a quiet
/// call).
enum EchoDelay {
    struct Estimate: Equatable {
        /// Samples the microphone is behind the speakers. Negative is
        /// possible: the two streams' starts are only known to within a
        /// few tenths of a second.
        var lag: Int
        /// The peak over the correlation's typical size: about 4 for
        /// noise (the largest of thousands of random values), far higher
        /// for a real echo.
        var strength: Float
    }

    /// `mic` is a window of the microphone; `reference` the speakers from
    /// `maxLag` samples before that window's start to `maxLead` samples after
    /// its end, so `reference[maxLag + i]` is the speakers' sample at the
    /// microphone's `i` as far as the clocks say.
    static func estimate(mic: [Float], reference: [Float], maxLag: Int, maxLead: Int) -> Estimate? {
        guard !mic.isEmpty, reference.count == mic.count + maxLag + maxLead else { return nil }
        var size = 1
        while size < reference.count + mic.count { size <<= 1 }
        let fft = EchoFFT(size: size)
        let bins = fft.bins

        var padded = [Float](repeating: 0, count: size)
        padded.replaceSubrange(0..<mic.count, with: mic)
        let micSpectrum = Spectrum(bins: bins)
        fft.forward(padded, into: micSpectrum)
        padded = [Float](repeating: 0, count: size)
        padded.replaceSubrange(0..<reference.count, with: reference)
        let referenceSpectrum = Spectrum(bins: bins)
        fft.forward(padded, into: referenceSpectrum)

        // conj(mic) × speakers, each frequency brought to the same size.
        let cross = Spectrum(bins: bins)
        cross.setConjugateProduct(micSpectrum, referenceSpectrum)
        var magnitude = [Float](repeating: 0, count: bins)
        cross.power(into: &magnitude)
        var floor: Float = 0
        vDSP_maxv(magnitude, 1, &floor, vDSP_Length(bins))
        guard floor > 0 else { return nil }
        floor *= 1e-10
        let weight = magnitude.map { 1 / (sqrt($0) + sqrt(floor)) }
        cross.scale(by: weight)

        // correlation[k] = Σ mic[i] · reference[i + k]: the microphone at i
        // matches the speakers at maxLag + i − lag, so lag = maxLag − k.
        var correlation = [Float](repeating: 0, count: size)
        fft.inverse(cross, into: &correlation, work: Spectrum(bins: bins))
        let range = 0...(maxLag + maxLead)
        var best = range.lowerBound
        var sumOfSquares: Float = 0
        // Either sign: a speaker wired the other way round flips the echo.
        for k in range {
            sumOfSquares += correlation[k] * correlation[k]
            if abs(correlation[k]) > abs(correlation[best]) { best = k }
        }
        let typical = (sumOfSquares / Float(range.count)).squareRoot()
        guard typical > 0 else { return nil }
        return Estimate(lag: maxLag - best, strength: abs(correlation[best]) / typical)
    }
}
