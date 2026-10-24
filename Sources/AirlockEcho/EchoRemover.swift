import Accelerate

/// Keeps what the Mac's speakers played out of what its microphone hears, so
/// that on speakers the other side of a call is not written down as you.
///
/// Fed two streams as they arrive, both mono at 16 kHz: the microphone, and
/// everything the Mac plays (the reference). Hands back the microphone,
/// cleaned, sample for sample: the same number of samples in the same order,
/// a little later. Nothing is kept beyond the last few seconds.
///
/// **Lining the two up is most of the job.** The streams start at different
/// moments and arrive in different-sized pieces, so their clocks are known
/// only to within a few tenths of a second; the room then adds its own delay,
/// a few milliseconds through a MacBook's speakers and a quarter of a second
/// or more through Bluetooth ones. Arrival times give the rough line-up
/// (each stream's start, with gaps in the reference filled with silence so
/// its count keeps pace with the clock). `EchoDelay` then finds the real
/// delay by correlation, every second (twice a second until it is found),
/// from up to the last four seconds, whenever the speakers have been
/// playing. The canceller (`EchoCanceller`) is set
/// to start listening a little before that delay and learns the rest.
///
/// **The microphone never waits for long.** Each block waits for the
/// speakers' sound it needs, at most `maxWait`; past that, missing sound is
/// taken as silence. With no reference at all (the tap never started), every
/// block goes straight through unchanged. Headphones need no special case:
/// the microphone hears no speakers, nothing lines up, the filter learns
/// nothing, and the microphone comes out as it went in.
public final class EchoRemover {
    /// What the remover did, for the log.
    public struct Report: Equatable, Sendable {
        /// The room's delay, once one has been found.
        public var delayMilliseconds: Double?
        /// How clear the last delay found was (`EchoDelay.Estimate`).
        public var strength: Float = 0
        /// Delays found clearly enough to use, and times the line-up moved.
        public var estimates = 0
        public var realigned = 0
        /// Seconds of microphone handled, and of those, seconds while the
        /// speakers played.
        public var micSeconds: Double = 0
        public var speakersSeconds: Double = 0
        /// How much quieter the microphone came out while the speakers
        /// played, after the filter and after everything, in dB.
        public var filterDB: Double = 0
        public var totalDB: Double = 0
        /// Blocks that went through without the speakers' sound arriving
        /// in time.
        public var unmatchedBlocks = 0
        /// Filter copies wiped for making the microphone louder, and
        /// blocks given back as the microphone for it (`EchoCanceller`).
        public var wipes = 0
        public var passedThrough = 0
    }

    public static let sampleRate = 16_000.0
    /// The longest a microphone block waits for the speakers' sound.
    public static let maxWait = 0.6
    /// Delays searched: the microphone up to a second behind the speakers,
    /// or by the clocks' error, up to 0.4 s ahead.
    static let maxLagSeconds = 1.0
    static let maxLeadSeconds = 0.4
    /// A delay found must stand out this far from the noise to be used.
    static let clearStrength: Float = 8
    /// The canceller starts listening this long before the delay found, in
    /// case the room has a shorter path than the loudest one.
    static let earlyBlocks = 3
    /// A newly found delay this close to the one in use changes nothing:
    /// the filter's 256 ms covers it.
    static let closeEnough = 0.024
    /// Before any delay is found: a MacBook's own speakers.
    static let assumedDelay = 0.05
    /// Once a delay is in use, a different one must be at least this share
    /// as clear as the delay in use last read: on a call, the line-up in use
    /// read at 40 and stray readings at 8 to 11 moved it anyway, each move
    /// throwing away what the filter had learned.
    static let clearAgainstLock: Float = 0.5
    /// How much of the delay in use's clarity is still counted after each
    /// search that did not read it again: halved in about fourteen
    /// searches, so a real change of room wins in the end.
    static let lockFades: Float = 0.95

    private let n = EchoCanceller.block
    private let rate = Int(sampleRate)
    private let canceller = EchoCanceller()

    // The speakers: samples by absolute index, the oldest kept first.
    private var reference: [Float] = []
    private var referenceStart = 0
    private var referenceCount: Int { referenceStart + reference.count }
    private var referenceOrigin: Double?

    // The microphone: samples not yet cleaned, and the last few seconds of
    // what was, for the delay search.
    private var pending: [Float] = []
    private var micDone = 0
    private var micOrigin: Double?
    private var lastArrival = 0.0
    private var history: [Float] = []
    private var historyStart = 0

