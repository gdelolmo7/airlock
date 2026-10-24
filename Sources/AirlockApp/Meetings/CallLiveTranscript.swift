import AppKit
import AirlockCore
import SwiftUI

/// The call notes are being taken of, handed over by the notes model as its
/// record changes. The side window and the notes window read it from here
/// while the call happens.
///
/// At most a few times a second, so a burst of lines is one redraw. The last
/// call stays once it is over, so a window left open still shows the call it
/// was showing until the next one starts.
@MainActor
@Observable
final class CallNotesLive {
    private(set) var folder: URL?
    /// The call as shown: the notes model's record, with the lines a side
    /// holds back while its language is decided where they were said.
    private(set) var record: MeetingRecord?
    /// What became of the notes once the call was over; nil until then.
    private(set) var outcome: CallLive.Outcome?
    /// What each side is saying right now, word by word, before it is a
    /// line. Shown at once, never throttled: it is the point of watching.
    private(set) var hearing: [MeetingSpeaker: CallLive.Hearing] = [:]

    /// The longest a line waits to be handed on.
    static let interval: Duration = .milliseconds(400)

    @ObservationIgnored private var pending: MeetingRecord?
    @ObservationIgnored private var handing: Task<Void, Never>?
    /// The notes model's record as last handed on, without the held lines:
    /// what a change to the call is made to, so they are never kept.
    @ObservationIgnored private var handed: MeetingRecord?
    /// The lines each side has finished but holds back while its language
    /// is decided (`MeetingTrack`). Shown in `record`, never saved.
    @ObservationIgnored private var held: [MeetingSpeaker: [MeetingSegment]] = [:]

    init() {}

    /// For the state gallery: this call, as it stands, in `folder`.
    init(previewing record: MeetingRecord?, folder: URL? = nil, outcome: CallLive.Outcome? = nil,
         hearing: [CallLive.Hearing] = []) {
        self.record = record
        handed = record
        self.folder = folder ?? record.map { _ in URL(fileURLWithPath: "/var/empty/live") }
        self.outcome = outcome
        self.hearing = Dictionary(hearing.map { ($0.speaker, $0) }, uniquingKeysWith: { $1 })
    }

    /// The notes model's record changed. A new call, its end, and a call
    /// that came back show at once; a line waits for the next hand-over.
    /// Nil keeps the last call.
    func follow(_ record: MeetingRecord?, in folder: URL?) {
        guard let record, let folder else { return }
        let newCall = folder != self.folder
        let turned = (self.record?.endedAt == nil) != (record.endedAt == nil)
            || self.record?.droppedAt != record.droppedAt
        if newCall || turned {
            // What became of the last notes is not this call's, nor this
            // call's once it carries on.
            if newCall || record.endedAt == nil { outcome = nil }
            if newCall || record.endedAt != nil {
                hearing = [:]
                held = [:]
            }
            self.folder = folder
            hand(record)
            return
        }
        pending = record
        guard handing == nil else { return }
        handing = Task { [weak self] in
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled, let self else { return }
            handing = nil
            if let pending { hand(pending) }
        }
    }

    /// `speaker` is heard saying `text` so far; "" once it is a line, or
    /// nothing is being said. The line waiting for the next hand-over goes
    /// with it, so the words never vanish before their line shows.
    func hear(_ text: String, from speaker: MeetingSpeaker) {
        guard !text.isEmpty else {
            guard hearing[speaker] != nil else { return }
            if let pending { hand(pending) }
            hearing[speaker] = nil
            return
        }
        let since = hearing[speaker]?.since ?? Date()
        hearing[speaker] = CallLive.Hearing(speaker: speaker, text: text, since: since)
    }

    /// `speaker` has finished `lines` but holds them back while its
    /// language is decided: shown where they were said, at once, and with
    /// them the line waiting for the next hand-over. None once they are
    /// lines, which come in the same hand-over, so nothing shows twice.
    func hold(_ lines: [MeetingSegment], from speaker: MeetingSpeaker) {
        guard lines != held[speaker, default: []] else { return }
        held[speaker] = lines.isEmpty ? nil : lines
        if let record = pending ?? handed { hand(record) }
    }

