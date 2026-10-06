import Foundation

/// How loud the microphone is, as the listening wave draws it.
///
/// **The bug this exists for.** The wave scaled the raw sample peak linearly
/// (`peak * 4`). That was tolerable while the wave was 22pt tall; when it moved
/// under the cloud (ab00eda) it shrank to a 7.5pt swing, and ordinary speech
/// into the built-in microphone peaks around 0.03–0.15 over a 120ms window — a
/// movement of one or two points. The owner, 2026-10-04: "it appears but it's
/// static and doesn't move".
///
/// Loudness is heard on a log scale, so it is drawn on one: decibels, with a
/// quiet room at the floor and normal speech across most of the height.
public enum MicLevel {
    /// Quieter than this is the room, drawn flat. A silent built-in microphone
    /// reads 0.001–0.003 (−60 to −50 dB); a quiet room sits near the top of that.
    public static let floorDecibels: Double = -50
    /// Louder than this fills the bar. Speech held at laptop distance peaks
    /// around −20 to −15 dB.
    public static let ceilingDecibels: Double = -12

    /// A sample peak (0…1) as a height fraction (0…1).
    public static func scale(_ peak: Float) -> Double {
        guard peak > 0, peak.isFinite else { return 0 }
        let decibels = 20 * log10(Double(min(peak, 1)))
        let fraction = (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)
        return min(1, max(0, fraction))
    }

    /// The wave's bars, centre outwards: the centre is the newest reading and
    /// each pair further out is one reading older, so a word ripples outward
    /// instead of every bar pulsing together.
    ///
    /// Still driven only by what the microphone hears — there is no idle
    /// animation, so a quiet room is a still wave, which is the point of it.
    ///
    /// - Parameter recent: scaled levels, newest LAST. Missing history is 0.
    /// - Returns: `2 * rings - 1` heights, left to right.
    public static func ripple(_ recent: [Double], rings: Int = 3) -> [Double] {
        guard rings > 0 else { return [] }
        let byAge = (0..<rings).map { age in
            recent.count > age ? recent[recent.count - 1 - age] : 0
        }
        let outward = Array(byAge.reversed())          // oldest … newest
        return outward + byAge.dropFirst()             // … newest … oldest
    }
}
