import XCTest

/// Cards C2 and C3: every animation timing in the app — the notch, its
/// widgets, the guide, Settings and onboarding — comes from
/// Notch/NotchMotion.swift: one of the five motions, or a named effect. A new
/// one-off `.easeOut(duration: 0.2)` in a widget is how the island drifts back
/// to feeling like several apps, so this reads the sources and says where.
final class MotionTimingGuardTests: XCTestCase {

    /// Where a timing may still be written out: the motion file itself, and
    /// the bloub, whose choreography is its own special effect.
    private static let allowed = [
        "Notch/NotchMotion.swift",
        "Views/Bloub.swift",
        "Views/BloubMoods.swift",
    ]

    private static let timing = try! NSRegularExpression(
        pattern: #"\.(spring|easeInOut|easeIn|easeOut|smooth|snappy|bouncy|interpolatingSpring)\(|\.linear\(duration|repeatForever"#)

    func testNoAnimationTimingsOutsideTheMotionFile() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/AirlockApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(sources.path.count + 1))
            if Self.allowed.contains(where: { relative.hasPrefix($0) }) { continue }
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                let range = NSRange(code.startIndex..., in: code)
                if Self.timing.firstMatch(in: code, range: range) != nil {
                    found.append("\(relative):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan should have found the app's sources")
        XCTAssertEqual(found, [], "use a Motion or a MotionEffect from Notch/NotchMotion.swift")
    }
}
