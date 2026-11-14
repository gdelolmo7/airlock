import AppKit
import CoreGraphics

/// Keeps macOS's own permission questions in front of the notch.
///
/// The island sits at `.statusBar`, which is above the level macOS draws its
/// permission questions at, and those questions appear at the top middle of
/// the screen: right under an open panel. During setup the microphone
/// question came up half hidden behind the step that asked for it.
///
/// Called just before Airlock asks macOS something. For a few seconds it
/// looks for a window that wasn't on screen before, belongs to a background
/// process (macOS's questions come from agents, never from an app in the
/// Dock) and overlaps the panel. While that window is up the panel steps
/// down to just below it; once it is gone the panel goes back. It never
/// raises anything, and with nothing to watch it costs nothing.
@MainActor
final class SystemQuestionWatch {
    static let shared = SystemQuestionWatch()

    /// The panel's frame in screen points, bottom-left origin (AppKit's).
    var panelFrame: () -> NSRect? = { nil }
    /// Step aside to this level, or back to normal with nil.
    var onLevel: (NSWindow.Level?) -> Void = { _ in }

    private var task: Task<Void, Never>?
    private var before: Set<Int> = []
    /// Which watch is current, so a replaced one never undoes the next.
    private var generation = 0
    private var stepped: Int?

    /// How long a question has to appear in, after the ask.
    static let appearsWithin: Duration = .seconds(4)
    /// Nobody answers for longer than this; past it the panel goes back anyway.
    static let longest: Duration = .seconds(120)

    func begin() {
        // A second ask while the first is watched: keep the windows already
        // seen as "before", so the question on screen still counts.
        if task == nil { before = Set(Self.windows().map(\.number)) }
        task?.cancel()
        generation += 1
        let mine = generation
        task = Task { [weak self] in await self?.watch(mine) }
    }

    private func watch(_ mine: Int) async {
        let clock = ContinuousClock()
        let start = clock.now
        var goneSince: ContinuousClock.Instant?
        defer {
            if generation == mine {
                if stepped != nil { onLevel(nil) }
                stepped = nil
                task = nil
            }
        }
        while !Task.isCancelled, generation == mine {
            let elapsed = clock.now - start
            if elapsed > Self.longest { return }
            let question = panelFrame().flatMap { Self.question(over: $0, ignoring: before) }
            if let question {
                goneSince = nil
                let level = max(question.layer - 1, NSWindow.Level.normal.rawValue)
                if stepped != level {
                    stepped = level
                    onLevel(NSWindow.Level(rawValue: level))
                }
            } else if stepped != nil {
                // A short gap between two questions in a row is not the end.
                if let since = goneSince {
                    if clock.now - since > .milliseconds(500) { return }
                } else {
                    goneSince = clock.now
                }
            } else if elapsed > Self.appearsWithin {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private struct Seen {
        let number: Int
        let pid: pid_t
        let layer: Int
        /// Top-left origin, the way the window server reports it.
        let bounds: CGRect
    }

    private static func windows() -> [Seen] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return Seen(number: number, pid: pid_t(pid), layer: layer, bounds: bounds)
        }
    }

    /// A new window from a background process over the panel, below it.
    private static func question(over panel: NSRect, ignoring before: Set<Int>) -> Seen? {
        let ours = ProcessInfo.processInfo.processIdentifier
        let panelTop = flipped(panel)
        return windows().first { seen in
            seen.pid != ours
                && !before.contains(seen.number)
                && seen.layer < NSWindow.Level.statusBar.rawValue
                && seen.bounds.width > 40 && seen.bounds.height > 40
                && seen.bounds.intersects(panelTop)
                && isBackground(seen.pid)
        }
    }

    private static func isBackground(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        return app.activationPolicy != .regular
    }

    /// AppKit's bottom-left frame as the window server's top-left one.
    private static func flipped(_ rect: NSRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