    private var lag: Int
    /// The last delay found clearly; `lag` follows it only when it moves
    /// far enough to matter.
    private var measured: Int?
    private var found = false
    /// The last reading of the delay in use: the one moved to, or one
    /// close enough to it to leave the line-up where it is.
    private var agreed: Int?
    /// How clear the delay in use last read, fading (`lockFades`).
    private var lockStrength: Float = 0
    /// A different delay read once, and where the microphone window it was
    /// read from ended: the next reading that agrees counts only from a
    /// window after that, not from mostly the same seconds.
    private var candidate: (lag: Int, end: Int)?
    private var blocksSinceSearch = 0
    private var skipFirstBlock = true
    private var blocks = 0
    private var speakerBlocks = 0
    private var report = Report()

    public init() {
        lag = Int(Self.assumedDelay * Self.sampleRate)
    }

    /// The speakers' sound, as it arrives. `time`: seconds on a steady
    /// clock at its arrival, the same clock as the microphone's.
    public func addReference(_ samples: [Float], at time: Double) {
        guard !samples.isEmpty else { return }
        if referenceOrigin == nil {
            referenceOrigin = time - Double(samples.count) / Self.sampleRate
            referenceStart = 0
        }
        // A gap (the tap rebuilt, the Mac busy) is filled with silence, so
        // the count keeps pace with the clock and the line-up holds.
        if let origin = referenceOrigin {
            let expected = Int((time - origin) * Self.sampleRate)
            let missing = expected - (referenceCount + samples.count)
            if missing > Int(0.3 * Self.sampleRate) {
                reference.append(contentsOf: repeatElement(0, count: missing))
            }
        }
        reference.append(contentsOf: samples)
        // Eight seconds is the most any block or search reaches back.
        let keep = 8 * rate
        if reference.count > keep + rate {
            let drop = reference.count - keep
            reference.removeFirst(drop)
            referenceStart += drop
        }
    }

    /// The microphone's sound, as it arrives; returns what is ready of it,
    /// cleaned.
    public func addMicrophone(_ samples: [Float], at time: Double) -> [Float] {
        if micOrigin == nil, !samples.isEmpty {
            micOrigin = time - Double(samples.count) / Self.sampleRate
        }
        lastArrival = time
        pending.append(contentsOf: samples)
        return clean(waiting: true)
    }

    /// Everything still held, cleaned: the end of the microphone's stream.
    public func finish() -> [Float] {
        var out = clean(waiting: false)
        // A part-block is made whole with silence, and only its real part
        // kept.
        let left = pending.count
        if left > 0 {
            pending.append(contentsOf: repeatElement(0, count: n - left))
            out += clean(waiting: false)
        }
        // The canceller is a block behind: one more block of nothing brings
        // the last real one out.
        guard blocks > 0 else { return out }
        pending = [Float](repeating: 0, count: n)
        out += clean(waiting: false).prefix(left > 0 ? left : n)
        pending = []
        return out
    }

    public var currentReport: Report {
        var report = self.report
        report.micSeconds = Double(blocks * n) / Self.sampleRate
        report.speakersSeconds = Double(speakerBlocks * n) / Self.sampleRate
        report.delayMilliseconds = agreed.map { Double($0) / Self.sampleRate * 1000 }
        report.wipes = canceller.wipes
        report.passedThrough = canceller.passedThrough
        if canceller.leftAfterFilter > 0 {
            report.filterDB = 10 * log10(canceller.heard / canceller.leftAfterFilter)
        }
        if canceller.leftAfterAll > 0 {
            report.totalDB = 10 * log10(canceller.heard / canceller.leftAfterAll)
        }
        return report
    }

    // MARK: - Cleaning

    /// Where the speakers' sample for microphone sample `i` is, before the
    /// room's delay: the two streams' starts, by the clock.
    private var offset: Int? {
        guard let micOrigin, let referenceOrigin else { return nil }
        return Int(((micOrigin - referenceOrigin) * Self.sampleRate).rounded())
    }

    private func clean(waiting: Bool) -> [Float] {
        var out: [Float] = []
        var micBlock = [Float](repeating: 0, count: n)
        var speakerBlock = [Float](repeating: 0, count: n)
        var cleaned = [Float](repeating: 0, count: n)
        while pending.count >= n {
            let start = micDone
            let lead = offset.map { $0 - lag + Self.earlyBlocks * n }
            if waiting, let lead, referenceCount < start + n + lead {
                let blockEnd = (micOrigin ?? 0) + Double(start + n) / Self.sampleRate
                if lastArrival - blockEnd < Self.maxWait { break }
            }
            for index in 0..<n { micBlock[index] = pending[index] }
            pending.removeFirst(n)
            var matched = lead == nil
            if let lead {
                matched = fill(&speakerBlock, from: start + lead)
            } else {
                for index in 0..<n { speakerBlock[index] = 0 }
            }
            if !matched { report.unmatchedBlocks += 1 }
            micBlock.withUnsafeBufferPointer { mic in
                speakerBlock.withUnsafeBufferPointer { speakers in
                    cleaned.withUnsafeMutableBufferPointer { cleaned in
                        canceller.process(mic: mic, reference: speakers, into: cleaned)
                    }
                }
            }
            micDone += n
            blocks += 1
            if speakerBlock.contains(where: { $0 != 0 }) { speakerBlocks += 1 }
            remember(micBlock, at: start)
            if skipFirstBlock {
                skipFirstBlock = false
            } else {
                out += cleaned
            }
            // Twice a second until the delay is known, then once.
            blocksSinceSearch += 1
            if blocksSinceSearch * n >= (measured == nil ? rate / 2 : rate) {
                blocksSinceSearch = 0
                searchForDelay()
            }
        }
        return out
    }

