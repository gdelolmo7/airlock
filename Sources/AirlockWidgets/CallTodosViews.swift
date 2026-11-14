import AirlockCore
import AppIntents
import SwiftUI
import WidgetKit

/// The widget's three sizes, drawn from a snapshot and a look. The look is
/// passed in rather than read here, so the same views draw the screenshots
/// for every look on one run (`DeskShots`).
struct CallTodosView: View {
    enum Size { case small, medium, large }

    var todos: DeskTodos
    var size: Size
    var look: DeskLook

    var body: some View {
        Group {
            if todos.allDone {
                done
            } else if todos.items.isEmpty {
                nothing
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .foregroundStyle(look.fg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(DeskWords.small, size: 14, trailing: nil)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(todos.left)")
                    .font(DeskType.mono(42, weight: .medium))
                    .tracking(-1.7)
                Text(DeskWords.leftFromToday)
                    .font(DeskType.text(12.5, weight: .regular))
                    .foregroundStyle(look.fg2)
                    .lineLimit(2)
            }
            .padding(.top, 4)
            Spacer(minLength: 6)
            if let first = todos.openFirst.first {
                HStack(alignment: .top, spacing: 8) {
                    tick(first, size: 22, check: 11)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.text)
                            .font(DeskType.text(12.5))
                            .lineLimit(2)
                        Text(first.call)
                            .font(DeskType.text(11, weight: .regular))
                            .foregroundStyle(look.fg2)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(DeskWords.medium, size: 14, trailing: DeskWords.left(todos.left))
                .padding(.bottom, 4)
            ForEach(todos.openFirst.prefix(3)) { item in
                HStack(spacing: 8) {
                    tick(item, size: 22, check: 11)
                    Text(item.text)
                        .font(DeskType.text(13))
                        .foregroundStyle(item.done ? look.fg2 : look.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(item.call)
                        .font(DeskType.text(11, weight: .regular))
                        .foregroundStyle(look.fg2)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                .frame(height: 30)
            }
        }
    }

    // MARK: Large

    /// Five fit at 380 points: the design's "no extra large" is this.
    static let largeRows = 5

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(DeskWords.large, size: 18,
                   trailing: DeskWords.doneOf(todos.ticked, todos.items.count))
            progress.padding(.top, 12).padding(.bottom, 6)
            ForEach(rowsForLarge) { item in
                VStack(spacing: 0) {
                    Rectangle().fill(look.well).frame(height: 1)
                    HStack(alignment: .center, spacing: 10) {
                        tick(item, size: 24, check: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                                .font(DeskType.text(13.5))
                                .foregroundStyle(item.done ? look.fg2 : look.fg)
                                .lineLimit(1)
                            (Text(item.call + " · ") + Text(item.at, format: .dateTime.hour().minute())
                                .font(DeskType.mono(11)))
                                .font(DeskType.text(11, weight: .regular))
                                .foregroundStyle(look.fg2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                }
            }
        }
    }

    /// The day's to-dos in their order, done ones kept where they were; when
    /// there are more than fit, the open ones are the ones kept.
    private var rowsForLarge: [DeskTodos.Item] {
        guard todos.items.count > Self.largeRows else { return todos.items }
        let keep = Set(todos.openFirst.prefix(Self.largeRows).map(\.id))
        return todos.items.filter { keep.contains($0.id) }
    }

    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(look.well)
                Capsule().fill(look.accent)
                    .frame(width: geo.size.width * CGFloat(todos.ticked) / CGFloat(max(1, todos.items.count)))
                    .widgetAccentable()
            }
        }
        .frame(height: 6)
    }

    // MARK: All done, and nothing yet

    @ViewBuilder private var done: some View {
        let things = todos.items.count
        switch size {
        case .small:
            VStack(spacing: 6) {
                Bloub(look: look, width: 64)
                Text(DeskWords.allDone).font(DeskType.title(18))
                Text(DeskWords.tickedToday(todos.ticked, things))
                    .font(DeskType.text(11.5, weight: .regular))
                    .foregroundStyle(look.fg2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .medium:
            HStack(spacing: 16) {
                Bloub(look: look, width: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DeskWords.allDone).font(DeskType.title(24))
                    Text(DeskWords.allTicked(things, calls: todos.calls))
                        .font(DeskType.text(13, weight: .regular))
                        .foregroundStyle(look.fg2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        case .large:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Bloub(look: look, width: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DeskWords.allDone).font(DeskType.title(18))
                        Text(DeskWords.things(things, calls: todos.calls))
                            .font(DeskType.text(12, weight: .regular))
                            .foregroundStyle(look.fg2)
                    }
                }
                .padding(.bottom, 12)
                ForEach(rowsForLarge) { item in
                    VStack(spacing: 0) {
                        Rectangle().fill(look.well).frame(height: 1)
                        HStack(spacing: 10) {
                            tick(item, size: 24, check: 12)
                            Text(item.text).font(DeskType.text(13.5)).foregroundStyle(look.fg2).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(size == .small ? DeskWords.small : (size == .medium ? DeskWords.medium : DeskWords.large),
                   size: size == .large ? 18 : 14, trailing: nil)
            Spacer(minLength: 0)
            Text(DeskWords.nothingTitle).font(DeskType.title(size == .small ? 15 : 17))
            Text(DeskWords.nothingLine)
                .font(DeskType.text(12, weight: .regular))
                .foregroundStyle(look.fg2)
                .lineLimit(3)
            if size == .large { Spacer(minLength: 0) }
        }
    }

    // MARK: Pieces

    private func header(_ title: String, size: CGFloat, trailing: String?) -> some View {
        HStack(spacing: 6) {
            TodoMark(color: look.accent, size: size)
            Text(title).font(DeskType.title(size)).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(DeskType.mono(12)).foregroundStyle(look.fg2).lineLimit(1)
            }
        }
    }

    /// The circle, as a button that ticks the to-do (or unticks it) without
    /// opening Airlock. The rest of the widget opens the calls window.
    private func tick(_ item: DeskTodos.Item, size: CGFloat, check: CGFloat) -> some View {
        Button(intent: TickTodoIntent(item, done: !item.done)) {
            TodoCircle(done: item.done, look: look, size: size, checkSize: check)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.done ? DeskWords.untick : DeskWords.tick)
    }
}