    private func hand(_ record: MeetingRecord) {
        handing?.cancel()
        handing = nil
        pending = nil
        handed = record
        let shown = CallLive.withHeld([MeetingSpeaker.me, .them].flatMap { held[$0] ?? [] }, in: record)
        if shown != self.record { self.record = shown }
    }

    /// The notes of the call in `folder` were saved, and named it `title`
    /// when they did.
    func settle(_ folder: URL, as outcome: CallLive.Outcome, title: String? = nil) {
        guard folder == self.folder else { return }
        self.outcome = outcome
        retitle(folder, as: title)
    }

    /// The call in `folder` named by its notes (`MeetingRecord.topic`), as
    /// the notes window will find it. Nil leaves the name it has.
    func retitle(_ folder: URL, as title: String?) {
        guard folder == self.folder, let title, var record = pending ?? handed, record.topic != title
        else { return }
        record.topic = title
        hand(record)
    }

    /// The call in `folder` named as `names` say, from the side window: at
    /// once, and once the call is over too, when the notes model no longer
    /// hands its record on.
    func rename(_ names: [MeetingVoiceName], in folder: URL) {
        guard folder == self.folder, var record = pending ?? handed else { return }
        record.replaceNames(with: names)
        hand(record)
    }

    /// The notes stopped before they were saved.
    func failed(_ reason: String) {
        guard record != nil, outcome == nil else { return }
        outcome = .failed(reason)
    }
}

/// What the side window asks of the notes model.
struct LiveTranscriptActions {
    /// Whether the notes are paused now. Read as the window draws, so it
    /// follows the pause.
    let isPaused: @MainActor () -> Bool
    /// The notch's Pause, Resume and Stop, for the window's foot.
    let pause: @MainActor () -> Void
    let resume: @MainActor () -> Void
    let stop: @MainActor () -> Void
    /// The call in the notes window, on this tab.
    let open: @MainActor (CallNotesLibrary.Tab) -> Void
    let close: @MainActor () -> Void
    /// Whether a voice can be named now. While the voices are still being
    /// told apart, the other side heard as one can be named only until any
    /// of its lines has a number: named, it is one person.
    var canName: @MainActor (Int) -> Bool = { _ in true }
    /// The call's voices named as these say.
    var name: @MainActor ([MeetingVoiceName]) -> Void = { _ in }
}

/// A narrow window beside the call that shows the transcript as it is
/// written, newest line at the foot. It floats over the call's own window,
/// on every Space and beside a full-screen call, and never takes the
/// keyboard from the call when it opens.
@MainActor
final class LiveTranscriptWindowController {
    private let live: CallNotesLive
    private let actions: LiveTranscriptActions
    private var panel: NSPanel?

    static let width: CGFloat = 360
    /// The gap to the screen's edge and the menu bar.
    static let margin: CGFloat = 16

    init(live: CallNotesLive, actions: LiveTranscriptActions) {
        self.live = live
        self.actions = actions
    }

    var isShown: Bool { panel?.isVisible == true }