    /// The speakers' block starting at absolute index `start`, silence
    /// where none was kept or none has arrived. False when part of it had
    /// not arrived.
    private func fill(_ block: inout [Float], from start: Int) -> Bool {
        var complete = true
        for index in 0..<n {
            let at = start + index - referenceStart
            if at >= 0, at < reference.count {
                block[index] = reference[at]
            } else {
                block[index] = 0
                if start + index >= referenceCount { complete = false }
            }
        }
        return complete
    }

    private func remember(_ block: [Float], at start: Int) {
        if history.isEmpty { historyStart = start }
        history += block
        let keep = 6 * rate
        if history.count > keep + rate {
            let drop = history.count - keep
            history.removeFirst(drop)
            historyStart += drop
        }
    }

    // MARK: - Lining up

    /// Looks for the room's delay in the last few seconds, when the
    /// speakers played enough of them, and moves the line-up when a clear
    /// new one is found (twice, unless it is the first).
    private func searchForDelay() {
        guard let offset else { return }
        let maxLag = Int(Self.maxLagSeconds * Self.sampleRate)
        let maxLead = Int(Self.maxLeadSeconds * Self.sampleRate)
        // The window ends far enough back that the speakers' sound after it
        // has arrived.
        let end = min(micDone, referenceCount - offset - maxLead)
        // Before the speakers' stream began, nothing was played: silence.
        // Once its oldest seconds are dropped, the window starts later.
        var earliest = historyStart
        if referenceStart > 0 { earliest = max(earliest, referenceStart - offset + maxLag) }
        let start = max(earliest, end - 4 * rate)
        guard end - start >= 3 * rate / 2 else { return }
        let referenceFrom = start + offset - maxLag
        let referenceTo = end + offset + maxLead
        guard referenceTo <= referenceCount else { return }
        let speakers = (referenceFrom..<referenceTo).map { at in
            at >= referenceStart ? reference[at - referenceStart] : 0
        }
        guard Self.playedFor(speakers, atLeast: rate) else { return }
        let mic = Array(history[(start - historyStart)..<(end - historyStart)])
        guard let estimate = EchoDelay.estimate(mic: mic, reference: speakers,
                                                maxLag: maxLag, maxLead: maxLead) else { return }
        report.strength = estimate.strength
        lockStrength *= Self.lockFades
        guard estimate.strength >= Self.clearStrength else { return }
        report.estimates += 1
        measured = estimate.lag
        // Close to the line-up in use, the filter already covers it: moving
        // would only throw away what it has learned.
        let close = Int(Self.closeEnough * Self.sampleRate)
        if abs(estimate.lag - lag) <= close {
            // A guess this close counts as found: from now on only a
            // clear, confirmed reading moves it.
            found = true
            agreed = estimate.lag
            lockStrength = max(lockStrength, estimate.strength)
            candidate = nil
            return
        }
        // Further off, the first clear finding is taken at once (until then
        // the line-up is a guess). A change once found must be about as
        // clear as the delay in use, and read again from fresh seconds.
        if found {
            guard estimate.strength >= Self.clearAgainstLock * lockStrength else { return }
            guard let candidate, abs(candidate.lag - estimate.lag) <= rate / 500 else {
                self.candidate = (estimate.lag, end)
                return
            }
            guard start >= candidate.end else { return }
        }
        lag = estimate.lag
        found = true
        agreed = estimate.lag
        lockStrength = estimate.strength
        candidate = nil
        report.realigned += 1
        canceller.forgetTheRoom()
    }

    /// Whether at least `samples` of `speakers` (counted in blocks) carry
    /// sound.
    private static func playedFor(_ speakers: [Float], atLeast samples: Int) -> Bool {
        let n = EchoCanceller.block
        var loud = 0
        speakers.withUnsafeBufferPointer { all in
            var start = 0
            while start + n <= all.count {
                let block = UnsafeBufferPointer(rebasing: all[start..<(start + n)])
                if EchoCanceller.meanSquare(block) > EchoCanceller.quietReference { loud += n }
                start += n
            }
        }
        return loud >= samples
    }
}
