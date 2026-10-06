import AirlockCore
import SwiftUI

/// What the agents have done to your checkouts, one row per repository.
///
/// On the agents tab rather than home, because it is meaningless without a
/// session: the whole premise is that the working directory is already known.
struct RepositorySectionView: View {
    @Environment(RepositoryWidgetModel.self) private var repository

    var body: some View {
        if !repository.repositories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(repository.repositories) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: RepositoryWidgetModel.Repository) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

            Text(entry.status.headLabel)
                .font(Theme.chrome(11.5, .medium))
                .foregroundStyle(entry.status.isDetached || entry.status.operation != nil
                                 ? Theme.needs : Theme.running)
                .lineLimit(1)

            // Clean says so rather than showing three zeroes, which read as
            // broken far more often than as tidy. The words are `GitStatus`'s,
            // shared with the session row, so the two never say it differently.
            if entry.status.isClean {
                Text("clean")
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(entry.status.facts, id: \.self) { fact in
                    counter(fact.text, tint: Self.tint(of: fact))
                }
            }

            // Only with an upstream. Without one, "0 ahead" is ahead of
            // nothing — a number that looks like information and is not.
            if entry.status.hasUpstream {
                if entry.status.ahead > 0 { counter("↑\(entry.status.ahead)", tint: Theme.done) }
                if entry.status.behind > 0 { counter("↓\(entry.status.behind)", tint: Theme.needs) }
            }

            Spacer(minLength: 4)

            Text(entry.name)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.rowStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(entry.root.path)
    }

    /// A conflict is the one fact that stops anyone; new files are the
    /// quietest.
    private static func tint(of fact: GitStatus.Fact) -> Color {
        switch fact {
        case .conflicts: Theme.danger
        case .changed: Theme.needs
        case .new: Theme.textTertiary
        }
    }

    private func counter(_ text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(text)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }
}
