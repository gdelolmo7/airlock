import CryptoKit
import XCTest
@testable import AirlockCore

/// The faces call notes give people (`Blobatar`), held to the original's own
/// fixture: a name has to draw the face the original draws for it, or the
/// port has drifted and somebody's face changed.
final class BlobatarTests: XCTestCase {
    /// The first 1,000 seeds of the original's corpus, in its order: plain,
    /// e-mail, hex, spaced, accented, decomposable, astral, digits, UUIDs and
    /// padded mixed case.
    static let seeds: [String] = (0..<1000).map { i in
        switch i % 10 {
        case 0: "user-\(i)"
        case 1: "alain\(i)@example.com"
        case 2: String(repeating: String(format: "%08x", UInt32(truncatingIfNeeded: UInt64(i) * 2_654_435_761)),
                       count: 4)
        case 3: "Team Rocket \(i)"
        case 4: "café-\(i)"
        case 5: "Ünïcødé \(i)"
        case 6: "🦊\(i)🌱"
        case 7: "\(i)"
        case 8: "00000000-0000-4000-8000-" + String(format: "%012d", i)
        default: "  Mixed Case \(i)  "
        }
    }

    private func digest(_ markup: String) -> String {
        SHA256.hash(data: Data(markup.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Same face as the original

    func testEverySilhouetteDrawsTheOriginalsMarkup() {
        let midpoints: [(String, Double)] = [
            ("round", 0.11), ("organic", 0.35), ("boxy", 0.54), ("capsule", 0.65), ("nub", 0.745),
            ("cloud", 0.825), ("droplet", 0.888), ("hexagon", 0.933), ("sun", 0.965), ("triangle", 0.99),
        ]
        for (shape, value) in midpoints {
            XCTAssertEqual(Blobatar.svg(for: "alain", traits: ["shape": value]),
                           BlobatarGolden.markup["shape:\(shape)"], shape)
            XCTAssertEqual(Blobatar.figure(for: "alain", traits: ["shape": value]).shape.rawValue, shape)
        }
    }

    func testPinnedTraitsAndAnAstralNameDrawTheOriginalsMarkup() {
        XCTAssertEqual(Blobatar.svg(for: "alain"), BlobatarGolden.markup["plain"])
        XCTAssertEqual(Blobatar.svg(for: "alain", traits: ["shape": 0.96, "eye.ratio": 0, "hue": 0.5]),
                       BlobatarGolden.markup["configured"])
        XCTAssertEqual(Blobatar.svg(for: "🦊"), BlobatarGolden.markup["astral"])
    }

    func testAThousandNamesDrawTheOriginalsFaces() {
        let expected = BlobatarGolden.hashes.split(separator: "\n").map(String.init)
        XCTAssertEqual(expected.count, Self.seeds.count)
        let drifted = zip(Self.seeds, expected).filter { seed, hash in digest(Blobatar.svg(for: seed)) != hash }
        XCTAssertEqual(drifted.map(\.0), [], "these names no longer draw the original's face")
    }

    // MARK: - One person, one face

    func testANameIsTheSameFaceHoweverItIsWritten() {
        let face = Blobatar.figure(for: "Mariana")
        XCTAssertEqual(Blobatar.figure(for: "  mariana "), face)
        XCTAssertEqual(Blobatar.figure(for: "MARIANA"), face)
        // Precomposed and decomposed é are one letter to a reader.
        XCTAssertEqual(Blobatar.figure(for: "Jos\u{E9}"), Blobatar.figure(for: "Jose\u{301}"))
    }

    func testANameOneLetterAwayIsADifferentFace() {
        XCTAssertNotEqual(Blobatar.figure(for: "Mariana"), Blobatar.figure(for: "Marianb"))
        XCTAssertNotEqual(Blobatar.figure(for: "Person 1"), Blobatar.figure(for: "Person 2"))
    }

    /// No face Airlock draws is a triangle, which reads as a warning sign;
    /// every other face is the original's, and faces stay apart.
    func testAirlockNeverDrawsATriangle() {
        let triangle = Blobatar.face(for: "alain", traits: ["shape": 0.99])
        XCTAssertEqual(triangle, Blobatar.figure(for: "alain", traits: ["shape": 0.933]))
        for seed in Self.seeds {
            let face = Blobatar.face(for: seed)
            XCTAssertNotEqual(face.shape, .triangle, seed)
            if Blobatar.figure(for: seed).shape != .triangle { XCTAssertEqual(face, Blobatar.figure(for: seed), seed) }
        }
        let people = (1...6).map { Blobatar.face(for: "Person \($0)") }
        XCTAssertFalse(people.contains { $0.shape == .triangle })
        XCTAssertEqual(Set(people.map { "\($0.body)\($0.eyes)" }).count, people.count)
    }

    func testEveryFaceHasTwoEyes() {
        for seed in Self.seeds.prefix(200) {
            XCTAssertEqual(Blobatar.figure(for: seed).eyes.count, 2, seed)
        }
    }

    // MARK: - Eyes on a person's colour

    func testEyesAreDarkOnTheCallColours() {
        // Every colour call notes gives a person is light enough for dark eyes.
        for rgb: UInt32 in [0x4A9BFF, 0xF5A55A, 0x3ECF8E, 0xF472B6, 0xA78BFA, 0x4FC3D9, 0xF3D9A8, 0x919CAD] {
            let eye = Blobatar.eyeColour(on: rgb)
            XCTAssertLessThan(Blobatar.fromHex(UInt32(eye.dropFirst(), radix: 16)!).l, 0.3,
                              String(rgb, radix: 16))
            XCTAssertGreaterThanOrEqual(
                Blobatar.contrast(Blobatar.fromHex(UInt32(eye.dropFirst(), radix: 16)!), Blobatar.fromHex(rgb)),
                4.4, String(rgb, radix: 16))
        }
    }

    func testEyesAreLightOnADarkBody() {
        let eye = Blobatar.eyeColour(on: 0x1C1D21)
        XCTAssertGreaterThan(Blobatar.fromHex(UInt32(eye.dropFirst(), radix: 16)!).l, 0.8)
    }
}