    func show() {
        if panel == nil {
            let panel = Self.makePanel(LiveTranscriptView(live: live, actions: actions))
            Self.place(panel, on: NotchScreen.notched)
            // Where the person last put it, from then on.
            panel.setFrameAutosaveName("airlock.liveTranscript")
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// The window, sized and laid out, not yet on screen.
    static func makePanel(_ view: LiveTranscriptView) -> NSPanel {
        let panel = LiveTranscriptPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = String(localized: "Live transcript")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Its own close button is in the header, with the call's name.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Nor when Airlock is hidden from its Dock icon: it belongs to the
        // call, not to the call notes window that put Airlock in the Dock.
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(CallsLook.sidebar)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 300, height: 320)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return panel
    }

    /// Down the right of the screen the island is on, under the menu bar.
    static func place(_ panel: NSWindow, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let height = min(680, visible.height - margin * 2)
        panel.setFrame(NSRect(x: visible.maxX - width - margin, y: visible.maxY - height - margin,
                              width: width, height: height).integral,
                       display: false)
    }
}

/// Takes the keyboard when clicked, for Escape and selecting a line, without
/// bringing Airlock forward over the call.
private final class LiveTranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The colours of the side window that the notes window has no name for.
enum LiveLook {
    /// Times and the quiet words: "12:41", "Listening…", "Ended".
    static let faint = rgb(0x7D8695)
    /// The dot of a call that is over.
    static let over = CallsLook.openBox
    /// What the notes hold, under "Your notes are ready".
    static let cardText = rgb(0xAAB2BF)
    static let card = rgb(0x15161B)
    static let quietButton = rgb(0x1F2023)
    static let pill = rgb(0x24262C)
    /// "Open notes", on blue.
    static let openText = rgb(0xA9D0FA)
    /// "Live", beside a call still going.
    static let liveText = rgb(0xC4B2FC)
    /// Words still being said, before they are a line.
    static let hearing = rgb(0x9AA3B2)
    /// "Open in a window", on purple.
    static let windowText = rgb(0xD9CCFD)
    /// The same on the island's light glass.
    static let windowTextOnLight = rgb(0x6D28D9)
    /// The side window's space between one person's lines and the next's,
    /// and between lines of one person in a row, close as paragraphs.
    static let rowGap: CGFloat = 16
    static let runGap: CGFloat = 6
    /// Where the words under a name start: past the face (22) and its gap.
    static let underName: CGFloat = 32

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - The window's page

/// The call's name and clock across the top, the transcript, and at its foot
/// "Listening…" while the call goes on, or what became of the notes once it
/// is over.
struct LiveTranscriptView: View {
    let live: CallNotesLive
    let actions: LiveTranscriptActions
    /// For the state gallery, which cannot scroll: drawn as if the person
    /// had scrolled up and this many lines had come since.
    var scrolledAwayFor: Int?
    /// The voice being named, in the box over the window's foot.
    @State private var naming: Int?

    init(live: CallNotesLive, actions: LiveTranscriptActions, scrolledAwayFor: Int? = nil, naming: Int? = nil) {
        self.live = live
        self.actions = actions
        self.scrolledAwayFor = scrolledAwayFor
        _naming = State(initialValue: naming)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let record = live.record {
                let stage = CallLive.stage(of: record, paused: actions.isPaused(), outcome: live.outcome)
                let named = naming.flatMap { record.voices.contains($0) && actions.canName($0) ? $0 : nil }
                LiveTranscriptHeader(record: record, stage: stage, escapes: named == nil, actions: actions)
                LiveTranscriptLines(record: record, stage: stage, ground: CallsLook.sidebar,
                                    hearing: stage.isLive ? CallLive.speaking(live.hearing, paused: stage == .paused,
                                                                                in: record)
                                                          : [],
                                    scrolledAwayFor: scrolledAwayFor,
                                    canName: actions.canName, name: { naming = $0 })
                    .frame(maxHeight: .infinity)
                if let named {
                    LiveTranscriptNaming(record: record, voice: named, close: { naming = nil },
                                         save: { names in
                                             actions.name(names)
                                             naming = nil
                                         })
                        .id(named)
                        .padding(.horizontal, 12)
                        .padding(.bottom, stage.isLive ? 2 : 10)
                }
                if stage.isLive {
                    LiveTranscriptFoot(paused: stage == .paused, actions: actions)
                } else {
                    LiveTranscriptOutcome(stage: stage, hasWords: !record.segments.isEmpty, actions: actions)
                        .padding([.horizontal, .bottom], 12)
                }
            } else {
                Text("No call is being written down.")
                    .font(Theme.chrome(12.5))
                    .foregroundStyle(LiveLook.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CallsLook.sidebar)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Another call is nobody's to name from here.
        .onChange(of: live.folder) { naming = nil }
    }
}

/// "Who is Person 2?" over the window's foot, while the call goes on and
/// once it is over: the notes window's box, the width of this one.
private struct LiveTranscriptNaming: View {
    let record: MeetingRecord
    let voice: Int
    let close: () -> Void
    let save: ([MeetingVoiceName]) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        CallVoiceRename(record: record, voice: voice, width: nil, cancel: close, save: save)
            .background(shape.fill(LiveLook.card))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// Close, the call's dot, its name and how long so far, and the way to the
/// notes window. Dragging it moves the window.
private struct LiveTranscriptHeader: View {
    let record: MeetingRecord
    let stage: CallLive.Stage
    /// Whether Escape closes the window: not while a name is being typed,
    /// where it puts the name away.
    var escapes = true
    let actions: LiveTranscriptActions

