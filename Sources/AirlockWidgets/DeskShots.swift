import AirlockCore
import AppKit
import SwiftUI

/// Draws the widget at every size, in every look, on a desktop-like
/// backdrop, so the design can be checked without putting it on a desktop.
@MainActor
enum DeskShots {
    static func render(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let looks: [(String, DeskSurface, Bool)] = [
            ("black", .black, true), ("dark-glass", .darkGlass, true), ("light-glass", .lightGlass, false),
        ]
        for (name, surface, dark) in looks {
            write(board(DeskSample.some, surface: surface, dark: dark),
                  to: folder.appendingPathComponent("\(name).png"))
            write(board(DeskSample.allDone, surface: surface, dark: dark),
                  to: folder.appendingPathComponent("all-done-\(name).png"))
        }
        write(board(DeskSample.some, surface: .black, dark: false, faded: true),
              to: folder.appendingPathComponent("faded-light.png"))
        write(board(DeskSample.some, surface: .black, dark: true, faded: true),
              to: folder.appendingPathComponent("faded-dark.png"))
        write(board(.empty(on: .now), surface: .black, dark: true),
              to: folder.appendingPathComponent("no-todos-black.png"))

        let calls: [(String, DeskNextCall)] = [
            ("soon", NextCallSample.soon), ("on", NextCallSample.on),
            ("no-link", NextCallSample.noLink), ("clear", NextCallSample.clear),
        ]
        for (state, next) in calls {
            for (name, surface, dark) in looks {
                write(callBoard(next, surface: surface, dark: dark),
                      to: folder.appendingPathComponent("next-call-\(state)-\(name).png"))
            }
        }
        write(callBoard(NextCallSample.soon, surface: .black, dark: true, faded: true),
              to: folder.appendingPathComponent("next-call-soon-faded-dark.png"))

        let shelves: [(String, DeskShelfFiles)] = [
            ("some", ShelfSample.some), ("few", ShelfSample.few),
            ("empty", ShelfSample.empty), ("off", ShelfSample.off),
        ]
        for (state, shelf) in shelves {
            for (name, surface, dark) in looks {
                write(shelfBoard(shelf, surface: surface, dark: dark),
                      to: folder.appendingPathComponent("shelf-\(state)-\(name).png"))
            }
        }
        write(shelfBoard(ShelfSample.some, surface: .black, dark: true, faded: true),
              to: folder.appendingPathComponent("shelf-some-faded-dark.png"))

        let copies: [(String, DeskClips)] = [
            ("some", ClipsSample.some), ("secret", ClipsSample.secretFirst),
            ("picture", ClipsSample.pictureFirst), ("empty", ClipsSample.empty), ("off", ClipsSample.off),
        ]
        for (state, clips) in copies {
            for (name, surface, dark) in looks {
                write(clipsBoard(clips, surface: surface, dark: dark),
                      to: folder.appendingPathComponent("clips-\(state)-\(name).png"))
            }
        }
        write(clipsBoard(ClipsSample.some, surface: .black, dark: true, faded: true),
              to: folder.appendingPathComponent("clips-some-faded-dark.png"))

        let desks: [(String, DeskAgents)] = [
            ("some", AgentsSample.some), ("working", AgentsSample.working), ("quiet", AgentsSample.quiet),
            ("empty", AgentsSample.empty), ("off", AgentsSample.off), ("off-waiting", AgentsSample.offWaiting),
        ]
        for (state, desk) in desks {
            for (name, surface, dark) in looks {
                write(agentsBoard(desk, surface: surface, dark: dark),
                      to: folder.appendingPathComponent("agents-\(state)-\(name).png"))
            }
        }
        write(agentsBoard(AgentsSample.some, surface: .black, dark: true, faded: true),
              to: folder.appendingPathComponent("agents-some-faded-dark.png"))
    }

