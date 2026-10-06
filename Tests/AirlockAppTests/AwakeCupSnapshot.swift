import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the keep-awake cup in the closed island, for looking at
/// rather than asserting:
///
///     AIRLOCK_AWAKE_PNG=$PWD/.build/awake-cup.png taskpolicy -c background swift test --filter AwakeCupSnapshot
///
/// The island's trailing side three times over: the wave the cup yields to, the
/// cup, and the shelf count it outranks — so the one new glyph is judged beside
/// the two rungs it sits between, each at the volume it is drawn at. At 2×,
/// because the thing under review is a 10pt glyph. (The rung above was the
/// session count until 2026-09-30, when the closed island stopped counting
/// sessions; see `CompactIsland.trailing`.)
///
/// **One ground, because the compact island has one.** `NotchSurface` offers
/// black, dark glass and light glass, but glass is handed to our view only
/// while expanded (`isGlassGround`); a collapsed island keeps the kit's black
/// and the dark palette on every surface, which `PanelGroundSchemeTests` pins.
/// The picture checks that rule rather than assuming it, so it fails instead of
/// quietly drawing an incomplete set if the rule ever changes. What does vary
/// is the menu bar the island hangs over, so the one ground is drawn over a
/// light and a dark bar: over the dark one the black wing all but disappears
/// and the glyph stands alone, which is how it is mostly seen.
///
/// **What is real and what is a copy.** `NotchCompactTrailingView` itself
/// cannot be drawn here. It reads ten environment models, several of which
/// start watchers or touch the disk when built, and the cup's rung needs
/// `SystemControlsModel.isAwake`, which only a real `IOPMAssertion` sets — a
/// test holding one would keep this Mac awake. So the cup is `KeepAwakeCup`
/// and the wave is `MediaWaveView`, the very views the slot draws, the wave in
/// the slot's grey and at its 0.8 scale. A moving glyph has to be caught at
/// some frame, and this one is its tallest: every bar at the top of its travel
/// at once, which the live path draws when the music is loud and the canned
/// loop only approaches, since its bars peak in turn. The shelf count is drawn
/// the way the slot draws it, copied from its switch; and the wing is the kit's
/// compact geometry copied from `NotchView`: the 14-inch's measured 32pt housing
/// height, our 4pt padding, the kit's 8pt trailing and 4pt / 8pt top and bottom
/// insets, and `NotchShape`'s compact corners — a 6pt flare at the top, 14pt
/// round at the bottom.
@MainActor
final class AwakeCupSnapshot: XCTestCase {
    /// `NotchMetricsTests`' 14-inch: auxiliary areas 32pt tall.
    private static let housingHeight: CGFloat = 32
    /// How much of the housing to show left of the shoulder — enough to see
    /// where the island starts, not the whole 185pt cutout.
    private static let housingSlice: CGFloat = 22
    /// `NotchView`'s compact radii.
    private static let flare: CGFloat = 6
    private static let bottomRadius: CGFloat = 14

    func testDrawTheCup() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_AWAKE_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_AWAKE_PNG to a .png path to draw the keep-awake cup.")
        // The premise of drawing one ground. If a surface ever keeps its glass
        // while collapsed, this picture is missing a row — say so, loudly.
        for surface in NotchSurface.allCases {
            XCTAssertFalse(surface.isGlassGround(showing: .compact), "\(surface) is glass while compact; draw it")
            XCTAssertEqual(surface.groundScheme(showing: .compact), .dark, "\(surface) compact")
        }
        Theme.setTextScale(1)

        let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        print("Keep-awake cup drawn to \(url.path) (\(Int(image.size.width))×\(Int(image.size.height)) pt at 2×)")
    }

    // MARK: - The sheet

    private struct Rung {
        let caption: String
        let slot: CompactSlot
    }

    private static let rungs = [
        Rung(caption: "wave · rung above", slot: .wave),
        Rung(caption: "keep-awake · new", slot: .keepingAwake),
        Rung(caption: "shelf · rung below", slot: .shelfCount(3)),
    ]

    private static let menuBars: [(title: String, color: Color)] = [
        ("over a light menu bar", Color(white: 0.86)),
        ("over a dark menu bar", Color(white: 0.17)),
    ]

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Self.caption("compact ground: black, dark palette — the same on "
                         + NotchSurface.allCases.map(\.label).joined(separator: ", ").lowercased())
            ForEach(Self.menuBars, id: \.title) { bar in
                VStack(alignment: .leading, spacing: 8) {
                    Self.caption(bar.title)
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(Self.rungs, id: \.caption) { rung in
                            VStack(alignment: .leading, spacing: 8) {
                                Self.wing(rung.slot)
                                    .padding(.trailing, 14)
                                    .background(alignment: .topLeading) { bar.color }
                                Self.caption(rung.caption)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
    }

    private static func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
    }

    /// The right-hand end of the closed island: a slice of the housing, then
    /// the trailing shoulder exactly as the kit lays it out.
    private static func wing(_ slot: CompactSlot) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.housingSlice)
            Self.slotDrawing(slot)
                .padding(.horizontal, 4)
                .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: 8) }
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
        }
        .frame(height: Self.housingHeight)
        .fixedSize()
        // The kit pads the whole island by the top radius, and the flare lives
        // in that padding.
        .padding(.trailing, Self.flare)
        .background(Color.black)
        .mask {
            TrailingWingShape(flare: Self.flare, bottomRadius: Self.bottomRadius)
                .padding(.trailing, 0.5)
        }
    }

    /// The slot, drawn the way `NotchCompactTrailingView` draws it. The cup and
    /// the wave are the shipped views; the shelf count is a copy of that view's
    /// branch.
    @ViewBuilder
    private static func slotDrawing(_ slot: CompactSlot) -> some View {
        switch slot {
        case .keepingAwake:
            KeepAwakeCup()
        case .wave:
            // Five levels, one per bar, is what selects the live path; all at 1
            // is every bar at full height. See the type's note on which frame.
            MediaWaveView(color: Theme.textSecondary, levels: [1, 1, 1, 1, 1])
                .scaleEffect(0.8)
        case let .shelfCount(count):
            HStack(spacing: 2) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(count)")
                    .font(Theme.fixed(11, .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.textTertiary)
        default:
            EmptyView()
        }
    }
}

/// The right half of `NotchShape` at its compact radii: straight across the
/// top to the flare's tip, the flare curving in, straight down, and the bottom
/// corner rounding back under. Open on the left, where the housing continues.
private struct TrailingWingShape: Shape {
    let flare: CGFloat
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare),
                          control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - bottomRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - flare - bottomRadius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
