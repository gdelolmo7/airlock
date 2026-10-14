import SwiftUI
import AirlockCore

/// The diagnostics report, read rather than pasted.
///
/// **7c and 7d compose rather than compete.** The paste is the better artefact
/// for support — it is one string somebody can attach to an issue — and this is
/// the better surface for the user, because it names its own next step. The
/// banner at the top of the paste is what brings you here; this is where the fix
/// is.
///
/// The design decision worth keeping is the three-state dot. Green for a fact,
/// amber for a fault, **hollow for an honest unknown** — and only amber rows
/// lead anywhere, because a row with nothing wrong has nowhere to send anybody.
/// See `DiagnosticsHealth`.
struct DiagnosticsHealthView: View {
    let health: DiagnosticsHealth
    let summary: String
    var onCopy: () -> Void
    var onOpen: (DiagnosticsHealth.Remedy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if health.isHealthy { healthyHeader } else { faultHeader }

            VStack(spacing: 0) {
                ForEach(Array(health.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(SettingsLook.rowStroke).frame(height: 1) }
                    self.row(row)
                }
            }

            HStack(spacing: 8) {
                Text(summary)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                // Available even when nothing is wrong: a bug report from a
                // healthy install is still a bug report, and "it all looks fine
                // to me" is exactly the thing worth attaching.
                LookButton(health.isHealthy ? "Copy anyway" : "Copy the report", action: onCopy)
            }
        }
    }

    /// The state this pane spends most of its life in.
    ///
    /// A health page that looks eventful when everything is fine trains people
    /// to ignore it, so the boring case is drawn as boring — one green line and
    /// a sentence, not a dashboard.
    private var healthyHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Nothing to report", systemImage: "checkmark.circle.fill")
                .font(Theme.chrome(12.5, .semibold))
                .foregroundStyle(SettingsLook.on)
            Text(health.healthySummary)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var faultHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(health.faults.count == 1 ? "One thing needs attention"
                  : "\(health.faults.count) things need attention",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Theme.chrome(12.5, .semibold))
                .foregroundStyle(Theme.needs)
            Text("Everything else checked out.")
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func row(_ row: DiagnosticsHealth.Row) -> some View {
        let content = HStack(spacing: 9) {
            dot(row.severity)
            Text(row.title)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(row.detail)
                .font(Theme.chrome(11.5))
                .foregroundStyle(row.severity == .fault ? Theme.needs : Theme.textSecondary)
                .multilineTextAlignment(.trailing)
            if row.remedy != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())

        // Only amber rows are tappable. Making every row a button would promise
        // a destination for "Microphone: allowed", which has none.
        if let remedy = row.remedy {
            Button { onOpen(remedy) } label: { content }
                .buttonStyle(.plain)
                .help("Opens where this is fixed")
        } else {
            content
        }
    }

    private func dot(_ severity: DiagnosticsHealth.Severity) -> some View {
        Group {
            switch severity {
            case .fact:
                Circle().fill(SettingsLook.on)
            case .fault:
                Circle().fill(Theme.needs)
            case .unknown:
                // Hollow, deliberately. A filled grey dot reads as a fourth
                // state nobody defined; an outline reads as "no answer", which
                // is exactly what it is.
                Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.2)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}
