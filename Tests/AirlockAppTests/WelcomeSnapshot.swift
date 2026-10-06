import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the everyday first run (card 3.07), for looking at
/// rather than asserting:
///
///     AIRLOCK_WELCOME_PNG=$PWD/.build/welcome.png taskpolicy -c background swift test --filter WelcomeSnapshot
///
/// The welcome (9a) and the developer question (9d), after a practice that
/// did not finish and after one that did, each in light and dark. Drawn through a hosting view
/// rather than `ImageRenderer`, which cannot draw the window's AppKit buttons.
@MainActor
final class WelcomeSnapshot: XCTestCase {
    func testDrawWelcome() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_WELCOME_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_WELCOME_PNG to a .png path to draw the welcome.")

        var asked = WelcomePlan(hookStatuses: [])
        asked.startPractice()
        _ = asked.practiceEnded(reached: false)
        var reached = WelcomePlan(hookStatuses: [])
        reached.startPractice()
        _ = reached.practiceEnded(reached: true)
        let plans = [WelcomePlan(hookStatuses: []), asked, reached]

        var pictures: [NSBitmapImageRep] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for plan in plans {
                let model = WelcomeModel(previewing: plan)
                let view = NSHostingView(rootView: WelcomeView().environment(model)
                    .environment(\.welcomeHeroStill, true))
                view.appearance = NSAppearance(named: appearance)
                view.frame.size = view.fittingSize
                view.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                pictures.append(rep)
            }
        }

        // Two columns: light, dark; rows: welcome, question.
        let gap: CGFloat = 24
        let width = WelcomeView.width
        let heights = pictures.map { CGFloat($0.pixelsHigh) / CGFloat($0.pixelsWide) * width }
        let rowHeights = [max(heights[0], heights[2]), max(heights[1], heights[3])]
        let size = NSSize(width: width * 2 + gap * 3, height: rowHeights.reduce(0, +) + gap * 3)
        let sheet = NSImage(size: size, flipped: true) { _ in
            NSColor.gray.setFill()
            NSRect(origin: .zero, size: size).fill()
            for (index, rep) in pictures.enumerated() {
                let column = CGFloat(index / 2), row = index % 2
                let y = gap + (row == 0 ? 0 : rowHeights[0] + gap)
                rep.draw(in: NSRect(x: gap + column * (width + gap), y: y, width: width, height: heights[index]),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return true
        }
        let tiff = try XCTUnwrap(sheet.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: destination))
    }
}
