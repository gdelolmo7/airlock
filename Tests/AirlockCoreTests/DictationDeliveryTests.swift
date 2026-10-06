import XCTest
@testable import AirlockCore

/// A transcript is never discarded.
///
/// Pinning this because it was broken in shipping code: without Accessibility,
/// dictation transcribed the words and then dropped them, while the Permissions
/// pane told the user they would be on the clipboard. Nothing failed loudly —
/// the status line reporting it lives in the notch panel, and dictation types
/// into other apps, so the panel is exactly where nobody is looking at the
/// moment it matters.
final class DictationDeliveryTests: XCTestCase {

    func testSomewhereToTypeAndPermissionMeansTyping() {
        XCTAssertEqual(DictationDelivery.decide(route: .type, isAccessibilityTrusted: true), .type)
    }

    /// The case that was losing text.
    func testNoAccessibilityFallsBackToTheClipboard() {
        XCTAssertEqual(DictationDelivery.decide(route: .type, isAccessibilityTrusted: false), .copy,
                       "without Accessibility the words must survive, not vanish")
    }

    /// The case that already worked: nothing in front can take text.
    func testNowhereToTypeFallsBackToTheClipboard() {
        XCTAssertEqual(DictationDelivery.decide(route: .copy, isAccessibilityTrusted: true), .copy)
    }

    func testNeitherStillKeepsTheWords() {
        XCTAssertEqual(DictationDelivery.decide(route: .copy, isAccessibilityTrusted: false), .copy)
    }

    /// The invariant itself, over every combination: there is no input that
    /// produces "throw it away".
    func testNoCombinationDiscardsTheTranscript() {
        for route in [DictationRoute.type, .copy] {
            for trusted in [true, false] {
                let d = DictationDelivery.decide(route: route, isAccessibilityTrusted: trusted)
                XCTAssertTrue(d == .type || d == .copy, "\(route)/\(trusted) must deliver somewhere")
            }
        }
    }
}
