import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of one word on "Check these words" (2026-11-03): its
/// buttons, then "Type it" open with a word typed. For looking at rather
/// than asserting:
///
///     AIRLOCK_WORDS_PNG=$PWD/.build/words.png taskpolicy -c background swift test --filter WordCheckSnapshot
///
/// Drawn through a window rather than `ImageRenderer`, which leaves a text
/// field blank.
@MainActor
final class WordCheckSnapshot: XCTestCase {
    func testDrawTheRow() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_WORDS_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_WORDS_PNG to a .png path to draw the word row.")

        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: Date(),
                                   endedAt: Date().addingTimeInterval(49 * 60))
        let call = CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/words"), record: record, page: nil)
        let heard = ["a lock", "reloj", "look"]
        let sheet = VStack(alignment: .leading, spacing: 22) {
            CallNotesWordButtons(call: call, best: "Elock", heard: heard)
            CallNotesWordButtons(call: call, best: "Elock", heard: heard, typing: "Airlock")
        }
        .padding(24)
        .frame(width: 560, alignment: .leading)
        .background(Color(white: 0.09))
        .environment(CallNotesLibrary(previewing: [call], tab: .notes))
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: sheet)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: destination))
    }
}