    var body: some View {
        let title = MeetingFiles.title(of: record)
        HStack(spacing: 9) {
            LiveTranscriptClose(escapes: escapes, action: actions.close)
            Circle()
                .fill(stage.isLive ? Theme.assistant : LiveLook.over)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.chrome(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .help(title)
                .accessibilityAddTraits(.isHeader)
            Group {
                if stage.isLive {
                    // How long, not a clock: the lines below say the time of
                    // day, and "12:45" beside them would read as one.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(CallLive.soFar(record, now: context.date))
                    }
                } else {
                    Text("Ended")
                }
            }
            .font(Theme.chrome(12))
            .monospacedDigit()
            .foregroundStyle(LiveLook.faint)
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 4)
            LiveTranscriptIconButton(symbol: "arrow.up.right.square", help: "Open in Calls") {
                actions.open(.transcript)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 48)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .background(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }
}

private struct LiveTranscriptClose: View {
    var escapes = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.11 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(escapes ? .cancelAction : nil)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help("Close")
        .accessibilityLabel("Close")
    }
}

private struct LiveTranscriptIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The transcript, newest at the foot, followed while the person is at the
/// foot, and under it the words being said, in grey until they are a line.
/// Once the call is over, "Call ended · 13 min" across it.
private struct LiveTranscriptLines: View {
    let record: MeetingRecord
    let stage: CallLive.Stage
    let ground: Color
    /// Being said now (`CallLive.speaking`).
    let hearing: [CallLive.Hearing]
    let scrolledAwayFor: Int?
    /// Whether a voice can be named now, and naming it.
    let canName: @MainActor (Int) -> Bool
    let name: (Int) -> Void

    var body: some View {
        let entries = MeetingTimeline.shown(of: record)
        let people = CallPeople.people(of: record)
        let carried = hearing.first { CallLive.continues($0, after: entries, startedAt: record.startedAt) }
        let others = hearing.filter { $0 != carried }
        let headed = CallLive.headed(entries, hearing: others, in: record)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LiveLook.rowGap) {
                if entries.isEmpty, hearing.isEmpty, stage.isLive {
                    Text(stage == .paused ? "Nothing is written down while paused."
                                          : "Words appear here as they are said.")
                        .font(Theme.chrome(12.5))
                        .foregroundStyle(LiveLook.faint)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    LiveTranscriptRow(entry: entry, record: record, people: people,
                                      headed: headed.entries[index],
                                      carryingOn: index == entries.count - 1 ? carried?.text : nil,
                                      canName: canName, name: name)
                }
                ForEach(Array(others.enumerated()), id: \.element.speaker) { index, heard in
                    LiveTranscriptHearingRow(hearing: heard, record: record, people: people,
                                             headed: headed.hearing[index])
                }
                if let ended = CallLive.endedLine(record) {
                    LiveTranscriptDivider(symbol: nil, text: ended)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        // Still following once the call is over, for "Call ended" to come
        // into view under the last line.
        .followsNewest(said: CallLive.spokenCount(entries), enabled: true, ground: ground,
                       scrolledAwayFor: scrolledAwayFor)
    }
}

/// One turn: the person's face, their name in their colour and when, then
/// what they said; only what they said when the line above was theirs too.
/// A typed note on paper yellow; a pause or a change of language as a word
/// between hairlines.
private struct LiveTranscriptRow: View {
    let entry: MeetingTimeline.Entry
    let record: MeetingRecord
    let people: [CallPeople.Person]
    /// With the face and name (`CallLive.headed`).
    var headed = true
    /// The words the same person is saying now, at the end of their turn.
    var carryingOn: String?
    var canName: @MainActor (Int) -> Bool = { _ in false }
    var name: (Int) -> Void = { _ in }

