import AirlockCore
import SwiftUI
import EventKit

/// A week at a glance: month, then today and the six days after it, today
/// ringed. Forward-looking rather than centred on today — yesterday's date is
/// dead width in a column this narrow, and the agenda below is upcoming too.
///
/// Re-evaluates on a slow tick so the highlight follows midnight without a
/// panel reopen.
struct WeekStripView: View {
    @Environment(CalendarWidgetModel.self) private var calendar

    /// Leading-most visible day. Drives the scroll and is what a drag moves.
    @State private var anchorDay: Date?
    /// Where the current drag started from, so movement is measured against the
    /// grab point rather than accumulating per event.
    @State private var dragOrigin: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The picked day's circle is one shape that slides to the next day you
    /// pick (owner, 2026-10-04), and fades when you clear it.
    @Namespace private var selection

    /// The narrowest a day may be. The real width shares the strip out so
    /// only whole days show (`DayStripFit`).
    private static let minimumCellWidth: CGFloat = 30
    private static let cellSpacing: CGFloat = 2
    /// The strip's measured width, for the drag. The cells size themselves in
    /// layout, so this is never what decides how they look.
    @State private var stripWidth: CGFloat = 0
    /// One cell of travel moves one day, so dragging tracks the strip 1:1.
    private var cellPitch: CGFloat { Self.cellWidth(for: stripWidth) + Self.cellSpacing }

    private static func cellWidth(for width: CGFloat) -> CGFloat {
        CGFloat(DayStripFit.cellWidth(for: Double(width), minimum: Double(minimumCellWidth),
                                      spacing: Double(cellSpacing)))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 300)) { context in
            let cal = Calendar.current
            let today = cal.startOfDay(for: context.date)
            let days = dayRange(from: today, calendar: cal)

            VStack(alignment: .leading, spacing: 4) {
                // **The week strip stays here — decided, not overlooked.**
                //
                // The design bundle's home column drops it and footnotes "week
                // strip → calendar tab", i.e. it moves to a tab that does not
                // exist. Asked directly, the owner kept it: the strip is the
                // date context the agenda is read against, and a two-event list
                // under a bare date is less use than the same list under a week
                // you can see yourself in.
                //
                // So a later pass measuring this column against the mockup will
                // find a difference that is a choice. Leave it.

                // Date on the left, SCOPE on the right. The agenda below is not
                // "your calendar" — it is the next day of it — and a column of
                // two events under a bare date reads as a suspiciously empty
                // week rather than as a deliberately short horizon.
                HStack(alignment: .firstTextBaseline) {
                    Text(monthLabel(today: today, calendar: cal))
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 6)
                    Text(CalendarWidgetModel.scopeLabel(selectedDay: calendar.selectedDay, now: context.date))
                        .font(Theme.chrome(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 4)

                ScrollView(.horizontal) {
                    HStack(spacing: Self.cellSpacing) {
                        ForEach(days, id: \.self) { day in
                            dayCell(day,
                                    isToday: cal.isDate(day, inSameDayAs: today),
                                    isSelected: calendar.selectedDay == day,
                                    hasEvents: calendar.daysWithEvents.contains(day))
                        }
                    }
                    .scrollTargetLayout()
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                               value: calendar.selectedDay)
                }
                .scrollIndicators(.never)
                .ticksAtScrollEnds(.horizontal)
                // Rests on a whole day, so a scroll can't leave half of one at
                // either edge either.
                .scrollTargetBehavior(.viewAligned)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
                .scrollPosition(id: $anchorDay, anchor: .leading)
                // Land on today rather than a week ago, every time the panel
                // opens — the past is reachable, not the default view.
                .onAppear { if anchorDay == nil { anchorDay = today } }
                // Trackpad scrolling already worked; this is the grab-and-slide
                // a mouse user reaches for, which macOS ScrollView doesn't give.
                .gesture(dragToPan(across: days, calendar: cal))
            }
        }
    }

    /// The strip's span matches exactly what the model has read, so a day
    /// without a mark genuinely has nothing on it.
    private func dayRange(from today: Date, calendar cal: Calendar) -> [Date] {
        let span = -CalendarWidgetModel.stripPastDays..<CalendarWidgetModel.stripFutureDays
        return span.compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    /// Names the month you're looking at — the selected day's, else today's.
    /// The year only earns its space once you've scrolled out of this one.
    private func monthLabel(today: Date, calendar cal: Calendar) -> String {
        let anchor = calendar.selectedDay ?? today
        let sameYear = cal.component(.year, from: anchor) == cal.component(.year, from: today)
        return sameYear
            ? anchor.formatted(.dateTime.month(.abbreviated))
            : anchor.formatted(.dateTime.month(.abbreviated).year())
    }

    /// A tap gesture rather than a Button: a Button would swallow the drag that
    /// starts on top of a cell, which is every drag.
    private func dayCell(_ day: Date, isToday: Bool, isSelected: Bool, hasEvents: Bool) -> some View {
        VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(isToday ? Theme.running : Theme.textTertiary)
            Text(day.formatted(.dateTime.day()))
                .font(Theme.chrome(11, isToday || isSelected ? .bold : .medium))
                .foregroundStyle(fill(isToday: isToday, isSelected: isSelected) == nil
                                 ? Theme.textSecondary : Theme.pill)
                .monospacedDigit()
                .frame(width: 18, height: 18)
                .background {
                    if isSelected {
                        Circle()
                            .fill(Theme.textPrimary)
                            .matchedGeometryEffect(id: "selectedDay", in: selection)
                    } else if isToday {
                        Circle().fill(Theme.running)
                    }
                }
            Circle()
                .fill(hasEvents ? Theme.textTertiary : .clear)
                .frame(width: 3, height: 3)
        }
        .containerRelativeFrame(.horizontal) { length, _ in Self.cellWidth(for: length) }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the selected day clears it — the way back to the rolling
            // agenda is the same gesture that left it.
            calendar.select(day: isSelected ? nil : day)
        }
        .help(day.formatted(date: .complete, time: .omitted))
        // The cell renders a bare numeral and a 3pt dot, so spell out the date,
        // whether anything is on it, and whether it is the selected one — none
        // of which survives being read as "14".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted)
                            + (hasEvents ? ", has events" : ""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { calendar.select(day: isSelected ? nil : day) }
    }

    /// Translates horizontal drag into day steps from the grab point. Measuring
    /// against `dragOrigin` rather than accumulating means a drag out and back
    /// returns you exactly where you started.
    private func dragToPan(across days: [Date], calendar cal: Calendar) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let origin = dragOrigin ?? anchorDay ?? days.first
                if dragOrigin == nil { dragOrigin = origin }
                guard let origin else { return }
                let steps = Int((-value.translation.width / cellPitch).rounded())
                guard let target = cal.date(byAdding: .day, value: steps, to: origin) else { return }
                anchorDay = days.first { $0 >= target } ?? days.last
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// Today is the blue anchor; a picked day borrows the foreground so the two
    /// never compete for the same emphasis.
    private func fill(isToday: Bool, isSelected: Bool) -> Color? {
        if isSelected { return Theme.textPrimary }
        if isToday { return Theme.running }
        return nil
    }
}

