import XCTest
@testable import AirlockCore

final class WaveEnvelopeTests: XCTestCase {
    private func settle(_ envelope: inout WaveEnvelope, _ bands: [Double], frames: Int = 60) {
        for _ in 0..<frames { envelope.ingest(bands) }
    }

    func testStartsAtTheFloorRatherThanZero() {
        let envelope = WaveEnvelope()
        XCTAssertEqual(envelope.levels.count, WaveEnvelope.bandCount)
        XCTAssertTrue(envelope.levels.allSatisfy { $0 == WaveEnvelope.minimumLevel })
        XCTAssertTrue(envelope.isSettled)
    }

    /// The failure this normalisation exists for: real music sits well below
    /// full scale, and a fixed scale draws it as a flat line.
    func testQuietMusicStillFillsTheGlyph() {
        var envelope = WaveEnvelope()
        settle(&envelope, [0.02, 0.015, 0.01, 0.008, 0.005])
        XCTAssertGreaterThan(envelope.levels[0], 0.8,
                             "the loudest band should reach near full height however quiet the source")
        XCTAssertFalse(envelope.isSettled)
    }

    /// The same music at a different volume draws the same wave.
    ///
    /// Tested as a CHANGE — settle, then halve — because that is the only way
    /// to see scale-invariance once each band normalises against itself: a
    /// steady tone pins every bar to the top whatever its absolute level, which
    /// is true but says nothing. Both fixtures stay above `peakFloor`; below it
    /// the floor deliberately takes over, since that is the line between quiet
    /// music and no music.
    func testTheSameMusicAtAnyVolumeDrawsTheSameWave() {
        var quiet = WaveEnvelope()
        var loud = WaveEnvelope()
        settle(&quiet, [0.10, 0.08, 0.06, 0.04, 0.02])
        settle(&loud, [0.90, 0.72, 0.54, 0.36, 0.18])
        settle(&quiet, [0.05, 0.04, 0.03, 0.02, 0.01], frames: 5)
        settle(&loud, [0.45, 0.36, 0.27, 0.18, 0.09], frames: 5)
        for (index, (a, b)) in zip(quiet.levels, loud.levels).enumerated() {
            XCTAssertEqual(a, b, accuracy: 0.02, "band \(index) should not depend on volume")
        }
    }

    /// THE reason peaks are per-band, measured off real music: a shared peak
    /// gave bands of roughly 47, 12, 5, 3, 2, and the top two bars then sat on
    /// the floor forever. Every band that has any energy at all has to be able
    /// to use the full height of its bar.
    func testTrebleIsNotBuriedByBass() {
        var envelope = WaveEnvelope()
        settle(&envelope, [47, 12, 5, 3, 2])
        for (index, level) in envelope.levels.enumerated() {
            XCTAssertGreaterThan(level, 0.8,
                                 "band \(index) has energy and must reach full height")
        }
    }

    /// The other half of that contract: per-band normalisation must not invent
    /// motion in a band with nothing in it.
    func testABandWithNoEnergyStaysOnTheFloor() {
        var envelope = WaveEnvelope()
        settle(&envelope, [0.9, 0.7, 0.5, 0.3, 0])
        XCTAssertEqual(envelope.levels[4], WaveEnvelope.minimumLevel, accuracy: 0.001)
        XCTAssertGreaterThan(envelope.levels[0], 0.8)
    }

    /// Each band tracks its OWN history, so a band that goes quiet falls while
    /// its neighbours carry on — the thing a shared peak cannot express.
    func testBandsMoveIndependently() {
        var envelope = WaveEnvelope()
        settle(&envelope, [0.5, 0.5, 0.5, 0.5, 0.5])
        settle(&envelope, [0.5, 0.5, 0.5, 0.5, 0.01], frames: 40)
        XCTAssertGreaterThan(envelope.levels[0], 0.8)
        XCTAssertLessThan(envelope.levels[4], 0.4,
                          "a band that dropped away must fall on its own")
    }

    // MARK: - The failures that only show with real audio

    /// A cymbal crash must not flatten the next three minutes.
    func testALoudTransientDoesNotPermanentlySquashEverything() {
        var envelope = WaveEnvelope()
        envelope.ingest([1.0, 1.0, 1.0, 1.0, 1.0])
        settle(&envelope, [0.05, 0.04, 0.03, 0.02, 0.01], frames: 400)
        XCTAssertGreaterThan(envelope.levels[0], 0.8,
                             "the peak must decay so quiet passages re-scale back up")
    }

    /// And the mirror image: silence must not drive the reference to zero, or
    /// the first faint noise normalises to full height.
    func testSilenceDoesNotAmplifyNoiseIntoADrumHit() {
        var envelope = WaveEnvelope()
        for _ in 0..<2000 { envelope.idle() }
        envelope.ingest([WaveEnvelope.peakFloor / 8, 0, 0, 0, 0])
        XCTAssertLessThan(envelope.levels[0], 0.5,
                          "noise well under the floor must stay small")
    }

    func testRisesFasterThanItFalls() {
        var rising = WaveEnvelope()
        rising.ingest([1, 1, 1, 1, 1])
        let afterOneLoudFrame = rising.levels[0]

        var falling = WaveEnvelope()
        settle(&falling, [1, 1, 1, 1, 1])
        let before = falling.levels[0]
        falling.idle()
        let dropped = before - falling.levels[0]

        XCTAssertGreaterThan(afterOneLoudFrame - WaveEnvelope.minimumLevel, dropped,
                             "attack should move further in one frame than release does")
    }

    func testDecaysToTheFloorAndSettlesWhenAudioStops() {
        var envelope = WaveEnvelope()
        settle(&envelope, [0.9, 0.8, 0.7, 0.6, 0.5])
        XCTAssertFalse(envelope.isSettled)
        for _ in 0..<500 { envelope.idle() }
        XCTAssertTrue(envelope.isSettled, "a stopped tap must stop asking to be redrawn")
        XCTAssertTrue(envelope.levels.allSatisfy { $0 >= WaveEnvelope.minimumLevel })
    }

    // MARK: - Hostile input

    /// An FFT that divides by zero produces these, and a NaN reaching SwiftUI
    /// is a blank glyph with no error anywhere.
    func testNonFiniteMagnitudesAreIgnoredRatherThanDrawn() {
        var envelope = WaveEnvelope()
        envelope.ingest([.nan, .infinity, -.infinity, 0.5, -3])
        XCTAssertTrue(envelope.levels.allSatisfy(\.isFinite))
        XCTAssertTrue(envelope.levels.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testWrongBandCountIsSurvivable() {
        var short = WaveEnvelope()
        short.ingest([0.5])
        XCTAssertEqual(short.levels.count, WaveEnvelope.bandCount)

        var long = WaveEnvelope()
        long.ingest(Array(repeating: 0.5, count: 64))
        XCTAssertEqual(long.levels.count, WaveEnvelope.bandCount)
    }

    func testLevelsAlwaysStayInRange() {
        var envelope = WaveEnvelope()
        for step in 0..<300 {
            envelope.ingest(Array(repeating: Double(step % 7) * 0.31, count: 5))
            XCTAssertTrue(envelope.levels.allSatisfy { $0 >= WaveEnvelope.minimumLevel && $0 <= 1 })
        }
    }
}
