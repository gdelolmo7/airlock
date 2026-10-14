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
    /// Whether "Show transcript" starts open. Shut in the panel; the state
    /// gallery opens it to draw it.
    var transcriptShown = false

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
                            firstStarted: meetings.flow.firstStarted ?? since,
                            transcriptShown: transcriptShown)
                .modifier(BannerBox())
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

/// The notes while they are taken: how long and the controls, a field to
/// jot into, the heads-up for the first minute, and the transcript on ask.
private struct NotesBeingTaken: View {
    let meetings: MeetingNotesModel
    let call: OngoingCall
    let since: Date
    /// When notes on this call first started, which the clock and the
    /// heads-up's minute count from: notes carried on after a drop or a
    /// sleep keep the transcript's times and do not offer the heads-up
    /// again (`MeetingNotesFlow.firstStarted`).
    let firstStarted: Date

    @State private var showsTranscript: Bool
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

    init(meetings: MeetingNotesModel, call: OngoingCall, since: Date, firstStarted: Date,
         transcriptShown: Bool) {
        self.meetings = meetings
        self.call = call
        self.since = since
        self.firstStarted = firstStarted
        _showsTranscript = State(initialValue: transcriptShown)
        _headsUpOver = State(initialValue: !CallNotesPanel.showsHeadsUp(notesSince: firstStarted, now: Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            status
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
            jotRow
            if !headsUpOver { headsUp }
            transcript
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

    // MARK: Row 1: how long, and the controls

    private var status: some View {
        HStack(spacing: 7) {
            if meetings.isPaused {
                // Hollow and grey, as on the call pill: nothing is written.
                Circle()
                    .strokeBorder(Theme.textSecondary, lineWidth: 1.2)
                    .frame(width: 7, height: 7)
                Text("Paused · nothing is written down")
                    .font(Theme.chrome(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            } else {
                NotesBreathingDot(size: 7)
                TimelineView(.periodic(from: firstStarted, by: 1)) { context in
                    Text("Taking notes · \(CallNotesPanel.clock(context.date.timeIntervalSince(firstStarted)))")
                        .font(Theme.chrome(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Spacer(minLength: 6)
            // On the first line, beside the controls. It used to sit by
            // "Show transcript", under the jot field and the heads-up, and
            // the first person to try it never found it there.
            NotesOpenInWindow { meetings.openLiveWindow() }
            if meetings.isPaused {
                NotesPill("Resume", prominent: true) { meetings.resume() }
            } else {
                NotesPill("Pause") { meetings.pause() }
                    .help("Nothing said until you resume is written down")
            }
            NotesPill("Stop") { meetings.stop() }
        }
    }

    // MARK: Row 2: jot something down

    private var jotRow: some View {
        HStack(spacing: 6) {
            TextField("Jot something…", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textPrimary)
                .focused($typing)
                .onSubmit(save)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(typing ? 0.2 : 0.08), lineWidth: 1))
                .help("Return keeps the line in the notes, word for word")
            jotStatus
            // Paused, nothing from the last half-minute was written down
            // to mark. The field stays: a jot is the person's own words.
            if CallNotesPanel.offersMark(meetings.flow) {
                NotesPill("Mark", quiet: true) { markIt() }
                    .help("Marks the last \(Int(MeetingRecord.markReach)) seconds as important for the notes")
            }
        }
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

    // MARK: Row 3: the heads-up, for the first minute

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

    private var callHeadsUp: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Let them know:")
                .font(Theme.chrome(10.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            Text(CallNotesPanel.headsUp)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
            .help("Copies the line, to paste into the call's chat")
        }
    }

    // MARK: Row 4: the transcript, on ask

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: showsTranscript ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 9)
                    Text(showsTranscript ? "Hide transcript" : "Show transcript")
                        .font(Theme.chrome(10.5, .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
                .onTapGesture { showsTranscript.toggle() }
                .clickable()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { showsTranscript.toggle() }
                Spacer(minLength: 0)
            }

            if showsTranscript {
                let hearing = CallLive.speaking(meetings.live.hearing, paused: meetings.isPaused)
                if meetings.recentLines.isEmpty, hearing.isEmpty {
                    Text(meetings.isPaused ? "Nothing is written down while paused." : "Nothing heard yet.")
                        .font(Theme.chrome(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 13)
                } else {
                    ForEach(Array(meetings.recentLines.enumerated()), id: \.offset) { _, line in
                        if line.isDivider {
                            // Quiet, as in the notes window: the lines
                            // below it say the rest.
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                    .font(Theme.chrome(9.5))
                                Text(line.text)
                                    .font(Theme.chrome(10.5))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 13)
                            .accessibilityElement(children: .combine)
                        } else {
                            Text("\(Text(line.speaker).fontWeight(.semibold))  \(line.text)")
                                .font(Theme.chrome(10.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 13)
                        }
                    }
                    // What is being said now, fainter, where the speaker
                    // has got to.
                    ForEach(hearing, id: \.speaker) { heard in
                        let name = meetings.live.record?.label(for: heard.speaker) ?? heard.speaker.label
                        Text("\(Text(name).fontWeight(.semibold))  \(CallLive.newest(heard.text, limit: 140))")
                            .font(Theme.chrome(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 13)
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if tooLittle {
                    // No tick: nothing was made. The same mark as a stretch
                    // the notes could not be written for, below.
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.done)
                }
                Text("\(tooLittle ? CallNotesPanel.tooLittleSaid : "Notes ready") · \(title)")
                    .font(Theme.chrome(11, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                // Still offered: the page keeps the transcript and anything
                // jotted, but it is not the news, so it is not the bright one.
                // Nor while the question below is asked: that has the one.
                NotesPill("Open notes", prominent: !tooLittle && !meetings.readyAsksOnline) {
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
            // said once a month, as news rather than as a fault.
            if let until = meetings.readyAllowance {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CloudNotesAllowance.message(until: until))
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
            // Asked once, before any meeting leaves the Mac: these notes
            // were written here, and a yes writes them again online.
            if meetings.readyAsksOnline {
                NotesOnlineQuestion(meetings: meetings)
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

/// "Write better notes online?", under notes that could have been written
/// online by someone who hasn't said whether they may (`CloudNotesQuestion`).
/// Closing the line without an answer leaves it unasked, for the next meeting.
private struct NotesOnlineQuestion: View {
    let meetings: MeetingNotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CloudNotesQuestion.title)
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(CloudNotesQuestion.text)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 6) {
                Text(CloudNotesQuestion.settingsLine)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                NotesPill(CloudNotesQuestion.keepButton, quiet: true) { meetings.keepNotesOnMac() }
                    .help("Notes stay written on this Mac, and this isn't asked again")
                NotesPill(CloudNotesQuestion.writeButton, prominent: true) { meetings.writeNotesOnline() }
                    .help("Writes these notes again online, keeping this Mac's beside them")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
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

/// "Open in a window", beside Pause and Stop here and on the Calls tab's
/// live row: the whole transcript, as it is written, in a narrow window
/// beside the call. In Airlock's purple, as the notes being taken are.
struct NotesOpenInWindow: View {
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(dark ? LiveLook.liveText : LiveLook.windowTextOnLight)
            Text("Open in a window")
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(dark ? LiveLook.windowText : LiveLook.windowTextOnLight)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(shape.fill(Theme.assistant.opacity(hovered ? 0.22 : 0.14)))
        .overlay(shape.strokeBorder(Theme.assistant.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help("Watch the transcript in a window beside the call")
        .accessibilityElement(children: .combine)
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
}
