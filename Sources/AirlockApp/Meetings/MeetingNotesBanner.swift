import AirlockCore
import SwiftUI

/// The call notes in the panel, above the widgets: the ask, the countdown,
/// the notes being taken (with a field to jot things down), then what the
/// notes say once they are written.
///
/// **Waits in the panel, never opens it.** Only a gate or a question may
/// expand the island by itself; this is neither, so the call pill carries a
/// mark instead (`CallPill`) and the notes are here when you look.
///
/// Neutral greys rather than the amber of the licence line: amber means
/// something is waiting on you, and notes never block anything. Purple is
/// Airlock taking notes, green the finished tick. No sound, ever: this sits
/// beside a call.
struct MeetingNotesBanner: View {
    let meetings: MeetingNotesModel

    var body: some View {
        switch meetings.flow.phase {
        case .idle:
            EmptyView()
        case .offering(let call):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11, weight: .medium))
                    Text("Take notes of \(meetings.callTitle(call))?")
                        .font(Theme.chrome(11, .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    NotesPill("Take notes", prominent: true) { meetings.takeNotes() }
                    NotesPill("Always") { meetings.takeNotes(always: true) }
                        .help("Takes notes of every call from now on, after a short countdown")
                    NotesPill("Not now", quiet: true) { meetings.notNow() }
                }
                .foregroundStyle(Theme.textPrimary)
                Text("Words only, written on this Mac. No audio is kept.")
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .modifier(BannerBox())
        case .startingSoon(let call, let startsAt):
            HStack(spacing: 7) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 11, weight: .medium))
                TimelineView(.periodic(from: startsAt.addingTimeInterval(-MeetingNotesFlow.countdown), by: 1)) { context in
                    Text("Taking notes of \(meetings.callTitle(call)) in \(Self.secondsLeft(to: startsAt, at: context.date))…")
                        .font(Theme.chrome(11, .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                NotesPill("Start now", prominent: true) { meetings.startNow() }
                NotesPill("Skip", quiet: true) { meetings.skipCountdown() }
            }
            .foregroundStyle(Theme.textPrimary)
            .modifier(BannerBox())
        case .recording(let call, let since):
            NotesBeingTaken(meetings: meetings, call: call, since: since,
                            firstStarted: meetings.flow.firstStarted ?? since)
                .modifier(NotesCardBox(live: !meetings.isPaused))
        case .writing(let call):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Writing your notes…")
                        .font(Theme.chrome(11, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .layoutPriority(1)
                    Text("· \(meetings.listedTitle(call))")
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                if meetings.flow.endedBySleep {
                    Text(CallNotesPanel.stoppedBySleep)
                        .font(Theme.chrome(10.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                if meetings.flow.stoppedAtLimit { NotesStoppedAtLimit(meetings: meetings) }
            }
            .modifier(BannerBox())
        case .ready(_, let call):
            NotesReady(meetings: meetings, title: meetings.listedTitle(call))
                .modifier(BannerBox())
        case .failed(let reason):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .medium))
                Text(reason)
                    .font(Theme.chrome(11, .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                NotesClose { meetings.dismiss() }
            }
            .foregroundStyle(Theme.textSecondary)
            .modifier(BannerBox())
        }
    }

    /// The whole seconds before "Always" starts the notes, as the panel and
    /// the call pill count them: 3, 2, 1 and never 0, because at 0 the notes
    /// have started and the count is gone.
    static func secondsLeft(to startsAt: Date, at now: Date) -> Int {
        max(1, Int(startsAt.timeIntervalSince(now).rounded(.up)))
    }

    /// How long "Saved", "Marked…" and "Copied" stay before the line goes
    /// back to what it said.
    static let flashFor: Duration = .seconds(1.6)
}

// MARK: - Taking notes

/// Whether the jot field is being typed in. The clipboard's keys work across
/// the whole panel (Return pastes the row under the pointer), so it stands
/// aside while this is true.
@MainActor
enum CallNotesTyping {
    static var isActive = false
}

/// The notes while they are taken, as one card: the call's tile, its name
/// and how long, three buttons (the window, Pause, Stop), a field to jot
/// into with Mark at its end, and the heads-up for the first minute.
///
/// The transcript is in the window, a click away, not in the card: the card
/// keeps the size it started at, and what the other side says is not shown
/// in the panel to whoever is looking at the screen.
private struct NotesBeingTaken: View {
    let meetings: MeetingNotesModel
    let call: OngoingCall
    let since: Date
    /// When notes on this call first started, which the clock and the
    /// heads-up's minute count from: notes carried on after a drop or a
    /// sleep keep the transcript's times and do not offer the heads-up
    /// again (`MeetingNotesFlow.firstStarted`).
    let firstStarted: Date

    @State private var draft = ""
    @State private var flash: Flash?
    @State private var flashEnds: Task<Void, Never>?
    @State private var copied = false
    @State private var copiedEnds: Task<Void, Never>?
    /// Past the heads-up's minute. Set once, by a wait rather than a clock
    /// that ticks for the rest of the call.
    @State private var headsUpOver: Bool
    @FocusState private var typing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Flash: Equatable { case saved, marked }

    init(meetings: MeetingNotesModel, call: OngoingCall, since: Date, firstStarted: Date) {
        self.meetings = meetings
        self.call = call
        self.since = since
        self.firstStarted = firstStarted
        _headsUpOver = State(initialValue: !CallNotesPanel.showsHeadsUp(notesSince: firstStarted, now: Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            // A browser's sound is heard whole, so a video in another tab
            // ends up in the notes too: said, so it is no surprise.
            if CallGlyph.isBrowser(call.bundleID) {
                Text("Hearing everything \(call.appName) plays")
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .help("A video playing in another tab is written down too")
            }
            // Paused, nothing is meant to reach the notes, so a side not
            // reaching them is no news.
            if !meetings.isPaused { health }
            jotField
            if !headsUpOver { headsUp }
            // Free's last five minutes: said where the notes are, so the
            // stop at the limit is no surprise. Purple like the notes: amber
            // would say something waits on you, and nothing does.
            if meetings.limitWord == .stopsSoon {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(MeetingNotesFlow.LimitWord.stopsSoon.line)
                        .font(Theme.chrome(10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(CallsLook.saidText)
            }
        }
        .task(id: firstStarted) {
            let left = CallNotesPanel.headsUpWindow - Date().timeIntervalSince(firstStarted)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled else { return }
            headsUpOver = true
        }
        .onChange(of: typing) { _, now in CallNotesTyping.isActive = now }
        .onDisappear {
            flashEnds?.cancel()
            copiedEnds?.cancel()
            CallNotesTyping.isActive = false
        }
    }

    // MARK: The call, how long, and the controls

    private var header: some View {
        HStack(spacing: 10) {
            CallAppTile(kind: CallGlyph.kind(for: call), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(meetings.callTitle(call))
                    .font(Theme.chrome(13.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                state
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 5) {
                // First, and in purple: the first person to try the notes
                // never found the window when it sat lower down.
                NotesIconButton("sidebar.right", label: "Open in a window", look: .window) {
                    meetings.openLiveWindow()
                }
                .help("Watch the transcript in a window beside the call")
                if meetings.isPaused {
                    NotesIconButton("play.fill", label: "Resume", look: .prominent) { meetings.resume() }
                        .help("Resume taking notes")
                } else {
                    NotesIconButton("pause.fill", label: "Pause") { meetings.pause() }
                        .help("Nothing said until you resume is written down")
                }
                NotesIconButton("stop.fill", label: "Stop") { meetings.stop() }
                    .help("Stop taking notes and write them")
            }
        }
    }

    /// "Taking notes · 4:12" in purple with the breathing dot, or paused in
    /// grey with a hollow one, as on the call pill: nothing is written.
    @ViewBuilder
    private var state: some View {
        if meetings.isPaused {
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(Theme.textSecondary, lineWidth: 1.2)
                    .frame(width: 7, height: 7)
                Text("Paused · nothing is written down")
            }
            .font(Theme.chrome(11, .semibold))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        } else {
            HStack(spacing: 5) {
                NotesBreathingDot(size: 7)
                TimelineView(.periodic(from: firstStarted, by: 1)) { context in
                    Text("Taking notes · \(CallNotesPanel.clock(context.date.timeIntervalSince(firstStarted)))")
                        .monospacedDigit()
                }
            }
            .font(Theme.chrome(11, .semibold))
            .foregroundStyle(CallsLook.saidText)
            .lineLimit(1)
        }
    }

    // MARK: Jot something down, and Mark

    private var jotField: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 6) {
            TextField("Jot something…", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($typing)
                .onSubmit(save)
                .help("Return keeps the line in the notes, word for word")
            jotStatus
            // Paused, nothing from the last half-minute was written down
            // to mark. The field stays: a jot is the person's own words.
            if CallNotesPanel.offersMark(meetings.flow) {
                NotesMarkButton(marked: flash == .marked) { markIt() }
                    .help("Marks the last \(Int(MeetingRecord.markReach)) seconds as important for the notes")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(shape.fill(Color.white.opacity(0.06)))
        .overlay(shape.strokeBorder(Color.white.opacity(typing ? 0.2 : 0.08), lineWidth: 1))
    }

    /// "Saved" or "Marked…" for a moment, then how many lines are jotted.
    @ViewBuilder
    private var jotStatus: some View {
        Group {
            switch flash {
            case .saved:
                Text("Saved")
                    .transition(Motion.confirm.transition(reduceMotion: reduceMotion))
            case .marked:
                Text(CallNotesPanel.marked)
                    .transition(Motion.confirm.transition(reduceMotion: reduceMotion))
            case nil:
                if let jotted = CallNotesPanel.jotted(meetings.jotCount) {
                    Text(jotted)
                        .foregroundStyle(Theme.textTertiary)
                        .transition(Motion.confirm.transition(reduceMotion: reduceMotion))
                }
            }
        }
        .font(Theme.chrome(10.5))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let before = meetings.jotCount
        meetings.jot(text)
        // Said only when it was kept: notes that stopped a moment ago keep
        // nothing, and the line stays in the field to copy elsewhere.
        guard meetings.jotCount > before else { return }
        draft = ""
        show(.saved)
    }

    private func markIt() {
        guard meetings.mark() else { return }
        show(.marked)
    }

    private func show(_ shown: Flash) {
        flashEnds?.cancel()
        withAnimation(Motion.confirm.animation(reduceMotion: reduceMotion)) { flash = shown }
        flashEnds = Task { @MainActor in
            try? await Task.sleep(for: MeetingNotesBanner.flashFor)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.confirm.animation(reduceMotion: reduceMotion)) { flash = nil }
        }
    }

    // MARK: The heads-up, for the first minute

    @ViewBuilder
    private var headsUp: some View {
        if call.isInPerson {
            // No chat to paste into: said out loud, so nothing to copy.
            Text(CallNotesPanel.roomHeadsUp)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            callHeadsUp
        }
    }

    /// One short line and Copy: the line itself is what gets pasted, so the
    /// card doesn't spell it out (the pointer shows it).
    private var callHeadsUp: some View {
        HStack(spacing: 6) {
            Text("Copy a heads-up to send them")
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .help(CallNotesPanel.headsUp)
            Spacer(minLength: 4)
            NotesPill(copied ? "Copied" : "Copy", quiet: true) {
                meetings.copyHeadsUp()
                copiedEnds?.cancel()
                copied = true
                copiedEnds = Task { @MainActor in
                    try? await Task.sleep(for: MeetingNotesBanner.flashFor)
                    guard !Task.isCancelled else { return }
                    copied = false
                }
            }
            .confirmSettle(when: copied)
            .help("Copies \u{201C}\(CallNotesPanel.headsUp)\u{201D}, to paste into the call's chat")
        }
    }

    // MARK: Whether both sides are heard

    @ViewBuilder
    private var health: some View {
        if meetings.health.yoursMissing {
            // In the room the microphone is everybody, not one side.
            note(call.isInPerson
                 ? "The microphone isn't reaching Airlock. Nothing is being written down."
                 : "Your side isn't reaching Airlock. Only the other side is being written down.")
        }
        // The permission explains a missing other side, so it is said
        // instead of the plain line, not as well.
        if meetings.health.theirsNotAllowed {
            HStack(spacing: 6) {
                note("The other side isn't reaching Airlock. It needs System Audio Recording.")
                Spacer(minLength: 4)
                NotesPill("Open Settings", quiet: true) { meetings.openAudioPermission() }
            }
        } else if meetings.health.theirsMissing {
            note("The other side isn't reaching Airlock. Only your side is being written down.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.chrome(10.5))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Ready

/// The notes, written: the first of the summary and of the to-dos, with
/// the whole of them a tap away, and any minutes left without notes. Notes
/// with nothing in them say only that they are ready.
private struct NotesReady: View {
    let meetings: MeetingNotesModel
    let title: String

    @State private var copied = false
    @State private var copiedEnds: Task<Void, Never>?

    var body: some View {
        let notes = CallNotesPanel.hasNotes(meetings.readyNotes) ? meetings.readyNotes : nil
        let tooLittle = meetings.readyOutcome == .tooLittleSaid
        let later = meetings.readyOutcome == .later
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if tooLittle {
                    // No tick: nothing was made. The same mark as a stretch
                    // the notes could not be written for, below.
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                } else if later {
                    // No tick yet: the notes come later, online.
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.done)
                }
                Text("\(tooLittle ? CallNotesPanel.tooLittleSaid : later ? CallNotesPanel.notesLater : "Notes ready")"
                     + " · \(title)")
                    .font(Theme.chrome(11, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                // Still offered: the page keeps the transcript and anything
                // jotted, but it is not the news, so it is not the bright one.
                NotesPill("Open notes", prominent: !tooLittle) {
                    meetings.showNotes()
                }
                if notes != nil {
                    NotesPill(copied ? "Copied" : "Copy") { copy() }
                        .confirmSettle(when: copied)
                        .help("Copies the notes, to paste anywhere")
                }
                NotesClose { meetings.dismiss() }
            }
            if meetings.flow.endedBySleep {
                Text(CallNotesPanel.stoppedBySleep)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            if meetings.flow.stoppedAtLimit { NotesStoppedAtLimit(meetings: meetings) }
            if let waiting = meetings.readyWaiting {
                Text(waiting)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notes {
                let lead = CallNotesPanel.summaryLead(notes.summary)
                if !lead.isEmpty {
                    Text(lead)
                        .font(Theme.chrome(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let todos = CallNotesPanel.todos(notes.todos)
                if !todos.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(todos.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "square")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(line)
                                    .font(Theme.chrome(10.5))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                        if let more = todos.moreLine {
                            Text(more)
                                .font(Theme.chrome(10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.leading, 15)
                        }
                    }
                }
                // Last, so the notes read first; but always shown, so the
                // to-dos above are not taken for the whole call.
                ForEach(Array(notes.unwritten.enumerated()), id: \.offset) { _, stretch in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "text.badge.xmark")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                        Text(stretch.sentence)
                            .font(Theme.chrome(10.5).italic())
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // This month's online notes are used, so the Mac wrote these:
            // said once a month, as news rather than as a fault. On a Mac
            // that can't write notes, said every time, with the day they
            // will be written.
            if let until = meetings.readyAllowance {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CloudNotesAllowance.message(until: until, macWrites: meetings.readyAllowanceMacWrites,
                                                     plan: CloudNotesService.shared.plan()))
                        .font(Theme.chrome(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if CloudNotesAllowance.offersUpgrade {
                        NotesPill(CloudNotesAllowance.upgradeButton, quiet: true) { meetings.showPlans() }
                            .help("Opens Airlock's plans on the website")
                    }
                }
            }
        }
        .onDisappear { copiedEnds?.cancel() }
    }

    private func copy() {
        meetings.copyNotes()
        copiedEnds?.cancel()
        copied = true
        copiedEnds = Task { @MainActor in
            try? await Task.sleep(for: MeetingNotesBanner.flashFor)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// Under notes that Free stopped at its limit, being written or ready: how
/// much was kept, what Plus would have done, and the way to it. Quiet grey:
/// it is news about the notes, not something to answer.
private struct NotesStoppedAtLimit: View {
    let meetings: MeetingNotesModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(MeetingNotesFlow.LimitWord.stopped.line)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            NotesPill("See Plus", quiet: true) { meetings.showPlans() }
                .help("Opens Airlock's plans")
        }
    }
}

// MARK: - Pieces

/// A small rounded button, as the licence line has them. The notch's Calls
/// tab uses it too, so the two ways into the notes look alike.
struct NotesPill: View {
    let title: String
    var prominent = false
    var quiet = false
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, quiet: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.quiet = quiet
        self.action = action
    }

    var body: some View {
        Text(title)
            .font(Theme.chrome(11, .semibold))
            .foregroundStyle(quiet ? Theme.textSecondary : Theme.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(quiet ? 0.04 : prominent ? 0.16 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(quiet ? 0.08 : 0.16), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .clickable()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// A square button with a symbol: the card's window, Pause and Stop.
/// `.window` is in Airlock's purple, as the notes being taken are.
private struct NotesIconButton: View {
    enum Look { case plain, prominent, window }

    let symbol: String
    let label: String
    var look: Look = .plain
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    init(_ symbol: String, label: String, look: Look = .plain, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.look = look
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: 28, height: 28)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { inside in
                withAnimation(MotionEffect.pointer) { hovered = inside }
            }
            .clickable()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private var ink: Color {
        guard look == .window else { return Theme.textPrimary }
        return colorScheme == .dark ? LiveLook.liveText : LiveLook.windowTextOnLight
    }

    private var fill: Color {
        switch look {
        case .window: Theme.assistant.opacity(hovered ? 0.24 : 0.16)
        case .prominent: Color.white.opacity(hovered ? 0.22 : 0.16)
        case .plain: Color.white.opacity(hovered ? 0.14 : 0.08)
        }
    }

    private var edge: Color {
        switch look {
        case .window: Theme.assistant.opacity(0.45)
        case .prominent: Color.white.opacity(0.2)
        case .plain: Color.white.opacity(0.1)
        }
    }
}

/// Mark, at the end of the jot field: a bookmark, filled in purple for the
/// moment "Marked…" shows beside it.
private struct NotesMarkButton: View {
    let marked: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Image(systemName: marked ? "bookmark.fill" : "bookmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(marked ? CallsLook.saidText : hovered ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: 22, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { inside in
                withAnimation(MotionEffect.pointer) { hovered = inside }
            }
            .clickable()
            .accessibilityLabel("Mark")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

private struct NotesClose: View {
    let action: () -> Void

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .clickable()
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// The card notes are taken in: Airlock's purple while they are, as on the
/// call pill; grey while paused, when nothing is written.
private struct NotesCardBox: ViewModifier {
    let live: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(live
                ? AnyShapeStyle(LinearGradient(colors: [Theme.assistant.opacity(0.14), Theme.assistant.opacity(0.05)],
                                               startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(Color.white.opacity(0.06))))
            .overlay(shape.strokeBorder(live ? Theme.assistant.opacity(0.28) : Color.white.opacity(0.08),
                                        lineWidth: 1))
    }
}

/// The licence line's box, in grey.
private struct BannerBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06)))
    }
}

extension EnvironmentValues {
    /// The call pill's mark for call notes, set where the compact island is
    /// drawn so `CallPill` needs no model.
    @Entry var callNotesMark: MeetingNotesFlow.PillMark = .none
    /// Free's word about the notes' limit, and since when (`CallPill`).
    @Entry var callNotesLimit: CallNotesLimit?
}

/// Free's word about the notes' limit, as the call pill gets it.
struct CallNotesLimit: Equatable {
    let word: MeetingNotesFlow.LimitWord
    let since: Date

    /// Whether the closed notch still says it at `now`.
    func shows(at now: Date) -> Bool {
        let shown = now.timeIntervalSince(since)
        return shown >= 0 && shown < MeetingNotesFlow.LimitWord.pillFor
    }
}
