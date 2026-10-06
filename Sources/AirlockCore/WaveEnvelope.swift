import Foundation

/// Turns raw spectrum magnitudes into bar heights a wave can be drawn from.
///
/// The FFT is mechanical and lives in the app beside the audio tap. This is the
/// part with judgement in it, and every one of these rules exists because the
/// naive version fails in a way you only notice with real music playing:
///
/// - **Normalised against a rolling peak, not an absolute scale.** Digital audio
///   is nowhere near full scale most of the time, and a quiet track fed through
///   a fixed scale is a flat line. The peak decays, so the wave re-scales itself
///   to whatever is playing now.
/// - **The peak decays but never falls below a floor.** Without the floor,
///   silence drives the reference to zero and the first whisper of noise then
///   normalises to full height — the wave thrashes wildly between tracks.
/// - **Attack is faster than decay.** Ears expect a transient to hit instantly
///   and fade; symmetric smoothing looks like syrup, and no smoothing at all
///   looks like a seizure at 60fps.
///
/// Pure and value-typed so all of that is testable in microseconds rather than
/// by playing music and squinting at a 16pt glyph.
public struct WaveEnvelope: Equatable, Sendable {
    /// Bars in the glyph. Matches `MediaWaveView`, which is the only consumer.
    public static let bandCount = 5

    /// How much of the previous level survives one frame. Attack is the rise,
    /// release the fall — see the note above about symmetry.
    public static let attack: Double = 0.35
    public static let release: Double = 0.82

    /// The reference peak bleeds away at this rate per frame, so a single loud
    /// moment does not squash the next three minutes.
    ///
    /// Was 0.995, which a test caught: at the ~20 frames a second this runs at,
    /// that takes half a minute to climb back from one full-scale cymbal crash —
    /// so the wave sat at a third of its height for the rest of the song. 0.97
    /// re-scales in about five seconds, which reads as the wave adjusting rather
    /// than as it being broken.
    public static let peakDecay: Double = 0.97
    /// And never below this, so silence cannot make noise look like a drum hit.
    ///
    /// Deliberately well under any real musical magnitude. It was 0.02, and that
    /// was above the quiet end of actual music — which meant quiet tracks were
    /// normalised against the FLOOR instead of against themselves, and the same
    /// song played softly drew a different wave from the same song played loud.
    /// This is the line between "quiet" and "not playing", nothing more.
    public static let peakFloor: Double = 0.005

    /// Bars never collapse entirely: a wave flat on the floor reads as broken
    /// rather than quiet, and something IS playing whenever this is on screen.
    public static let minimumLevel: Double = 0.12

    /// One rolling peak PER BAND, not one shared across all five.
    ///
    /// Measured against real music: with a single shared peak the bands came in
    /// at roughly 47, 12, 5, 3, 2 — because musical energy falls off steeply
    /// with frequency — so the top two bars sat on the floor permanently and
    /// only the bass moved. Half a wave.
    ///
    /// The alternative was a hand-tuned frequency tilt, and it would have been
    /// tuned against whichever song happened to be playing. Per-band peaks are
    /// self-tuning: each bar shows how loud its own band is against its own
    /// recent history, so all five stay alive across any material. The cost is
    /// that the glyph no longer draws the spectrum's true SHAPE — a real
    /// spectrum analyser it is not, and for a 16pt decoration that is the right
    /// trade.
    private var peaks: [Double]

    public private(set) var levels: [Double]

    public init() {
        levels = Array(repeating: Self.minimumLevel, count: Self.bandCount)
        peaks = Array(repeating: Self.peakFloor, count: Self.bandCount)
    }

    /// Feed one frame of band magnitudes; get back the heights to draw.
    ///
    /// Extra bands are ignored and missing ones read as silence, so a caller
    /// that changes its FFT binning cannot crash the UI — it just looks wrong,
    /// which is recoverable.
    @discardableResult
    public mutating func ingest(_ bands: [Double]) -> [Double] {
        let frame = (0..<Self.bandCount).map { index -> Double in
            guard index < bands.count else { return 0 }
            let value = bands[index]
            return value.isFinite ? max(0, value) : 0
        }

        for index in 0..<Self.bandCount {
            peaks[index] = max(peaks[index] * Self.peakDecay, Self.peakFloor)
            peaks[index] = max(peaks[index], frame[index])
        }

        levels = (0..<Self.bandCount).map { index in
            let previous = levels[index]
            let target = max(Self.minimumLevel, min(1, frame[index] / peaks[index]))
            // Rising and falling are different gestures; see `attack`.
            let smoothing = target > previous ? Self.attack : Self.release
            let next = previous * smoothing + target * (1 - smoothing)
            return max(Self.minimumLevel, min(1, next))
        }
        return levels
    }

    /// No audio this frame — the tap stopped, the track paused, the player quit.
    /// Decays to the floor rather than snapping, so a pause looks like a wave
    /// settling instead of a glyph blinking out.
    @discardableResult
    public mutating func idle() -> [Double] {
        ingest(Array(repeating: 0, count: Self.bandCount))
    }

    /// True once everything has settled, so a caller can stop redrawing rather
    /// than animating a flat line for as long as the app is open.
    public var isSettled: Bool {
        levels.allSatisfy { $0 <= Self.minimumLevel + 0.001 }
    }
}
