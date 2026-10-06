import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the dictation strip (2026-10-01), for looking at rather
/// than asserting:
///
///     AIRLOCK_LISTEN_PNG=$PWD/.build/listen.png taskpolicy -c background swift test --filter ListeningStripSnapshot
///
/// `ListeningStrip` is the view the panel draws under the top bar while a key
/// is held, fed values instead of `DictationModel`. Each state sits on a black
/// panel-width ground, since the strip is now the whole panel.
@MainActor
final class ListeningStripSnapshot: XCTestCase {
    func testDrawTheStates() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_LISTEN_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_LISTEN_PNG to a .png path to draw the listening strip.")

        let states: [ListeningStrip] = [
            strip(listening: true, text: "", level: 0.02),
            strip(listening: true, text: "Remind me to send the invoice to Marta before Friday and",
                  level: 0.18, destination: "Notes"),
            strip(listening: true, asking: true, route: .guide,
                  text: "How do I add an A record in Hostinger", level: 0.12),
            strip(listening: false, sorting: true,
                  text: "How do I add an A record in Hostinger", level: 0),
            strip(listening: false, text: "Remind me to send the invoice to Marta before Friday.", level: 0),
        ]
        let sheet = VStack(spacing: 14) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                state
                    .frame(width: 640, alignment: .leading)
                    .padding(.vertical, 10)
                    .background(Color.black, in: .rect(cornerRadius: 18))
            }
        }
        .padding(16)
        .background(Color(white: 0.25))
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: destination))
    }

    private func strip(listening: Bool, sorting: Bool = false, asking: Bool = false,
                       route: GuideRouting.Route? = nil, text: String, level: Float,
                       destination: String? = nil) -> ListeningStrip {
        ListeningStrip(isListening: listening, isSorting: sorting, isAsking: asking,
                       askRoute: route, route: .type, destinationName: destination,
                       liveText: text,
                       inputLevels: [0.6, 0.8, 1].map { $0 * MicLevel.scale(level) })
    }
}
