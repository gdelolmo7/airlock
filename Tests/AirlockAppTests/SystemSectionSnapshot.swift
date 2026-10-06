import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the System section, for looking at rather than asserting:
///
///     AIRLOCK_SYSTEM_PNG=$PWD/.build/system-section.png taskpolicy -c background swift test --filter SystemSectionSnapshot
///
/// Five states of the This Mac card, drawn as rings since 2026-10-01. Across
/// the top, in a side column of the default 640pt panel, which is where the
/// card lives: a Mac under heavy load with the list and its leftover line; one
/// whose GPU figure is not reported, which draws two rings rather than a third
/// reading 0%; and the seconds after the panel opens, before a second sweep is
/// in. Underneath: heavy load in a side column of the narrowest panel, where
/// the rings are at their tightest; and the first state's list given room for
/// two lines only, which is the list giving way. Drawn from sample data, so the
/// picture is the same on every run and on every Mac.
///
/// Drawn the way `PanelSnapshot` draws the cards, and with the same caveat: dark
/// explicitly, because `ImageRenderer` resolves light whatever the system says;
/// at 2×, because the thing under review is 10pt type; on flat near-black,
/// which is the honest stand-in for the panel's glass. It answers "is the
/// hierarchy right, does anything wrap badly", not "does this fit the panel".
@MainActor
final class SystemSectionSnapshot: XCTestCase {
    /// The stack is inset 10pt a side, and paired columns are 25pt apart
    /// (`NotchExpandedView`). The card lives in the Dashboard's right-hand
    /// column since 2026-10-01, so that is its default width here.
    private static let sectionWidth: CGFloat = (640 - 2 * 10 - 25) / 2
    private static let sideColumnWidth: CGFloat =
        (NotchAppearanceModel.requestedWidthRange.lowerBound - 2 * 10 - 25) / 2

    /// The list's own heights at text size 1: an 8pt gap over a 13pt caption,
    /// then a 16pt row and 3pt between rows for each line (`CPUByAppView`).
    private static func listHeight(lines: Int) -> CGFloat { 8 + 13 + CGFloat(lines) * (3 + 16) }

    func testDrawTheStates() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_SYSTEM_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_SYSTEM_PNG to a .png path to draw the System section.")
        Theme.setTextScale(1)

        let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        print("System section drawn to \(url.path) (\(Int(image.size.width))×\(Int(image.size.height)) pt at 2×)")
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 28) {
                    ForEach(row, id: \.title) { state in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(state.title.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                            SystemStatsContent(stats: state.stats, apps: state.apps)
                                .environment(\.yieldingContentRoom, state.room)
                                .frame(width: state.width ?? Self.sectionWidth, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
    }

    private struct State {
        let title: String
        let stats: SystemStats
        let apps: CPUByApp
        /// A full-width section of the default panel when nil.
        var width: CGFloat?
        /// What the panel would offer the list; unbounded is its natural height.
        var room: CGFloat = .infinity
    }

    private static var rows: [[State]] {
        let xcodePath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")?.path
            ?? "/Applications/Xcode.app"
        let xcode = ProcessGroup(kind: .app, name: "Xcode", bundlePath: xcodePath)
        let node = ProcessGroup(kind: .program, name: "node")
        let heavyShares: [ProcessGroup: Double] = [xcode: 41.2, .simulator: 22.8, .spotlight: 9.6, node: 0.6]

        var ranker = CPUBreakdownRanker()
        let heavy = ranker.rank(shares: heavyShares, headline: 87.4)
        var idleRanker = CPUBreakdownRanker()
        let idle = idleRanker.rank(shares: [node: 0.3], headline: 0.8)
        // The owner's own mix: a build, the simulators, and Docker's Linux VM.
        var sideRanker = CPUBreakdownRanker()
        let side = sideRanker.rank(shares: [xcode: 38.4, .simulator: 21.7, .virtualMachines: 7.9, node: 0.6],
                                   headline: 81.2)

        let heavyStats = SystemStats(cpuPercent: 87.4, memoryPercent: 81.3, memoryUsedGB: 39.0,
                                     memoryTotalGB: 48, gpuPercent: 64)

        return [
            [
                State(title: "Heavy load: rows and the leftover",
                      stats: heavyStats,
                      apps: .breakdown(heavy)),
                State(title: "GPU not reported: as before",
                      stats: SystemStats(cpuPercent: 0.8, memoryPercent: 42.0, memoryUsedGB: 20.2,
                                         memoryTotalGB: 48, gpuPercent: nil),
                      apps: .breakdown(idle)),
                State(title: "Just opened: measuring",
                      stats: SystemStats(cpuPercent: 23.6, memoryPercent: 64.8, memoryUsedGB: 31.1,
                                         memoryTotalGB: 48, gpuPercent: 12),
                      apps: .measuring),
            ],
            [
                State(title: "Side column, \(Int(NotchAppearanceModel.requestedWidthRange.lowerBound))pt panel",
                      stats: SystemStats(cpuPercent: 81.2, memoryPercent: 88.6, memoryUsedGB: 42.5,
                                         memoryTotalGB: 48, gpuPercent: 38),
                      apps: .breakdown(side),
                      width: sideColumnWidth),
                State(title: "Heavy load, room for two lines",
                      stats: heavyStats,
                      apps: .breakdown(heavy),
                      room: listHeight(lines: 2)),
            ],
        ]
    }
}
