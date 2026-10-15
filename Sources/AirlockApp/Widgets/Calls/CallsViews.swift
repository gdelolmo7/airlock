import AirlockCore
import SwiftUI

/// Panel section: the notch's Calls tab, drawn from the list the meetings
/// model keeps (`RecentCalls`). The list is read again as the tab comes on
/// screen and watched while it stays, so nothing here reads a file.
struct CallsSectionView: View {
    let meetings: MeetingNotesModel

    var body: some View {
        let recent = meetings.recentCalls
        let takingNotes = if case .recording = meetings.flow.phase { true } else { false }
        CallsCardContent(rows: recent.rows, loaded: recent.loaded, week: recent.week,
                         takingNotes: takingNotes,
                         hand: meetings.handButton,
                         reading: meetings.recordings.reading,
                         onOpen: { meetings.showCall(folder: $0.folder) },
                         onAllCalls: { meetings.showPastCalls(fromIsland: true) },
                         onHand: { meetings.pressHandButton() },
                         onAddRecording: { meetings.addRecording() },
                         onStopReading: { meetings.recordings.stop() })
            .onAppear {
                recent.refresh()
                recent.startWatching()
            }
            .onDisappear { recent.stopWatching() }
    }
}

/// The tab as a function of what it shows, so the state gallery can draw it
/// from made-up calls.
///
/// A header with how many calls this week, the recording being read (if
/// any), then the calls by day, newest first: each day a small heading
/// over its own rounded box, each call a row with the app's tile, the name,
/// the clock and how many were on it, and the to-dos it left. A call's name
/// and facts only, never what was said: the panel opens in front of whoever
/// is looking at the screen.
struct CallsCardContent: View {
    let rows: [CallsCard.Row]
    /// False until the first read: neither rows nor "No calls yet" yet.
    var loaded = true
    /// Finished calls begun this week (`CallsCard.thisWeek`).
    var week = 0
    /// Notes are being taken. The card above the tabs has the call, so the
    /// tab draws no row for it, and no "No calls yet" under the card.
    var takingNotes = false
    /// What "Today" and "Yesterday" are counted from. Nil is now.
    var now: Date?
    /// "Take notes" (`MeetingNotesFlow.handButton`); nil draws no button, as
    /// in a gallery row about something else. No button while notes are
    /// taken: the banner above the tabs has Pause and Stop.
    var hand: MeetingNotesFlow.HandButton?
    /// The recording being read into a meeting; nil when none.
    var reading: RecordingImporter.Reading?
    var onOpen: (CallsCard.Row) -> Void = { _ in }
    var onAllCalls: () -> Void = {}
    var onHand: () -> Void = {}
    /// "Add recording"; nil draws no button, as in a gallery row about
    /// something else.
    var onAddRecording: (() -> Void)?
    var onStopReading: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)
            if let reading {
                CallsReadingRow(reading: reading, stop: onStopReading)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            if !listed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(CallsCard.days(listed, now: now ?? Date())) { day in
                        daySection(day)
                    }
                }
            } else if loaded, !takingNotes, reading == nil {
                emptyState
            }
        }
        // A call whose notes land while the panel is open joins the list as
        // a Swap, not in one frame; so does a row leaving for the Bin, and
        // "No calls yet" as notes start and stop.
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: rows.map(\.id))
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: takingNotes)
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: reading == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CallsCard.title)
    }

    /// The calls by day, less the one a recording is being read into: the
    /// row at the top already stands for it, and its notes aren't written.
    private var listed: [CallsCard.Row] {
        guard let folder = reading?.folder?.lastPathComponent else { return rows }
        return rows.filter { $0.folder != folder }
    }

    private var takesNotes: (label: String, hand: MeetingNotesFlow.HandButton)? {
        guard let hand, hand != .stop, let label = CallsCard.handLabel(hand) else { return nil }
        return (label, hand)
    }

    /// The name and how many calls this week on the left, the ways in on the
    /// right: "Take notes" for a meeting with no call, "Add recording" for one
    /// already recorded, then "All calls". No "All calls" before there is a
    /// call to see: the window would only say there are none.
    private var header: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CallsCard.title)
                    .font(Theme.chrome(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if !rows.isEmpty, let line = CallsCard.weekLine(week) {
                    Text(line)
                        .font(Theme.chrome(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let take = takesNotes {
                CallsTakeNotesButton(title: take.label, action: onHand)
                    .help(CallsCard.handHelp(take.hand))
            }
            if let onAddRecording {
                CallsAddRecordingButton(busy: reading != nil, action: onAddRecording)
            }
            if !rows.isEmpty {
                CallsAllCallsButton(action: onAllCalls)
            }
        }
        .frame(minHeight: 26)
        .padding(.horizontal, 4)
    }

    /// A day's heading over its calls, the calls in a box of their own, so a
    /// glance down the tab finds a day before it reads a row.
    private func daySection(_ day: CallsCard.Day) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.heading)
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .accessibilityAddTraits(.isHeader)
            CallsDayBox(rows: day.rows, onOpen: onOpen)
        }
    }

    /// Said rather than hidden while call notes are on and nothing is saved
    /// yet, in the middle of the tab where the first call will land, with
    /// the apps whose calls get notes.
    private var emptyState: some View {
        VStack(spacing: 0) {
            // The character, as the empty clipboard has it, in the brand's
            // blue and looking up: waiting for the first call rather than
            // unimpressed by none. Hidden from VoiceOver and still under
            // Reduce Motion by `BloubView` itself.
            BloubView(expression: .attentive, motion: .breathing, tint: BloubTint.working.color)
                .frame(width: 36, height: 36)
            Text(CallsCard.emptyTitle)
                .font(Theme.chrome(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 10)
            Text(takesNotes == nil ? CallsCard.emptyLine : CallsCard.emptyLine + "\n" + CallsCard.emptyRoomLine)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 7) {
                ForEach(Self.emptyApps.indices, id: \.self) { index in
                    CallAppTile(kind: Self.emptyApps[index], size: 26)
                }
                Text("and more")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 3)
                    .accessibilityHidden(true)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .accessibilityElement(children: .combine)
    }

    /// The apps the empty tab shows, as a hint of where notes come from:
    /// Meet, Zoom, WhatsApp, Slack, Discord and a phone call.
    private static let emptyApps: [CallGlyph.Kind] = [
        .logo("googlemeet"), .symbol("video.fill"), .logo("whatsapp"),
        .logo("slack"), .logo("discord"), .symbol("phone.fill"),
    ]
}

