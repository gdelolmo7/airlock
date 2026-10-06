import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the typing notch and the cloud in the tab strip
/// (2026-10-01), for looking at rather than asserting:
///
///     AIRLOCK_TYPING_PNG=$PWD/.build/typing.png taskpolicy -c background swift test --filter TypingBarSnapshot
///
/// The top bar needs half the app's models, so its two gutters are restated
/// here from the same pieces (`AirlockMark`, `BloubView`, the gear), with the
/// real `CommandField` under them.
@MainActor
final class TypingBarSnapshot: XCTestCase {
    func testDrawTheStates() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_TYPING_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_TYPING_PNG to a .png path to draw the typing bar.")

        let sheet = VStack(spacing: 14) {
            panel { typingTopBar } body: {
                CommandField(text: .constant(""), isBlocked: false, guideKeys: true, onSubmit: {}, drawsAsLabel: true)
            }
            panel { typingTopBar } body: {
                CommandField(text: .constant("How do I add an A record in Hostinger"),
                             isBlocked: false, guideKeys: true, onSubmit: {}, drawsAsLabel: true)
            }
            panel { typingTopBar } body: {
                CommandField(text: .constant(""), isBlocked: true, guideKeys: true, onSubmit: {}, drawsAsLabel: true)
            }
            panel { tabsTopBar } body: { Color.clear.frame(height: 8) }
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

    private func panel<Top: View, Body: View>(@ViewBuilder _ top: () -> Top,
                                              @ViewBuilder body: () -> Body) -> some View {
        VStack(spacing: 0) {
            top().frame(height: 32)
            body()
        }
        .padding(.bottom, 12)
        .frame(width: 640)
        .background(Color.black, in: .rect(cornerRadius: 18))
    }

    private var typingTopBar: some View {
        HStack(spacing: 3) {
            AirlockMark(motion: .still)
            glyph("chevron.up")
            Spacer()
            rightGutter
        }
        .padding(.leading, 8)
    }

    private var tabsTopBar: some View {
        HStack(spacing: 3) {
            BloubView(expression: .attentive, tint: Theme.running)
                .frame(width: 18, height: 15)
                .frame(width: 36, height: 26)
                .background(Capsule().fill(Color.white.opacity(0.16)))
            ForEach(["square.grid.2x2.fill", "tray.full.fill", "doc.on.clipboard.fill"], id: \.self) {
                Image(systemName: $0)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 36, height: 26)
            }
            glyph("chevron.up")
            Spacer()
            rightGutter
        }
        .padding(.leading, 8)
    }

    private var rightGutter: some View {
        HStack(spacing: 8) {
            glyph("gear")
            Text("32%").font(Theme.gutter(11, .semibold)).foregroundStyle(Theme.textPrimary)
            Image(systemName: "battery.25").font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.done).symbolRenderingMode(.hierarchical)
        }
        .padding(.trailing, 10)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 22, height: 22)
    }
}
