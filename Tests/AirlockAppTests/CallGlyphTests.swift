import AirlockCore
import AppKit
import XCTest
@testable import AirlockApp

/// The call pill's logos are SVG text in the source; a typo in one is a blank
/// square on somebody's call, and nothing else would notice.
@MainActor
final class CallGlyphTests: XCTestCase {
    func testEveryLogoDrawsAsATemplate() throws {
        for name in Set(CallGlyph.logoNames.values).union(["googlemeet"]) {
            let image = try XCTUnwrap(CallGlyph.image(name), "\(name) did not load")
            XCTAssertTrue(image.isTemplate, name)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), name)
        }
    }

    func testEveryLogoIsUsed() {
        XCTAssertEqual(Set(CallGlyph.paths.keys), Set(CallGlyph.logoNames.values).union(["googlemeet"]))
    }

    func testUnknownAppsGetThePhone() {
        XCTAssertEqual(CallGlyph.kind(for: "com.example.SomeApp"), .symbol("phone.fill"))
        XCTAssertEqual(CallGlyph.kind(for: "com.apple.FaceTime"), .symbol("phone.fill"))
        XCTAssertEqual(CallGlyph.kind(for: "us.zoom.xos"), .symbol("video.fill"))
        XCTAssertEqual(CallGlyph.kind(for: "net.whatsapp.WhatsApp"), .logo("whatsapp"))
        XCTAssertEqual(CallGlyph.kind(for: "com.google.Chrome"), .logo("chrome"))
    }

    func testAMeetTabShowsMeetInsteadOfTheBrowser() {
        let chrome = OngoingCall(bundleID: "com.google.Chrome", appName: "Google Chrome", startedAt: .now)
        var meet = chrome
        meet.site = .googleMeet
        XCTAssertEqual(CallGlyph.kind(for: chrome), .logo("chrome"))
        XCTAssertEqual(CallGlyph.kind(for: meet), .logo("googlemeet"))
    }

    func testMeetIsReadFromTheTabTitle() {
        XCTAssertEqual(CallGlyph.site(inWindowTitles: ["Inbox", "Meet – abc-defg-hij"]), .googleMeet)
        XCTAssertEqual(CallGlyph.site(inWindowTitles: ["Meet - Weekly sync - Google Chrome"]), .googleMeet)
        XCTAssertEqual(CallGlyph.site(inWindowTitles: ["Meet"]), .googleMeet)
        XCTAssertNil(CallGlyph.site(inWindowTitles: ["Meeting notes – Google Docs", "YouTube"]))
        XCTAssertNil(CallGlyph.site(inWindowTitles: []))
    }

    func testOnlyBrowsersAreRead() {
        XCTAssertTrue(CallGlyph.isBrowser("com.google.Chrome"))
        XCTAssertTrue(CallGlyph.isBrowser("com.apple.Safari"))
        XCTAssertFalse(CallGlyph.isBrowser("net.whatsapp.WhatsApp"))
        XCTAssertFalse(CallGlyph.isBrowser("com.example.SomeApp"))
    }
}
