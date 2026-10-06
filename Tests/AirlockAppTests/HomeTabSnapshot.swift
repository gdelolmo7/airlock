import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the slimmed Home tab (2026-10-01), for looking at rather
/// than asserting:
///
///     AIRLOCK_HOME_PNG=$PWD/.build/home.png taskpolicy -c background swift test --filter HomeTabSnapshot
///
/// Draws the real card views (`NowPlayingCard`, `DormantTrackCard`,
/// `ControlTile`) with values instead of models, on a black ground at the
/// default panel width, in three states: playing, paused with Wi-Fi's strip
/// open, and the player quit. The artwork is a flat stand-in — `ArtworkView`
/// loads a remote image, which a test cannot wait on.
@MainActor
final class HomeTabSnapshot: XCTestCase {
    private static let sectionWidth: CGFloat = 640 - 2 * 10
    private static let sideColumn: CGFloat = (640 - 2 * 10 - 25) / 2

    func testDrawHome() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_HOME_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_HOME_PNG to a .png path to draw the Home tab.")

        let sheet = VStack(alignment: .leading, spacing: 24) {
            home(playing: true, onControls: [.wifi, .awake])
            home(playing: false, onControls: [.dark], openStrip: true)
            VStack(alignment: .leading, spacing: 8) {
                DormantTrackCard(title: "Midnight City", artist: "M83",
                                 caption: "Last played in Spotify · 2 hr. ago",
                                 button: "Open Spotify", artwork: artwork, onReopen: {})
                controls(on: [])
            }
        }
        .padding(16)
        .frame(width: Self.sectionWidth + 32)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: destination))
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: MediaCardMetrics.artworkSize * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [.purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: MediaCardMetrics.artworkSize, height: MediaCardMetrics.artworkSize)
    }

    private func home(playing: Bool, onControls: Set<SystemControlsModel.Control>,
                      openStrip: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NowPlayingCard(title: "Midnight City", artist: "M83",
                           playerName: "Spotify", isPlaying: playing,
                           artwork: artwork, artworkLabel: "Album artwork, Spotify",
                           timeline: MediaTimelineRow(position: 37, duration: 285, isSeekable: true,
                                                      onBegin: { _ in }, onMove: { _ in }, onEnd: { _ in }),
                           onOpen: {}, onPrevious: {}, onTogglePlay: {}, onNext: {})
            controls(on: onControls, openWiFi: openStrip)
        }
    }

    /// The controls beside the Sound card, as Home lays them out since
    /// 2026-10-01: leading and trailing columns, 25pt apart, each card alone in
    /// its column and so filling the row (`fillsPairedRow`), with Sound's
    /// levels at its foot as `SoundSectionView` puts them.
    private func controls(on: Set<SystemControlsModel.Control>, openWiFi: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 25) {
            ControlRail(shown: SystemControlsModel.Control.allCases,
                        isOn: { on.contains($0) },
                        openStrip: openWiFi ? .wifi : nil)
                .modifier(HomeCardBackground())
                .frame(width: Self.sideColumn)
            VStack(alignment: .leading, spacing: 10) {
                SoundCardHeader(device: "MacBook Pro Speakers", canSwitch: true, isChoosing: false,
                                stacked: true)
                Spacer(minLength: 0)
                LevelRows(output: LevelSource(id: "output", name: "Volume", value: 0.62, isMuted: false,
                                              isIdle: false, icon: nil, symbol: "speaker.wave.2.fill",
                                              mute: (name: "Mute", run: {}), failure: nil, set: { _ in }),
                          apps: [], hidden: 0)
            }
            .modifier(HomeCardBackground())
            .frame(width: Self.sideColumn)
        }
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.fillsPairedRow, true)
    }
}