    var body: some View {
        switch entry {
        case .speech(let turn, let marked) where !headed:
            VStack(alignment: .leading, spacing: 3) {
                if marked { CallTranscriptMarked() }
                (Text(turn.text) + Text(carryingOn.map { " " + $0 } ?? "").foregroundStyle(LiveLook.hearing))
                    .font(Theme.chrome(13.5))
                    .foregroundStyle(CallsLook.spokenText)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, LiveLook.underName)
            .padding(.top, LiveLook.runGap - LiveLook.rowGap)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(MeetingRecord.shownLabel(record.label(for: turn))): \(turn.text)")
            .accessibilityValue(marked ? "Marked" : "")
        case .speech(let turn, let marked):
            let name = record.label(for: turn)
            let seat = CallPeople.seat(of: name, in: people)
            HStack(alignment: .top, spacing: 10) {
                CallPersonAvatar(name: name, seat: seat, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let voice = record.voice(of: turn), canName(voice) {
                            LiveTranscriptName(name: name, seat: seat) { self.name(voice) }
                        } else {
                            Text(MeetingRecord.shownLabel(name))
                                .font(Theme.chrome(12, .semibold))
                                .foregroundStyle(CallsLook.colour(for: seat))
                                .lineLimit(1)
                        }
                        Text(time(turn.start))
                            .font(Theme.chrome(11))
                            .monospacedDigit()
                            .foregroundStyle(LiveLook.faint)
                        if marked { CallTranscriptMarked() }
                    }
                    (Text(turn.text) + Text(carryingOn.map { " " + $0 } ?? "").foregroundStyle(LiveLook.hearing))
                        .font(Theme.chrome(13.5))
                        .foregroundStyle(CallsLook.spokenText)
                        .lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(marked ? "Marked" : "")
        case .jot(let jot):
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Your note")
                        .font(Theme.chrome(11.5, .semibold))
                    Text(time(jot.at))
                        .font(Theme.chrome(11))
                        .monospacedDigit()
                        .foregroundStyle(LiveLook.faint)
                }
                .foregroundStyle(CallsLook.yours)
                Text(jot.text)
                    .font(Theme.chrome(12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(CallsLook.yours.opacity(0.07)))
            .overlay(shape.strokeBorder(CallsLook.yours.opacity(0.16), lineWidth: 1))
            .padding(.leading, 32)
            .accessibilityElement(children: .combine)
        case .pause(let pause):
            LiveTranscriptDivider(symbol: "pause.fill", text: MeetingTimeline.pauseLabel(pause, clock: time))
        case .language(let listening):
            LiveTranscriptDivider(symbol: "globe", text: MeetingTimeline.languageLabel(listening, clock: time))
        }
    }

    /// When a moment of the call was, as the clock said it: "20:58".
    private func time(_ seconds: TimeInterval) -> String {
        CallsCard.time(seconds, into: record.startedAt)
    }
}

/// A voice's name above its line, that a click says who it is.
private struct LiveTranscriptName: View {
    let name: String
    let seat: CallPeople.Seat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let colour = CallsLook.colour(for: seat)
        Button(action: action) {
            Text(MeetingRecord.shownLabel(name))
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(colour)
                .underline(hovered, color: colour.opacity(0.55))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .clickable()
        .help("Say who this is")
        .accessibilityHint("Say who this is")
    }
}

/// Someone saying something that is not a line yet: their face and name,
/// and the words in grey as they come.
private struct LiveTranscriptHearingRow: View {
    let hearing: CallLive.Hearing
    let record: MeetingRecord
    let people: [CallPeople.Person]
    /// With the face and name: not when the line above is theirs.
    var headed = true

