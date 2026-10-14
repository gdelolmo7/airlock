import Accelerate

/// A real FFT of one fixed size over vDSP's packed layout, and the few
/// spectrum sums the echo remover needs.
///
/// **The packed layout's one trap, removed at the source.** A real signal of
/// `size` samples has `size / 2 + 1` frequencies, the lowest and the highest
/// purely real, and vDSP packs both into element 0: 0 Hz as its real part,
/// the top frequency as its imaginary part. vDSP's complex routines then
/// multiply element 0 as one complex number, which mixes the two. `forward`
/// drops the top frequency (8 kHz at the recogniser's 16 kHz, where speech
/// has nothing) so element 0 is an honest real number and every complex
/// routine is right on every element, with nothing to fix up after.
///
/// Scaling is vDSP's: `forward` doubles, `inverse` is scaled back so that
/// `inverse(forward(x)) == x` (less the top frequency). Only ratios of
/// spectra are ever compared, so the factor cancels everywhere it matters.
final class EchoFFT {
    let size: Int
    /// Complex elements in a packed spectrum: `size / 2`.
    let bins: Int
    private let setup: FFTSetup
    private let log2Size: vDSP_Length

    init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "power of two")
        self.size = size
        bins = size / 2
        log2Size = vDSP_Length(Int.bitWidth - 1 - size.leadingZeroBitCount)
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `time` (`size` samples) to a packed spectrum, top frequency dropped
    /// unless `keepTop`: then element 0 holds both, and is right only for
    /// a spectrum that is scaled and turned back into sound, nothing else.
    func forward(_ time: [Float], into spectrum: Spectrum, keepTop: Bool = false) {
        time.withUnsafeBufferPointer { time in
            time.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { pairs in
                spectrum.withSplit { split in
                    vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(bins))
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Forward))
                }
            }
        }
        if !keepTop { spectrum.imag[0] = 0 }
    }

    /// A packed spectrum back to `size` samples, in `time`. `work` is
    /// overwritten; `spectrum` is left as it was.
    func inverse(_ spectrum: Spectrum, into time: inout [Float], work: Spectrum) {
        work.copy(from: spectrum)
        work.withSplit { split in
            vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Inverse))
            time.withUnsafeMutableBufferPointer { time in
                time.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { pairs in
                    vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(bins))
                }
            }
        }
        var scale = 1 / Float(2 * size)
        time.withUnsafeMutableBufferPointer { time in
            vDSP_vsmul(time.baseAddress!, 1, &scale, time.baseAddress!, 1, vDSP_Length(size))
        }
    }
}

/// One packed spectrum (see `EchoFFT`): `bins` complex elements.
final class Spectrum {
    var real: [Float]
    var imag: [Float]
    let bins: Int

    init(bins: Int) {
        self.bins = bins
        real = [Float](repeating: 0, count: bins)
        imag = [Float](repeating: 0, count: bins)
    }

    func withSplit<R>(_ body: (inout DSPSplitComplex) -> R) -> R {
        real.withUnsafeMutableBufferPointer { real in
            imag.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                return body(&split)
            }
        }
    }

    func zero() {
        vDSP_vclr(&real, 1, vDSP_Length(bins))
        vDSP_vclr(&imag, 1, vDSP_Length(bins))
    }

    func copy(from other: Spectrum) {
        real.withUnsafeMutableBufferPointer { me in
            other.real.withUnsafeBufferPointer { me.baseAddress!.update(from: $0.baseAddress!, count: bins) }
        }
        imag.withUnsafeMutableBufferPointer { me in
            other.imag.withUnsafeBufferPointer { me.baseAddress!.update(from: $0.baseAddress!, count: bins) }
        }
    }

    /// `self += a * b`.
    func addProduct(_ a: Spectrum, _ b: Spectrum) {
        a.withSplit { a in
            b.withSplit { b in
                withSplit { me in
                    // Two copies of the same two pointers: one is read, one
                    // written, and Swift will not pass one variable twice.
                    var sum = me
                    vDSP_zvma(&a, 1, &b, 1, &me, 1, &sum, 1, vDSP_Length(bins))
                }
            }
        }
    }

    /// `self = conj(a) * b`.
    func setConjugateProduct(_ a: Spectrum, _ b: Spectrum) {
        a.withSplit { a in
            b.withSplit { b in
                withSplit { me in
                    vDSP_zvcmul(&a, 1, &b, 1, &me, 1, vDSP_Length(bins))
                }
            }
        }
    }

    /// `self = a - b`, three different spectra.
    func setDifference(_ a: Spectrum, _ b: Spectrum) {
        a.withSplit { a in
            b.withSplit { b in
                withSplit { me in
                    vDSP_zvsub(&a, 1, &b, 1, &me, 1, vDSP_Length(bins))
                }
            }
        }
    }

    /// Every element times its own real `gain`.
    func scale(by gain: [Float]) {
        withSplit { me in
            vDSP_vmul(me.realp, 1, gain, 1, me.realp, 1, vDSP_Length(bins))
            vDSP_vmul(me.imagp, 1, gain, 1, me.imagp, 1, vDSP_Length(bins))
        }
    }

    /// `self += other`.
    func add(_ other: Spectrum) {
        other.withSplit { other in
            withSplit { me in
                var sum = me
                vDSP_zvadd(&other, 1, &me, 1, &sum, 1, vDSP_Length(bins))
            }
        }
    }

    /// Power per element, into `out`.
    func power(into out: inout [Float]) {
        vDSP_vmma(real, 1, real, 1, imag, 1, imag, 1, &out, 1, vDSP_Length(bins))
    }
}