    static func agentsBoard(_ desk: DeskAgents, surface: DeskSurface, dark: Bool,
                            faded: Bool = false) -> some View {
        let look = DeskLook.make(surface: surface, faded: faded, fadedDark: dark)
        func card(_ size: AgentsView.Size, width: CGFloat, height: CGFloat, padding: CGFloat) -> some View {
            AgentsView(desk: desk, size: size, look: look, live: false)
                .padding(padding)
                .frame(width: width, height: height)
                .background(look.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                card(.small, width: 170, height: 170, padding: 14)
                card(.medium, width: 360, height: 170, padding: 16)
            }
            card(.large, width: 360, height: 380, padding: 18)
        }
        .padding(28)
        .background(
            LinearGradient(colors: dark ? [Color(hex: 0x2B3866), Color(hex: 0x3E4C80)]
                                        : [Color(hex: 0xCFE2FB), Color(hex: 0xEAF2FD)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    static func clipsBoard(_ clips: DeskClips, surface: DeskSurface, dark: Bool,
                           faded: Bool = false) -> some View {
        let look = DeskLook.make(surface: surface, faded: faded, fadedDark: dark)
        func card(_ size: ClipsView.Size, width: CGFloat, height: CGFloat, padding: CGFloat) -> some View {
            ClipsView(clips: clips, size: size, look: look, picture: { madeUp($0.thumb) }, live: false)
                .padding(padding)
                .frame(width: width, height: height)
                .background(look.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                card(.small, width: 170, height: 170, padding: 14)
                card(.medium, width: 360, height: 170, padding: 16)
            }
            card(.large, width: 360, height: 380, padding: 18)
        }
        .padding(28)
        .background(
            LinearGradient(colors: dark ? [Color(hex: 0x2B3866), Color(hex: 0x3E4C80)]
                                        : [Color(hex: 0xCFE2FB), Color(hex: 0xEAF2FD)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    static func shelfBoard(_ shelf: DeskShelfFiles, surface: DeskSurface, dark: Bool,
                           faded: Bool = false) -> some View {
        let look = DeskLook.make(surface: surface, faded: faded, fadedDark: dark)
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                shelfCard(shelf, .small, look, width: 170, height: 170, padding: 14)
                shelfCard(shelf, .medium, look, width: 360, height: 170, padding: 16)
            }
            shelfCard(shelf, .large, look, width: 360, height: 380, padding: 18)
        }
        .padding(28)
        .background(
            LinearGradient(colors: dark ? [Color(hex: 0x2B3866), Color(hex: 0x3E4C80)]
                                        : [Color(hex: 0xCFE2FB), Color(hex: 0xEAF2FD)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    static func shelfCard(_ shelf: DeskShelfFiles, _ size: ShelfView.Size, _ look: DeskLook,
                          width: CGFloat, height: CGFloat, padding: CGFloat) -> some View {
        ShelfView(shelf: shelf, size: size, look: look, picture: { madeUp($0.thumb) }, live: false)
            .padding(padding)
            .frame(width: width, height: height)
            .background(look.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    /// Stand-in pictures for the made-up files: no real file is read.
    static func madeUp(_ thumb: String?) -> NSImage? {
        let colors: [Color]
        switch thumb {
        case "beach": colors = [Color(hex: 0x5BC0EB), Color(hex: 0xF4D35E)]
        case "mockup": colors = [Color(hex: 0x6C5CE7), Color(hex: 0xA29BFE)]
        case "logo": colors = [Color(hex: 0x00B894), Color(hex: 0x55EFC4)]
        default: return nil
        }
        let view = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom).frame(width: 120, height: 120)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    static func callBoard(_ next: DeskNextCall, surface: DeskSurface, dark: Bool, faded: Bool = false) -> some View {
        let look = DeskLook.make(surface: surface, faded: faded, fadedDark: dark)
        return HStack(alignment: .top, spacing: 24) {
            callCard(next, .small, look, width: 170, height: 170, padding: 14)
            callCard(next, .medium, look, width: 360, height: 170, padding: 16)
        }
        .padding(28)
        .background(
            LinearGradient(colors: dark ? [Color(hex: 0x2B3866), Color(hex: 0x3E4C80)]
                                        : [Color(hex: 0xCFE2FB), Color(hex: 0xEAF2FD)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    static func callCard(_ next: DeskNextCall, _ size: NextCallView.Size, _ look: DeskLook,
                         width: CGFloat, height: CGFloat, padding: CGFloat) -> some View {
        NextCallView(next: next, now: .now, size: size, look: look, live: false)
            .padding(padding)
            .frame(width: width, height: height)
            .background(look.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    /// `dark` picks the desktop behind it. Glass cannot be drawn off screen,
    /// so here the glass grounds show only their tint.
    static func board(_ todos: DeskTodos, surface: DeskSurface, dark: Bool, faded: Bool = false) -> some View {
        let look = DeskLook.make(surface: surface, faded: faded, fadedDark: dark)
        return HStack(alignment: .top, spacing: 24) {
            card(todos, .small, look, width: 170, height: 170, padding: 14)
            card(todos, .medium, look, width: 360, height: 170, padding: 16)
            card(todos, .large, look, width: 360, height: 380, padding: 18)
        }
        .padding(28)
        .background(
            LinearGradient(colors: dark ? [Color(hex: 0x2B3866), Color(hex: 0x3E4C80)]
                                        : [Color(hex: 0xCFE2FB), Color(hex: 0xEAF2FD)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    static func card(_ todos: DeskTodos, _ size: CallTodosView.Size, _ look: DeskLook,
                     width: CGFloat, height: CGFloat, padding: CGFloat) -> some View {
        CallTodosView(todos: todos, size: size, look: look)
            .padding(padding)
            .frame(width: width, height: height)
            .background(look.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