/// Panel section: the next few timed events, with one-click Join when a
/// meeting link is detected. Glance tier — hints in compact, never expands.
struct CalendarSectionView: View {
    @Environment(CalendarWidgetModel.self) private var calendar
    /// Settings at the calendar list, for the "nothing ticked" card.
    var onChooseCalendars: () -> Void = {}

    var body: some View {
        Group {
            if let card = calendar.accessCard {
                accessRow(card)
            } else {
                // The strip is the date context; the rows below are the agenda.
                // Both states get it — a week with nothing in it is still worth
                // orienting you.
                VStack(alignment: .leading, spacing: 8) {
                    WeekStripView()
                    if calendar.selection.readsNothing {
                        ProblemCard(icon: "calendar", sentence: CalendarWidgetModel.nothingTicked,
                                    button: CalendarWidgetModel.chooseCalendars, action: onChooseCalendars)
                    } else if calendar.isLoadingDay {
                        AgendaSkeletonView()
                    } else if agenda.isEmpty {
                        // Access granted but nothing scheduled — say so, don't
                        // render a blank hole (the 'still doesn't show' bug).
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                            Text(emptyNote)
                                .font(Theme.chrome(11))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            // Above the timed rows and out of their list, so a
                            // day with two "OOO" markers lays its meetings out
                            // at the same y as a day with none.
                            if !allDayEvents.isEmpty {
                                AllDayStripView(events: allDayEvents)
                            }
                            if !timedEvents.isEmpty {
                                TimedAgendaView(events: timedEvents, day: calendar.selectedDay)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.rowFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Theme.rowStroke, lineWidth: 1)
                                )
                        )
                    }
                }
            }
        }
    }

    /// Picking a day in the strip swaps the rolling agenda for that day's.
    private var agenda: [CalendarEvent] {
        calendar.selectedDay == nil ? calendar.upcoming : calendar.selectedDayEvents
    }

    /// The two lists are laid out differently because they answer different
    /// questions: an all-day row is a fact about the day, a timed row is a
    /// place to be at a time.
    private var allDayEvents: [CalendarEvent] { agenda.filter(\.isAllDay) }
    private var timedEvents: [CalendarEvent] { agenda.filter { !$0.isAllDay } }

    private var emptyNote: String {
        guard let day = calendar.selectedDay else { return "No meetings in the next 24 hours." }
        if Calendar.current.isDateInToday(day) { return "Nothing left today." }
        return "Nothing on \(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))."
    }

    /// The first-run offer keeps its quiet look; every other state is a
    /// problem and looks like one.
    @ViewBuilder private func accessRow(_ card: CalendarAccessCard) -> some View {
        if card.isProblem {
            ProblemCard(icon: "calendar", sentence: card.sentence,
                        button: card.remedy.button,
                        action: card.remedy == .nothing ? nil : { calendar.performRemedy(card.remedy) })
        } else {
            invitation(card)
        }
    }

    private func invitation(_ card: CalendarAccessCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 1)
                Text(card.sentence)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button = card.remedy.button {
                Button { calendar.performRemedy(card.remedy) } label: {
                    Label(button, systemImage: "calendar.badge.checkmark")
                        .font(Theme.chrome(10, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .clickable()
                .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Holds the card's shape while a day loads, so switching days doesn't collapse
/// the panel and spring it back. Two rows because that's the common count —
/// close enough that the real agenda replacing it doesn't jump.
private struct AgendaSkeletonView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.textTertiary)
                        .frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.textTertiary)
                            .frame(width: 116, height: 9)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.textTertiary)
                            .frame(width: 68, height: 8)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .opacity(dim ? 0.18 : 0.34)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.rowStroke, lineWidth: 1)
                )
        )
        // The shimmer is a loading hint, not information — a statically dimmed
        // skeleton says "not here yet" just as well. Guarded on the call rather
        // than by swapping the animation, because the repeat is opened by
        // `withAnimation` here and there is no modifier to degrade.
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(MotionEffect.pulse) { dim = true }
        }
    }
}

