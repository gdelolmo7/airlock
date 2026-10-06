import AppKit
import SwiftUI
import AirlockCore

/// Every screen Airlock can show, drawn from fake values, one at a time.
///
///     open output/package/Airlock.app --args --state-gallery          # browse
///     open output/package/Airlock.app --args --state-gallery G26      # open at a state
///     open output/package/Airlock.app --args --state-gallery ~/states # write PNGs, quit
///
/// **Why it exists.** To see "no internet" or "Screen Recording is off" you
/// otherwise have to break your own Mac, so those states were rarely looked at
/// and they rotted. The IDs are the rows of `docs/feel-and-finish-inventory.md`,
/// and the export names each picture after its row.
///
/// **It leaves no trace, and that is structural rather than careful.** It is
/// handled at the very top of `applicationDidFinishLaunching`, before the
/// identity migration, the bridge, the island, any widget model or any
/// permission check exists — the same place as `--snapshot`, for the same
/// reason. What it draws is built from values: guide states come from a real
/// `GuideSession` driven by made-up replies (so the words are the shipping
/// words), never from the guide client; the licence is
/// `LicenseModel(previewing:)`, which reads and writes nothing. And nothing in a
/// picture can be pressed (`allowsHitTesting(false)`): an agent card's "Jump"
/// is a real AppleScript call, and the gallery is for looking.
///
/// **What it is not**, the same caveat as `PanelSnapshot`: these are the VIEWS,
/// not the composited island — no glass, no notch above them, no height budget.
/// "Is the wording right, is anything unfinished" is answerable here; "does it
/// fit on a 13-inch screen" is not.
@MainActor
enum StateGallery {
    enum Request: Equatable {
        case browse(startAt: String?)
        case export(URL)
    }

