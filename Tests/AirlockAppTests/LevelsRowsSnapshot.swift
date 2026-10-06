import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the levels card in its rows form, for looking at rather
/// than asserting:
///
///     AIRLOCK_LEVELS_PNG=$PWD/.build/levels-rows.png taskpolicy -c background swift test --filter LevelsRowsSnapshot
///
/// Every card the form draws, from sample data, at the width the home tab gives
/// it in the default 640pt panel — a side column, beside the calendar. Across
/// the top: the output alone, which is the shipped default; one and two apps on
/// an output with no software volume, which is HDMI and DisplayPort; the output
/// and one app. Under them: five apps against a cap of four; muted, idle and
/// failed rows; an output with no settable mute. Then the busiest card in the
/// narrowest and widest panels, and a card alone in the panel, which is what
/// it gets when the calendar is off — an empty column claims nothing, so the
/// survivor takes the whole width. Last, both failure sentences in the
/// narrowest panel, which is where `LevelFailureCaptionTests` holds them to
/// their line budget; the one under a muted row, because a muted row that can
/// be heard is the case the sentence most needs to explain. And, in a second
/// file with `-large` before the extension, all of it again at the largest
/// text size.
///
/// The sentences are the model's own constants, never copies, so the picture
/// cannot go on showing a sentence the app no longer says.
///
/// Drawn the way `SystemSectionSnapshot` draws, with its caveats — dark
/// explicitly, 2×, flat near-black standing in for the panel's glass. Since the
/// 2026-10-01 redraw the levels are drawn bars rather than AppKit sliders, so
/// the picture is the real thing and not a placeholder in the slider's frame.
@MainActor
final class LevelsRowsSnapshot: XCTestCase {

    /// A side column of a panel this wide: the stack is inset 10pt a side and
    /// paired columns are 25pt apart (`NotchExpandedView`). Not private:
    /// `LevelFailureCaptionTests` measures in the same column.
    nonisolated static func sideColumn(_ panel: CGFloat) -> CGFloat { (panel - 2 * 10 - 25) / 2 }

    func testDrawTheStates() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_LEVELS_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_LEVELS_PNG to a .png path to draw the levels card.")
        // The scale is process-wide; leave it where every other test expects it.
        defer { Theme.setTextScale(1) }

        Theme.setTextScale(1)
        let url = URL(fileURLWithPath: destination)
        try draw(Self.rows, to: url)
        printHeights(Self.rows.flatMap { $0 }, scale: 1)