/// "Take notes", in the blue of Airlock's own buttons, with a microphone.
private struct CallsTakeNotesButton: View {
    let title: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(Theme.chrome(11.5, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CallsLook.takeText)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 26)
            .background(Capsule().fill(Theme.running.opacity(hovered ? 0.26 : 0.18)))
            .overlay(Capsule().strokeBorder(Theme.running.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
    }
}

/// "Add recording", dark beside "Take notes"'s blue: a recording somebody
/// already has, read into a meeting. Greyed while one is being read.
private struct CallsAddRecordingButton: View {
    let busy: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add recording")
                    .font(Theme.chrome(11.5, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CallsLook.quietText)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hovered && !busy ? 0.1 : 0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help(busy ? "Airlock reads one recording at a time"
                   : "Get notes from a recording you already have, like a voice memo")
    }
}

/// "All calls ›": quiet, beside "Take notes", into the notes window.
private struct CallsAllCallsButton: View {
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(CallsCard.allCalls)
                    .font(Theme.chrome(11.5, .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help("Open the notes of every call")
    }
}

/// A day's calls in their box, a hairline between rows, hidden either side
/// of the row the pointer is on so its wash reads as one piece.
private struct CallsDayBox: View {
    let rows: [CallsCard.Row]
    let onOpen: (CallsCard.Row) -> Void

    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                CallsTabRow(row: row, hovered: hovered == row.id,
                            onHover: { inside in
                                withAnimation(MotionEffect.pointer) {
                                    if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                                }
                            },
                            open: { onOpen(row) })
                    .overlay(alignment: .bottom) {
                        let next = index + 1 < rows.count ? rows[index + 1].id : nil
                        if next != nil, hovered != row.id, hovered != next {
                            Rectangle()
                                .fill(Theme.rowStroke)
                                .frame(height: 1)
                                .padding(.leading, 50)
                                .padding(.trailing, 10)
                                .offset(y: 0.5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Theme.rowStroke, lineWidth: 1)
                )
        )
    }
}

/// One call: the app it was in, its name over its clock, length and (for
/// three or more) how many were on it, and the to-dos it left. The whole row
/// opens the notes window on it, and says so with a chevron on hover.
private struct CallsTabRow: View {
    let row: CallsCard.Row
    let hovered: Bool
    let onHover: (Bool) -> Void
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                CallAppTile(kind: CallGlyph.kind(for: row))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(Theme.chrome(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    subline
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let todos = CallsCard.todos(row.todos) {
                    CallsTodoChip(text: todos)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 10)
                    .opacity(hovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.055 : 0))
                .allowsHitTesting(false)
        }
        .onHover(perform: onHover)
        .clickable()
        .help("Open the notes of this call")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the notes of this call")
    }