    static func requested(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Request? {
        guard let flag = arguments.firstIndex(of: "--state-gallery") else { return nil }
        let next = arguments.index(after: flag)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return .browse(startAt: nil) }
        let value = arguments[next]
        if value.range(of: #"^[A-Z][0-9]+[a-z]?$"#, options: .regularExpression) != nil {
            return .browse(startAt: value)
        }
        return .export(URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true))
    }

    /// Every state, in inventory order. One line per area, like the widget
    /// registry: an area is a file of its own under `StateGallery/`.
    static var all: [GalleryState] {
        guideStates + GalleryIsland.states + GalleryAgents.states + GalleryWidgets.states
            + GalleryClipboard.states + GalleryShelf.states + GalleryDictation.states
            + GalleryAssistant.states + GalleryLicence.states + GalleryOnboarding.states
            + GallerySettings.states + GalleryMotion.states
    }

    /// The guide's area, first in the inventory, only in a build that has it.
    private static var guideStates: [GalleryState] {
        #if AIRLOCK_GUIDE
        GalleryGuide.states
        #else
        []
        #endif
    }

    static func run(_ request: Request) {
        switch request {
        case .export(let directory):
            let written = export(to: directory)
            FileHandle.standardError.write(Data("state gallery: wrote \(written) of \(all.count) to \(directory.path)\n".utf8))
            NSApp.terminate(nil)
        case .browse(let startAt):
            GalleryWindow.shared.show(startAt: startAt)
        }
    }

    // MARK: - Export

    /// One PNG per state, named by its inventory row, plus `index.md` saying
    /// which is which. Returns how many were written.
    @discardableResult
    static func export(to directory: URL) -> Int {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        var index = "# Airlock states\n\n| # | Area | State |\n|---|---|---|\n"
        for state in all {
            index += "| [\(state.id)](\(state.id).png) | \(state.area) | \(state.name) |\n"
            guard let png = png(of: state) else { continue }
            if (try? png.write(to: directory.appendingPathComponent("\(state.id).png"))) != nil { written += 1 }
        }
        try? index.write(to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        return written
    }

    /// Drawn by a hosting view in a window that is never shown, not by
    /// `ImageRenderer`: that one draws every AppKit-backed control — a
    /// spinner, a switch, a text field — as a 🚫 placeholder, which would make
    /// half of Settings look broken in the export when it is not. Reading our
    /// own view's pixels needs no permission.
    static func png(of state: GalleryState) -> Data? {
        let host = NSHostingView(rootView: GalleryFrame(state: state, showsLabel: true)
            .environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = RetinaWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Measured again once it is in the window: a view that settles in
        // `onAppear` (the calendar folding this morning's rows behind
        // "1 earlier") or reads a preference back into @State (the shelf
        // matching its rail) changes height after the first measure, and the
        // old size would leave a white band above and below the picture.
        let settled = host.fittingSize
        if settled != host.frame.size {
            window.setContentSize(settled)
            host.frame = NSRect(origin: .zero, size: settled)
            host.layoutSubtreeIfNeeded()
        }
        guard host.bounds.width > 0, host.bounds.height > 0,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// A window that is never on a screen has a backing scale of 1, so what it
/// draws is blurry at 2×. This one says 2 whatever screen it is not on.
private final class RetinaWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

/// One row of the inventory, drawn.
struct GalleryState: Identifiable {
    /// What the state sits on. The island's states are drawn on the panel's
    /// black; the guide's floating card on a stand-in desktop, since it is a
    /// window of its own; Settings and the welcome on a window ground.
    enum Ground {
        /// The expanded notch panel: black, rounded, `width` wide.
        case panel
        /// The compact island: the view is the trailing half, drawn beside a
        /// stand-in notch.
        case compact
        /// A window of its own over the desktop (the guide's bubble).
        case floating
        /// A standard window (Settings, welcome, purchase).
        case window
    }

    /// The inventory row, e.g. "G26".
    let id: String
    let area: String
    let name: String
    var ground: Ground = .panel
    var width: CGFloat = GalleryState.panelWidth
    let draw: @MainActor () -> AnyView
    /// `.compact` only: what sits left of the camera. Nil draws the resting
    /// bloub, which is right for every row about the trailing half.
    var leading: (@MainActor () -> AnyView)?

    /// The default panel width (`NotchAppearanceModel`'s default), not the
    /// person's own: a gallery picture should look the same on every Mac.
    static let panelWidth: CGFloat = 640

    init(_ id: String, _ area: String, _ name: String, ground: Ground = .panel,
         width: CGFloat = GalleryState.panelWidth, @ViewBuilder draw: @escaping @MainActor () -> some View) {
        self.id = id
        self.area = area
        self.name = name
        self.ground = ground
        self.width = width
        self.draw = { AnyView(draw()) }
    }

    /// A row that cannot be drawn from values yet, saying why. It still opens
    /// in the gallery, so a gap is a visible card rather than a missing ID.
    static func notYet(_ id: String, _ area: String, _ name: String, why: String) -> GalleryState {
        GalleryState(id, area, name) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hammer")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not drawable yet")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(why)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A state on its ground, with its row and name in the corner.
struct GalleryFrame: View {
    var state: GalleryState
    var showsLabel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel {
                Text("\(state.id) · \(state.name)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            grounded
                // Every wait drawn at the same moment, and a still one: two
                // seconds in, the dots are up and no words have joined them.
                // A row that shows another stage says so itself (card B2).
                .environment(\.waitElapsedOverride, 2)
                .allowsHitTesting(false)
        }
        .padding(18)
        .background(Color(red: 0.16, green: 0.17, blue: 0.19))
    }

    @ViewBuilder private var grounded: some View {
        switch state.ground {
        case .panel:
            state.draw()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: state.width, alignment: .leading)
                .background(Color.black, in: .rect(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
        case .compact:
            HStack(spacing: 0) {
                Group {
                    if let leading = state.leading {
                        leading()
                    } else {
                        BloubView(expression: .neutral, motion: .still, tint: Theme.textPrimary)
                            .frame(width: 22, height: 19)
                    }
                }
                .padding(.leading, 12)
                Spacer(minLength: 0)
                Color.clear.frame(width: 190) // where the camera housing sits
                Spacer(minLength: 0)
                state.draw()
                    .padding(.trailing, 12)
            }
            .frame(height: 32)
            .frame(minWidth: 320)
            .fixedSize()
            .background(Color.black, in: .rect(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        case .floating:
            state.draw()
                .padding(28)
                .background(LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.45),
                                                    Color(red: 0.20, green: 0.22, blue: 0.30)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
        case .window:
            state.draw()
                // What the Settings window sets at its root.
                .environment(\.problemCardLook, .settings)
                .frame(width: state.width)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(.rect(cornerRadius: 10))
        }
    }
}

// MARK: - The window

@MainActor
final class GalleryWindow: NSObject, NSWindowDelegate {
    static let shared = GalleryWindow()
    private var window: NSWindow?

    func show(startAt: String?) {
        let model = GalleryBrowser(states: StateGallery.all, startAt: startAt)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Airlock · state gallery"
        window.contentView = NSHostingView(rootView: GalleryBrowserView(browser: model)
            .environment(\.colorScheme, .dark))
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The gallery is the whole app in this run: closing it quits.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

@MainActor
@Observable
final class GalleryBrowser {
    let states: [GalleryState]
    var selection: String?
    var exportNote: String?

    init(states: [GalleryState], startAt: String?) {
        self.states = states
        selection = states.first(where: { $0.id == startAt })?.id ?? states.first?.id
    }

    var areas: [(name: String, states: [GalleryState])] {
        var order: [String] = []
        var grouped: [String: [GalleryState]] = [:]
        for state in states {
            if grouped[state.area] == nil { order.append(state.area) }
            grouped[state.area, default: []].append(state)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var current: GalleryState? { states.first { $0.id == selection } }
    private var position: Int? { states.firstIndex { $0.id == selection } }
    var label: String {
        guard let position else { return "" }
        return "\(position + 1) of \(states.count)"
    }

    func step(_ delta: Int) {
        guard let position, !states.isEmpty else { return }
        selection = states[(position + delta + states.count) % states.count].id
    }

    func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let written = StateGallery.export(to: directory)
        exportNote = "Wrote \(written) pictures to \(directory.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

struct GalleryBrowserView: View {
    @Bindable var browser: GalleryBrowser

    var body: some View {
        NavigationSplitView {
            List(selection: $browser.selection) {
                ForEach(browser.areas, id: \.name) { area in
                    Section(area.name) {
                        ForEach(area.states) { state in
                            HStack(spacing: 8) {
                                Text(state.id)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                Text(state.name).lineLimit(1)
                            }
                            .tag(state.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    if let state = browser.current {
                        GalleryFrame(state: state, showsLabel: false)
                            .environment(\.galleryPlays, true)
                            .id(state.id)
                            .padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if let state = browser.current {
                        Text("\(state.id) · \(state.name)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                Divider()
                HStack {
                    Button("Previous") { browser.step(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("Next") { browser.step(1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Text(browser.label).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if let note = browser.exportNote {
                        Text(note).foregroundStyle(.secondary)
                    }
                    Button("Export all…") { browser.exportAll() }
                }
                .padding(10)
            }
        }
    }
}