/// All-day events as a chip row of their own: one line, fixed height, scrolled
/// sideways when there are more than fit.
///
/// They used to share the list with timed events, so a day with two of them laid
/// the meetings out lower than a day with none, and six pushed the timed rows —
/// the ones whose whole point is a time — off the bottom of the card. Height is
/// a constant precisely so that stops being possible: the timed list starts at
/// the same y whether there is one all-day marker or nine.
///
/// That constant is also why a chip's Join is a glyph and not the timed row's
/// labelled capsule. It still has to be there — a multi-day conference with a
/// permanent room link is the case, and the chip row briefly took it from one
/// click to none — but nothing a chip gains may make it taller than a chip
/// without it, which would push every timed row below by however many points
/// the tallest chip won.
private struct AllDayStripView: View {
    let events: [CalendarEvent]
    @Environment(CalendarWidgetModel.self) private var calendar

    /// Scales with the text setting, because a fixed box around growing type
    /// clips it — but capped, since the strip's job is to stay out of the way.
    @MainActor private static var height: CGFloat { 22 * min(Theme.textScale, 1.25) }
    /// Long titles truncate rather than making one chip wider than the card.
    @MainActor private static var titleWidth: CGFloat { 120 * min(Theme.textScale, 1.25) }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(events) { event in chip(event) }
            }
            // The capsule strokes sit on the chip's edge; without this the
            // first and last are shaved by the scroll view's clip.
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .ticksAtScrollEnds(.horizontal)
        .frame(height: Self.height)
    }

    private func chip(_ event: CalendarEvent) -> some View {
        HStack(spacing: 0) {
            // Two targets that do not overlap, rather than a button nested in
            // the chip's own tap gesture: which of the two a click reaches would
            // then be down to gesture precedence, and the wrong answer opens
            // Calendar *and* the call. The dot and the title carry the leading
            // padding so the whole left of the capsule still opens the event.
            HStack(spacing: 4) {
                Circle()
                    .fill(event.color.map(Color.init(nsColor:)) ?? Theme.textTertiary)
                    .frame(width: 5, height: 5)
                Text(event.title)
                    .font(Theme.chrome(10, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.titleWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 7)
            .padding(.trailing, event.meeting == nil ? 7 : 3)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { calendar.openInCalendar(event) }
            .clickable()
            .help("Open in Calendar")

            if let meeting = event.meeting { joinGlyph(event, meeting: meeting) }
        }
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        // One element carrying two actions rather than two elements: `children:
        // .ignore` is what stops a 5pt dot and a glyph from being read out as
        // themselves, and it hides the Join button from VoiceOver along with
        // them — so the named action below is not a nicety, it is the only
        // route to that button without a pointer.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(event))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens in Calendar")
        .accessibilityAction { calendar.openInCalendar(event) }
        .accessibilityActions {
            if let meeting = event.meeting {
                Button(meeting.buttonTitle) { calendar.join(event) }
            }
        }
    }

    /// A multi-day conference with a permanent room link used to be one click
    /// and briefly became zero: the chip row replaced a full row, and the full
    /// row was where Join lived. It comes back as a glyph rather than the timed
    /// row's labelled capsule, because the strip's height is a constant the
    /// timed rows below are laid out against — so this is sized SMALLER than the
    /// title beside it and can never be the tallest thing in the chip. A chip
    /// with a link is exactly as tall as one without.
    private func joinGlyph(_ event: CalendarEvent, meeting: MeetingLink) -> some View {
        Button { calendar.join(event) } label: {
            HStack(spacing: 0) {
                // Zero-width, invisible and load-bearing: it lends this half of
                // the capsule the TITLE's line height at whatever the text
                // setting is, so the glyph's hit area covers the chip's full
                // height while the glyph itself — 8pt against the title's 10,
                // with identical padding — can never be what decides that
                // height. Matching the metric beats guessing at a symbol's
                // bounding box, which is the way this constraint gets broken by
                // a font change nobody connected to a calendar chip.
                Text(verbatim: " ")
                    .font(Theme.chrome(10, .semibold))
                    .frame(width: 0)
                    .hidden()
                Image(systemName: "video.fill")
                    .font(Theme.chrome(8, .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.leading, 1)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .help(meeting.joinDescription)
    }

    /// Everything the chip shows and the one thing it can only imply. The glyph
    /// says "there is a call here" to anyone who can see it; `callSummary` is
    /// that same fact in words.
    private func accessibilityLabel(_ event: CalendarEvent) -> String {
        guard let meeting = event.meeting else { return "\(event.title), all day" }
        return "\(event.title), all day, \(meeting.callSummary)"
    }
}

/// The timed rows, opened on the one that matters.
///
/// Picking today used to start at the top of the day, so at 15:00 you were
/// looking at this morning's finished stand-up rather than the meeting you were
/// in. `CalendarDayAgenda.focusIndex` decides which row that is; the rows above
/// it collapse behind a count rather than being thrown away, because "what have
/// I already done today" is a real question, just not the one you asked by
/// picking today.
private struct TimedAgendaView: View {
    let events: [CalendarEvent]
    /// The picked day, or nil for the rolling agenda.
    let day: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fixed when the day opens rather than re-derived on every tick: a row
    /// vanishing from under the pointer the moment a meeting ends is worse than
    /// a slightly stale window, and reopening the day is one click.
    @State private var earlier = 0
    @State private var showsEarlier = false

    var body: some View {
        VStack(spacing: 6) {
            if earlier > 0 { earlierToggle }
            ForEach(visible) { event in
                EventRowView(event: event, day: day)
            }
        }
        .onAppear { recompute() }
        .onChange(of: day) { _, _ in
            showsEarlier = false
            recompute()
        }
        .onChange(of: events) { _, _ in recompute() }
    }

    private var visible: [CalendarEvent] {
        guard earlier > 0, !showsEarlier else { return events }
        return Array(events.dropFirst(earlier))
    }

    private var earlierToggle: some View {
        Button {
            withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
                showsEarlier.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsEarlier ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                Text(showsEarlier ? "Hide earlier" : (earlier == 1 ? "1 earlier" : "\(earlier) earlier"))
                    .font(Theme.chrome(10, .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityLabel(showsEarlier ? "Hide earlier events" : "Show \(earlier) earlier events")
    }

    private func recompute() {
        earlier = CalendarDayAgenda.focusIndex(
            in: events.map {
                CalendarDayAgenda.Event(start: $0.start, end: $0.end, isAllDay: $0.isAllDay)
            },
            day: day,
            now: Date()
        )
    }
}

private struct EventRowView: View {
    let event: CalendarEvent
    /// The day on screen, or nil for the rolling agenda. Both "is this already
    /// over" and "may this row talk about now at all" are questions about the
    /// day as much as the clock — see `CalendarDayAgenda`.
    let day: Date?
    /// True in the rolling agenda, which spans the next 24 HOURS and therefore
    /// crosses midnight. False when a day has been picked, where every row is
    /// that day by construction and the strip already says which.
    private var qualifiesDay: Bool { day == nil }
    @Environment(CalendarWidgetModel.self) private var calendar

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(event.color.map(Color.init(nsColor:)) ?? Theme.textTertiary)
                    .frame(width: 3, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(timeLine(at: context.date))
                        .font(Theme.chrome(10, .medium))
                        .foregroundStyle(isImminent(at: context.date) ? Theme.needs : Theme.textSecondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { calendar.openInCalendar(event) }
                .clickable()
                .help("Open in Calendar")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens in Calendar")
                .accessibilityAction { calendar.openInCalendar(event) }

                Spacer(minLength: 6)

                if let meeting = event.meeting {
                    Button { calendar.join(event) } label: {
                        // "Join Zoom" when we know the provider, plain "Join"
                        // when we do not — the tooltip then names the host
                        // rather than inventing a brand for it.
                        Text(meeting.buttonTitle)
                            .font(Theme.chrome(11, .bold))
                            .foregroundStyle(isImminent(at: context.date) ? Color(red: 0.1, green: 0.08, blue: 0) : Theme.textPrimary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(isImminent(at: context.date) ? Theme.needs : Color.white.opacity(0.10))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help(meeting.joinDescription)
                    .accessibilityLabel(meeting.buttonTitle)
                    .accessibilityHint(meeting.joinDescription)
                }
            }
            // Faded rather than hidden: what already happened is still useful
            // context for reading the day, just not something to act on.
            .opacity(isPast(at: context.date) ? 0.45 : 1)
        }
    }

    private func isImminent(at now: Date) -> Bool {
        !event.isAllDay
            && event.start.timeIntervalSince(now) < 10 * 60
            && now.timeIntervalSince(event.start) < 5 * 60
    }

    /// Ended already, so it is history rather than context — and only on a day
    /// the clock is running inside. Compared against `now` alone, yesterday came
    /// up entirely faded and tomorrow entirely lit; a day you picked is a whole
    /// unit and renders uniformly.
    private func isPast(at now: Date) -> Bool {
        CalendarDayAgenda.isPast(
            CalendarDayAgenda.Event(start: event.start, end: event.end, isAllDay: event.isAllDay),
            day: day, now: now
        )
    }

    private func timeLine(at now: Date) -> String {
        // Which day, when it is not this one. Without it a 09:00 tomorrow is
        // indistinguishable from a 09:00 today, and on a day with nothing of
        // its own the card reads as showing the wrong date entirely.
        let dayLabel = qualifiesDay ? EventDayLabel.label(for: event.start, relativeTo: now) : nil
        func qualified(_ text: String) -> String {
            dayLabel.map { "\($0) · \(text)" } ?? text
        }
        if event.isAllDay { return qualified("All day") }
        // Another day gets a plain span and no countdown. Every relative phrase
        // below is measured against a clock that is not running inside the day
        // on screen: yesterday's 09:00 read as "now · until 10:00", which is not
        // merely useless but false.
        guard CalendarDayAgenda.reflectsNow(day: day, now: now) else {
            return "\(Self.clock(event.start)) – \(Self.clock(event.end))"
        }
        // A finished meeting is not happening "now". This only started mattering
        // when picking a day began loading whole days, past events included —
        // before that the list was upcoming-only and start-has-passed could
        // safely mean in progress.
        if isPast(at: now) {
            return qualified("\(Self.clock(event.start)) – \(Self.clock(event.end))")
        }
        let untilStart = event.start.timeIntervalSince(now)
        if untilStart <= 0 {
            // Already running, so it is plainly today whatever the calendar
            // says — a "Tomorrow · now" would be nonsense.
            return "now · until \(Self.clock(event.end))"
        }
        if untilStart < 3600 {
            // Under an hour away cannot be another day in any useful sense, and
            // "in 40m" is more precise than a day name.
            return "in \(max(1, Int(untilStart / 60)))m · \(Self.clock(event.start))"
        }
        return qualified(Self.clock(event.start))
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
