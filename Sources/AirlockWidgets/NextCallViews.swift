import AirlockCore
import SwiftUI
import WidgetKit

/// The "Next call" widget's two sizes, drawn from a snapshot, a moment and a
/// look, like `CallTodosView`, so the screenshots can draw every state.
struct NextCallView: View {
    enum Size { case small, medium }

    var next: DeskNextCall
    var now: Date
    var size: Size
    var look: DeskLook
    /// False only for the screenshots: an image cannot draw a link.
    var live = true

    var body: some View {
        Group {
            switch size {
            case .small: small
            case .medium: medium
            }
        }
        .foregroundStyle(look.fg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var moment: DeskNextCall.Moment { next.moment(at: now) }

    // MARK: Small

    @ViewBuilder private var small: some View {
        switch moment {
        case .now(let event, _), .next(let event, _):
            VStack(alignment: .leading, spacing: 0) {
                header(isOn: isOn)
                when(event).padding(.top, 6)
                Spacer(minLength: 4)
                Text(event.title).font(DeskType.text(13.5, weight: .semibold)).lineLimit(2)
                times(event).padding(.top, 2)
                if event.joinURL != nil {
                    join(event, wide: true).padding(.top, 8)
                }
            }
        case .clear:
            VStack(alignment: .leading, spacing: 6) {
                header(isOn: false)
                Spacer(minLength: 0)
                clear(title: 15)
                if let notes = next.notes { notesRow(notes).padding(.top, 4) }
            }
        }
    }

    // MARK: Medium

    @ViewBuilder private var medium: some View {
        switch moment {
        case .now(let event, let then), .next(let event, let then):
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    header(isOn: isOn)
                    when(event).padding(.top, 6)
                    Spacer(minLength: 4)
                    Text(event.title).font(DeskType.text(14, weight: .semibold)).lineLimit(2)
                    times(event).padding(.top, 2)
                    if event.joinURL != nil {
                        join(event, wide: false).padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    if let then {
                        Text(DeskCallWords.then).font(DeskType.text(11, weight: .semibold))
                            .foregroundStyle(look.fg2)
                            .textCase(.uppercase)
                        Text(then.title).font(DeskType.text(13)).lineLimit(2).padding(.top, 4)
                        times(then).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    if let notes = next.notes { notesRow(notes) }
                }
                .frame(width: 128, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        case .clear:
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    header(isOn: false)
                    Spacer(minLength: 0)
                    clear(title: 17)
                }
                Spacer(minLength: 0)
                if let notes = next.notes { notesRow(notes).frame(width: 128, alignment: .leading) }
            }
        }
    }

    // MARK: Pieces

    private var isOn: Bool { if case .now = moment { true } else { false } }

    private func header(isOn: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "video.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(look.accent)
                .widgetAccentable()
            Text(isOn ? DeskCallWords.now : DeskCallWords.next)
                .font(DeskType.title(14))
                .foregroundStyle(isOn ? look.accent : look.fg)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// "in 12 min" before it starts, "ends 11:00" while it is on. The
    /// timeline has an entry each minute of the last hour, so it counts.
    @ViewBuilder private func when(_ event: DeskNextCall.Event) -> some View {
        if event.start <= now {
            Text(DeskCallWords.ends(event.end.formatted(.dateTime.hour().minute())))
                .font(DeskType.mono(15, weight: .medium))
                .foregroundStyle(look.fg2)
        } else if !Calendar.current.isDate(event.start, inSameDayAs: now) {
            Text(DeskCallWords.tomorrow)
                .font(DeskType.mono(22, weight: .medium))
                .tracking(-0.6)
        } else {
            Text(DeskCallWords.startsIn(event.start.timeIntervalSince(now)))
                .font(DeskType.mono(22, weight: .medium))
                .tracking(-0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func times(_ event: DeskNextCall.Event) -> some View {
        Text(event.start.formatted(.dateTime.hour().minute()) + " – "
             + event.end.formatted(.dateTime.hour().minute()))
            .font(DeskType.mono(11))
            .foregroundStyle(look.fg2)
            .lineLimit(1)
    }

    @ViewBuilder private func join(_ event: DeskNextCall.Event, wide: Bool) -> some View {
        if let url = event.joinURL {
            linked(url) {
                Text(event.join ?? DeskCallWords.join)
                    .font(DeskType.text(12.5, weight: .semibold))
                    .foregroundStyle(look.pillText)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .frame(height: 28)
                    .background(look.pill, in: Capsule())
            }
            .widgetAccentable()
        }
    }

    private func clear(title: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DeskCallWords.clearTitle).font(DeskType.title(title))
            Text(DeskCallWords.clearLine)
                .font(DeskType.text(12, weight: .regular))
                .foregroundStyle(look.fg2)
                .lineLimit(2)
        }
    }

    /// "Notes ready · Design review": opens that call's notes.
    @ViewBuilder private func notesRow(_ notes: DeskNextCall.Notes) -> some View {
        if let url = notes.openURL {
            linked(url) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(look.accent)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(DeskCallWords.notesReady).font(DeskType.text(11.5, weight: .semibold))
                        Text(notes.call).font(DeskType.text(11, weight: .regular))
                            .foregroundStyle(look.fg2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(look.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    @ViewBuilder private func linked(_ url: URL, @ViewBuilder _ label: () -> some View) -> some View {
        if live { Link(destination: url, label: label) } else { label() }
    }
}