    var body: some View {
        let name = record.label(for: hearing.speaker)
        let seat = CallPeople.seat(of: name, in: people)
        if headed {
            row(name: name, seat: seat)
        } else {
            Text(hearing.text)
                .font(Theme.chrome(13.5))
                .foregroundStyle(LiveLook.hearing)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, LiveLook.underName)
                .padding(.top, LiveLook.runGap - LiveLook.rowGap)
                .accessibilityLabel("\(name): \(hearing.text)")
        }
    }

    private func row(name: String, seat: CallPeople.Seat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CallPersonAvatar(name: name, seat: seat, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(MeetingRecord.shownLabel(name))
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(CallsLook.colour(for: seat))
                    .lineLimit(1)
                Text(hearing.text)
                    .font(Theme.chrome(13.5))
                    .foregroundStyle(LiveLook.hearing)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A word between two hairlines: a pause, a change of language, the end.
private struct LiveTranscriptDivider: View {
    let symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(Theme.chrome(11.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(LiveLook.faint)
            .fixedSize()
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Once the call is over: the notes being written, ready, or why there are
/// none, with the way to them.
private struct LiveTranscriptOutcome: View {
    let stage: CallLive.Stage
    /// Something was written down before the notes stopped: the way to it.
    let hasWords: Bool
    let actions: LiveTranscriptActions

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                icon
                Text(title)
                    .font(Theme.chrome(13.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(Theme.chrome(12.5))
                    .foregroundStyle(LiveLook.cardText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LiveLook.card))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch stage {
        case .ready:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.done)
                .accessibilityHidden(true)
        case .writing:
            NotesBreathingDot(size: 8)
                .frame(width: 14)
                .accessibilityHidden(true)
        case .later:
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.needs)
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    private var title: String {
        switch stage {
        case .ready: String(localized: "Your notes are ready")
        case .writing: String(localized: "Writing your notes…")
        case .tooLittleSaid: CallNotesPanel.tooLittleSaid
        case .later: String(localized: "Call saved")
        case .tooShort: String(localized: "Too short to keep")
        case .failed: String(localized: "The notes stopped")
        case .listening, .paused: ""
        }
    }

    private var detail: String? {
        switch stage {
        case .ready(let todos): CallLive.readyDetail(todos: todos)
        case .writing: String(localized: "They'll be ready in a moment.")
        case .tooLittleSaid: String(localized: "The transcript is kept in Calls.")
        case .later: String(localized: "Its notes will be written online later.")
        case .tooShort: String(localized: "A call this short isn't saved, unless it comes back.")
        case .failed(let reason): reason
        case .listening, .paused: nil
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch stage {
        case .ready, .later:
            HStack(spacing: 8) {
                LiveCardButton("Open notes", prominent: true) { actions.open(.notes) }
                LiveCardButton("Close") { actions.close() }
            }
        case .tooLittleSaid:
            HStack(spacing: 8) {
                LiveCardButton("Open in Calls", prominent: true) { actions.open(.transcript) }
                LiveCardButton("Close") { actions.close() }
            }
        case .failed where hasWords:
            HStack(spacing: 8) {
                LiveCardButton("Open in Calls", prominent: true) { actions.open(.transcript) }
                LiveCardButton("Close") { actions.close() }
            }
        case .tooShort, .failed:
            LiveCardButton("Close") { actions.close() }
        case .writing, .listening, .paused:
            EmptyView()
        }
    }
}

/// "Listening…" under the transcript, and the notch's Pause (or Resume) and
/// Stop beside it, so the notes can be stopped from the window itself. The
/// first person to watch a call here looked for Stop and found only Close,
/// which closes the window and leaves the notes going.
private struct LiveTranscriptFoot: View {
    let paused: Bool
    let actions: LiveTranscriptActions

    var body: some View {
        HStack(spacing: 6) {
            CallLiveListening(paused: paused)
            Spacer(minLength: 8)
            if paused {
                LiveFootButton("Resume", symbol: "play.fill", action: { actions.resume() })
            } else {
                LiveFootButton("Pause", symbol: "pause.fill", action: { actions.pause() })
                    .help("Nothing said until you resume is written down")
            }
            LiveFootButton("Stop", symbol: "stop.fill", action: { actions.stop() })
                .help("Stop taking notes and write them")
        }
        .padding(.leading, 48)
        .padding(.trailing, 12)
        .padding(.bottom, 6)
        .frame(height: 44)
    }
}

/// Pause, Resume and Stop at the window's foot: small and quiet, so the
/// transcript stays what the window is for.
private struct LiveFootButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    init(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.chrome(12, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CallsLook.quietText)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(shape.fill(hovered ? Color(white: 0.16) : LiveLook.quietButton))
            .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .accessibilityLabel(title)
    }
}

/// "Open notes" across the card in blue; "Close" beside it, quiet.
private struct LiveCardButton: View {
    let title: LocalizedStringKey
    let prominent: Bool
    let action: () -> Void
    @State private var hovered = false

    init(_ title: LocalizedStringKey, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(13, .semibold))
                .foregroundStyle(prominent ? LiveLook.openText : CallsLook.quietText)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: prominent ? .infinity : nil)
                .frame(height: 34)
                .background(shape.fill(prominent ? Theme.running.opacity(hovered ? 0.24 : 0.16)
                                                 : (hovered ? Color(white: 0.16) : LiveLook.quietButton)))
                .overlay(shape.strokeBorder(prominent ? Theme.running.opacity(0.45) : Color.white.opacity(0.1),
                                            lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
    }
}

// MARK: - Shared with the notes window

/// "Listening…" with three short bars in Airlock's purple, under a
/// transcript still being written; "Paused" while the notes are.
struct CallLiveListening: View {
    var paused = false
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: size - 3, weight: .semibold))
                    .foregroundStyle(LiveLook.faint)
                    .frame(width: 13)
            } else {
                HStack(alignment: .center, spacing: 2) {
                    ForEach([6, 12, 8] as [CGFloat], id: \.self) { height in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Theme.assistant)
                            .frame(width: 3, height: height)
                    }
                }
                .frame(height: 12)
            }
            Text(paused ? "Paused" : "Listening…")
                .font(Theme.chrome(size))
                .foregroundStyle(LiveLook.faint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Notes paused" : "Listening")
    }
}

/// "● Live", beside a call that is still going: in the list, and on the
/// Transcript tab in a capsule.
struct CallLiveChip: View {
    var capsule = false

    var body: some View {
        HStack(spacing: 5) {
            NotesBreathingDot(size: capsule ? 6 : 7)
            Text("Live")
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(LiveLook.liveText)
        }
        .padding(.horizontal, capsule ? 8 : 0)
        .frame(height: capsule ? 20 : nil)
        .background {
            if capsule { Capsule().fill(Theme.assistant.opacity(0.14)) }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}

extension View {
    /// Keeps a transcript's newest line in view while the person is at its
    /// foot, and leaves them be once they scroll up to read: what arrives
    /// meanwhile is counted on a pill that brings them back down.
    /// `pinsShortToFoot` sets a transcript shorter than the view at its
    /// foot, against the "Listening…" it grows towards.
    func followsNewest(said: Int, enabled: Bool, ground: Color, pinsShortToFoot: Bool = true,
                       scrolledAwayFor away: Int? = nil) -> some View {
        modifier(FollowsNewest(said: said, enabled: enabled, ground: ground, pinsShortToFoot: pinsShortToFoot,
                               away: away))
    }
}

private struct FollowsNewest: ViewModifier {
    /// Things said so far: the count of new lines is a difference of two.
    let said: Int
    /// Off for a call that is over: nothing arrives to follow.
    let enabled: Bool
    /// What the fade over the last lines fades into.
    let ground: Color
    let pinsShortToFoot: Bool
    /// The gallery's "scrolled up": opens at the top, the pill showing.
    let startsAway: Bool

    @State private var position = ScrollPosition(idType: Int.self)
    @State private var following: Bool
    @State private var atEnd = true
    /// Things said when the person scrolled away from the foot.
    @State private var seen: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `away`: drawn as if scrolled up, that many lines ago (the gallery).
    init(said: Int, enabled: Bool, ground: Color, pinsShortToFoot: Bool, away: Int?) {
        self.said = said
        self.enabled = enabled
        self.ground = ground
        self.pinsShortToFoot = pinsShortToFoot
        startsAway = away != nil
        _following = State(initialValue: away == nil)
        _seen = State(initialValue: said - (away ?? 0))
    }

    func body(content: Content) -> some View {
        content
            // Opens on the newest line.
            .defaultScrollAnchor(enabled && !startsAway ? .bottom : nil, for: .initialOffset)
            .defaultScrollAnchor(enabled && pinsShortToFoot ? .bottom : nil, for: .alignment)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let insets = geometry.contentInsets
                return CallLive.isAtEnd(offset: Double(geometry.contentOffset.y + insets.top),
                                        visible: Double(geometry.containerSize.height),
                                        content: Double(geometry.contentSize.height + insets.top + insets.bottom))
            } action: { _, now in
                atEnd = now
            }
            // Only the person's own scrolling decides: a line arriving moves
            // the foot away for a moment too, and that is not leaving it.
            .onScrollPhaseChange { before, phase in
                guard enabled, phase == .idle, before == .interacting || before == .decelerating else { return }
                if atEnd {
                    following = true
                } else if following {
                    following = false
                    seen = said
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                guard enabled, following else { return }
                withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
                    position.scrollTo(edge: .bottom)
                }
            }
            // The opening anchor is not always honoured: a window laid out
            // before it is shown opens at the top. Its first size, and any
            // resize, puts a list that follows back on its newest line.
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, _ in
                guard enabled, following else { return }
                position.scrollTo(edge: .bottom)
            }
            .onAppear {
                guard enabled, following else { return }
                position.scrollTo(edge: .bottom)
            }
            .overlay(alignment: .bottom) {
                if enabled, !following {
                    ZStack(alignment: .bottom) {
                        LinearGradient(stops: [.init(color: ground.opacity(0), location: 0),
                                               .init(color: ground, location: 0.7)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 90)
                            .allowsHitTesting(false)
                        if said > seen {
                            NewLinesPill(count: said - seen, action: backDown)
                                .padding(.bottom, 18)
                        }
                    }
                    .transition(Motion.open.transition(reduceMotion: reduceMotion))
                }
            }
            .animation(Motion.open.animation(reduceMotion: reduceMotion), value: following)
            .onChange(of: enabled) { _, on in
                if !on { following = true }
            }
    }

    private func backDown() {
        following = true
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
            position.scrollTo(edge: .bottom)
        }
    }
}

/// "3 new lines", over the foot of a transcript the person scrolled up.
private struct NewLinesPill: View {
    let count: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CallsLook.takeText)
                Text(CallLive.newLines(count))
                    .font(Theme.chrome(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(hovered ? Color(white: 0.19) : LiveLook.pill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 9, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help("Back to the newest line")
        .accessibilityLabel("\(CallLive.newLines(count)), back to the newest")
    }
}