        // Every state again at the largest text size, where fixed widths meet
        // scaled fonts. That is where the readout used to wrap.
        Theme.setTextScale(Theme.maxTextScale)
        try draw(Self.rows, to: URL(fileURLWithPath: url.deletingPathExtension().path + "-large.png"))
        printHeights(Self.rows.flatMap { $0 }, scale: Theme.maxTextScale)
    }

    private func draw(_ rows: [[State]], to url: URL) throws {
        let renderer = ImageRenderer(content: Self.sheet(rows).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        print("Levels card drawn to \(url.path) (\(Int(image.size.width))×\(Int(image.size.height)) pt at 2×)")
    }

    /// Card heights through an `NSHostingView`, at text size `scale`.
    private func printHeights(_ states: [State], scale: CGFloat) {
        for state in states {
            let host = NSHostingView(rootView: Self.card(state).environment(\.colorScheme, .dark))
            let size = host.fittingSize
            let title = state.title.padding(toLength: 34, withPad: " ", startingAt: 0)
            print(String(format: "levels card @%.1fx  %@ %5.1f × %5.1f pt", scale, title, size.width, size.height))
        }
    }

    // MARK: - Drawing

    private static func sheet(_ rows: [[State]]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 28) {
                    ForEach(row, id: \.title) { state in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(state.title.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                            card(state)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
    }

    /// `SoundSectionView` from values: the header naming the device, the output
    /// list when it is open, and the levels.
    private static func card(_ state: State) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SoundCardHeader(device: state.device, canSwitch: state.devices.count > 1,
                            isChoosing: state.choosing)
            if state.choosing {
                OutputDeviceList(choices: state.devices.map {
                    OutputChoice(id: $0, name: $0, isCurrent: $0 == state.device)
                })
            }
            if state.output != nil || !state.apps.isEmpty {
                LevelRows(output: state.output, apps: state.apps, hidden: state.hidden)
            }
        }
        .modifier(HomeCardBackground())
        .frame(width: state.width)
    }

    // MARK: - Sample data

    private struct State {
        let title: String
        /// What the header names.
        var device: String?
        /// Every output; more than one makes the header a switcher.
        var devices: [String] = []
        /// The output list is open.
        var choosing = false
        var hidden = 0
        var output: LevelSource?
        var apps: [LevelSource] = []
        var width: CGFloat = LevelsRowsSnapshot.sideColumn(640)
    }

    private static let appPaths: [String: String] = [
        "Music": "/System/Applications/Music.app",
        "Podcasts": "/System/Applications/Podcasts.app",
        "Safari": "/Applications/Safari.app",
        "TV": "/System/Applications/TV.app",
    ]

    private static func app(_ name: String, _ value: Double, muted: Bool = false, idle: Bool = false,
                            failure: String? = nil) -> LevelSource {
        LevelSource(id: name, name: name, value: value, isMuted: muted, isIdle: idle,
                    icon: appPaths[name].map { NSWorkspace.shared.icon(forFile: $0) },
                    symbol: "app.dashed",
                    mute: idle ? nil : (name: muted ? "Unmute" : "Mute", run: {}),
                    failure: failure, set: { _ in })
    }

    private static func output(_ value: Double, muted: Bool = false, canMute: Bool = true) -> LevelSource {
        LevelSource(id: "output", name: "Volume", value: value, isMuted: muted, isIdle: false, icon: nil,
                    symbol: OutputMute.isSilent(volume: Float(value), isMuted: muted)
                        ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    mute: canMute ? (name: muted ? "Unmute" : "Mute", run: {}) : nil,
                    failure: nil, set: { _ in })
    }

    private static var rows: [[State]] {
        let speakers = "MacBook Pro Speakers"
        let display = "LG HDR 4K"
        let busy = State(title: "Five apps, a cap of four", device: speakers,
                         devices: [speakers, display, "AirPods Pro"], hidden: 1,
                         output: output(0.62),
                         apps: [app("Music", 1.0), app("Podcasts", 0.35, muted: true),
                                app("Safari", 0.7), app("TV", 0.5, idle: true)])
        return [
            [
                State(title: "Output alone (shipped default)", device: speakers, output: output(0.62)),
                State(title: "HDMI, one app", device: display, apps: [app("Music", 0.8)]),
                State(title: "HDMI, two apps", device: display,
                      apps: [app("Music", 0.8), app("Safari", 0.45)]),
                State(title: "Output and one app", device: speakers,
                      output: output(0.62), apps: [app("Music", 1.0)]),
            ],
            [
                busy,
                State(title: "Muted, failed, idle", device: speakers,
                      output: output(0.4, muted: true),
                      apps: [app("Music", 0.8, failure: AppVolumeModel.levelNotApplied),
                             app("Safari", 0.6, idle: true)]),
                State(title: "No settable mute", device: "USB Audio Interface",
                      output: output(0.5, canMute: false), apps: [app("Music", 0.8)]),
            ],
            [
                State(title: "Busiest, 460pt panel", device: speakers, devices: busy.devices, hidden: 1, output: busy.output,
                      apps: busy.apps, width: sideColumn(460)),
                State(title: "Busiest, 760pt panel", device: speakers, devices: busy.devices, hidden: 1, output: busy.output,
                      apps: busy.apps, width: sideColumn(760)),
            ],
            [
                State(title: "Choosing an output", device: speakers,
                      devices: [speakers, display, "AirPods Pro"], choosing: true,
                      output: output(0.62)),
                State(title: "Output and one app, calendar off", device: speakers,
                      output: output(0.62), apps: [app("Music", 1.0)], width: 640 - 2 * 10),
            ],
            [
                State(title: "Muted but heard, 460pt panel", device: speakers,
                      output: output(0.62),
                      apps: [app("Music", 0.4, muted: true, failure: AppVolumeModel.levelNotApplied)],
                      width: sideColumn(460)),
                // Two apps and no output row, to keep the card about the two
                // captions.
                State(title: "Multi-Output, 460pt panel", device: "Multi-Output Device",
                      apps: [app("Music", 0.6, failure: AppVolumeTap.multiOutputRefusal),
                             app("Safari", 0.45, failure: AppVolumeTap.multiOutputRefusal)],
                      width: sideColumn(460)),
            ],
        ]
    }
}