    private var subline: some View {
        HStack(spacing: 0) {
            Text(CallsCard.span(from: row.startedAt, to: row.endedAt))
            if let crowd = row.crowd {
                Text("  ·  ")
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .accessibilityHidden(true)
                Text("\u{2009}\(crowd)")
                    .accessibilityLabel("\(crowd) people")
            }
        }
        .font(Theme.chrome(11, .medium))
        .foregroundStyle(Theme.textSecondary)
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// "3 to-dos" in the to-dos' orange: things waiting, not a line of text.
private struct CallsTodoChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checklist")
                .font(.system(size: 10.5, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.chrome(10.5, .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(CallsLook.todoText)
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.needs.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Theme.needs.opacity(0.22), lineWidth: 1))
        .fixedSize()
    }
}

/// A recording being read into a meeting, in teal: its tile, its name, what
/// is being done, how far along and how long is left, a bar, and Stop. The
/// notes window has the steps and the lines heard so far.
private struct CallsReadingRow: View {
    let reading: RecordingImporter.Reading
    let stop: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let progress = reading.progress
        HStack(spacing: 12) {
            CallAppTile(kind: CallGlyph.recording, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(RecordingImport.title(forFile: progress.fileName))
                    .font(Theme.chrome(13.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    if reading.stopping {
                        Text("Stopping\u{2026}")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(progress.doing)
                            .foregroundStyle(CallsLook.recording)
                        dot
                        Text("\(progress.percent)%")
                            .foregroundStyle(Theme.textPrimary)
                        dot
                        Text(progress.timeLeftShort)
                            .font(Theme.chrome(11, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(Theme.chrome(11, .semibold))
                .monospacedDigit()
                .lineLimit(1)
                RecordingProgressBar(fraction: progress.fraction, height: 3)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RecordingStopButton(stopping: reading.stopping, action: stop)
        }
        .padding(10)
        .background(
            shape.fill(LinearGradient(colors: [CallsLook.recording.opacity(0.12), CallsLook.recording.opacity(0.04)],
                                      startPoint: .leading, endPoint: .trailing))
        )
        .overlay(shape.strokeBorder(CallsLook.recording.opacity(0.26), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var dot: some View {
        Text("\u{00B7}")
            .foregroundStyle(Theme.textTertiary)
            .accessibilityHidden(true)
    }
}
