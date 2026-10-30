import SwiftUI
import AirlockCore

/// The day-one home card: what the notch is listening for, and the one thing a
/// new user cannot deduce.
///
/// Not onboarding copy. Every row prints a **live binding** read from the model
/// that owns it, so the card is as true on day 400 as on day one — which is why
/// it is a `NotchWidget` rather than a first-run screen, and why it yields to
/// anything with actual state (`NotchWidget.isFallback`).
///
/// Each row can be closed, and a closed row never comes back (`KeyMapTips`,
/// the owner's call 2026-10-28): true or not, three tips on Home for good
/// were three too many. With every row closed the card is gone.
///
/// The rule that keeps it honest: a row appears only while its gesture would
/// actually fire. Printing "⌃ Hold to dictate anywhere" while dictation is
/// switched off is the same mistake as printing "⌘Y" on a panel that does not
/// hold the keyboard — see `PermissionCardView.showsShortcuts`.
struct KeyMapSectionView: View {
    @Environment(DictationModel.self) private var dictation
    @Environment(ClipboardWidgetModel.self) private var clipboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tips = KeyMapTips.shared

    // The "Airlock is watching" card that stood above the keys is gone
    // (2026-10-01). It told developers to start `claude` in a terminal, under
    // the recess-and-light mark the cloud replaced a month earlier, and the
    // owner, seeing it, asked what it was. The Agents tab says the same thing
    // where it belongs.
    var body: some View {
        // The hold key is watched by an event tap, so without Input Monitoring
        // the row's gesture never fires — dictation switched on is not enough.
        let watches = dictation.isEnabled && dictation.readiness.canWatchHoldKey
        let rows = Self.rows(
            dictation: watches ? dictation.holdKey.glyph : nil,
            clipboardKey: clipboard.isEnabled && clipboard.hotkeyEnabled ? clipboard.hotkey.displayName : nil)
            .filter { !tips.isClosed($0.id) }
        if !rows.isEmpty {
            KeyMapCard(rows: rows) { id in
                withAnimation(Motion.close.animation(reduceMotion: reduceMotion)) { tips.close(id) }
            }
        }
    }

    // MARK: - Rows

    /// Built from the live models, so a row is present exactly when its gesture
    /// is. Dictation ships off, which is why the first is conditional
    /// rather than decorative. Values in, so the state gallery draws the same
    /// rows from made-up settings.
    ///
    /// - Parameters:
    ///   - dictation: the hold key's glyph while dictation is on; nil while
    ///     it is off.
    ///   - clipboardKey: the clipboard's shortcut while it has one, else nil.
    static func rows(dictation: String?, clipboardKey: String?) -> [KeyMapRow] {
        var rows: [KeyMapRow] = []
        if let dictation {
            rows.append(KeyMapRow(id: "dictate", symbol: "mic.fill",
                                  title: String(localized: "Hold to dictate anywhere"),
                                  trailing: .cap(dictation)))
        }
        if let clipboardKey {
            rows.append(KeyMapRow(id: "clipboard", symbol: "list.clipboard",
                                  title: String(localized: "Everything you copy"),
                                  trailing: .cap(clipboardKey)))
        }
        // No switch and no binding — the drop target is the notch itself, and it
        // is the one row that is true on every install.
        rows.append(KeyMapRow(id: "tray", symbol: "tray",
                              title: String(localized: "Drop a file on the notch to shelve it"),
                              trailing: .hint(String(localized: "Try it"))))
        return rows
    }
}

/// One line of the shortcut map.
struct KeyMapRow: Identifiable {
    enum Trailing {
        case cap(String)
        case hint(String)
    }
    let id: String
    let symbol: String
    let title: String
    let trailing: Trailing
}

/// The keys card itself, from rows. Values in, so a snapshot draws exactly this.
struct KeyMapCard: View {
    let rows: [KeyMapRow]
    /// Closes a row for good. Nil draws no close buttons (the state gallery).
    var onClose: ((String) -> Void)? = nil

    var body: some View { keysCard }

    private var keysCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                }
                keyRow(row)
            }
        }
        .background(card)
    }

    private func keyRow(_ row: KeyMapRow) -> some View {
        HStack(spacing: 9) {
            Image(systemName: row.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
            // Two lines, not one: in the half-width column beside Sound the
            // Shelf row was cut to "…to shel…". The row grows instead.
            Text(row.title)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            switch row.trailing {
            case .cap(let key):
                Text(key)
                    // Monospaced so ⌘⇧V and ⌃ share a width per glyph and the
                    // caps down the column read as one set of keys.
                    .font(.system(size: 10 * Theme.textScale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
            case .hint(let text):
                Text(text)
                    .font(Theme.label)
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
            }
            if let onClose {
                Button { onClose(row.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Don't show this again"))
                .accessibilityLabel(String(localized: "Don't show this again"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.rowFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.rowStroke, lineWidth: 1)
            )
    }
}
