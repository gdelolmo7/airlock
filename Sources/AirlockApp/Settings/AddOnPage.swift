import AppKit
import AirlockCore
import SwiftUI

/// An add-on's own page in Settings: the header carries the add-on's big
/// switch, and under it come the add-on's settings, or, while it is off, one
/// card that says what it would add and switches it on.
///
/// There is no page of all the add-ons any more: each one is a row in the
/// sidebar, with a dot that says whether it is on, and this page is where it
/// is switched. Every switch goes through `AddOnSwitches`, the path the
/// model's own setting uses, so switching an add-on off here stops it exactly
/// as it always stopped.
///
/// Something that needs macOS's permission asks first: the switch moves, a
/// card says what macOS will be asked and why, and nothing is switched on
/// until the person says go. Off is always immediate.
struct AddOnPage<Rows: View, More: View>: View {
    let addOn: AddOn
    let subtitle: String
    var learnMore: [FeaturePage] = []
    @Binding var moreOptions: Bool
    var anchorsInMoreOptions: Set<SettingsAnchor> = []
    /// Off for a page that lists its own permissions (Dictation), so the
    /// missing one is not said twice.
    var showsMissing = true
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var more: () -> More

    @Environment(TrayModel.self) private var tray: TrayModel?
    @Environment(ClipboardWidgetModel.self) private var clipboard: ClipboardWidgetModel?
    @Environment(AgentsWidgetModel.self) private var agents: AgentsWidgetModel?
    @Environment(DictationModel.self) private var dictation: DictationModel?
    @Environment(CalendarWidgetModel.self) private var calendar: CalendarWidgetModel?
    /// Fixed values for the state gallery, which draws without real switches.
    @Environment(\.addOnPreview) private var preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Meeting notes has no observable model to read: its switch is this key,
    /// which the notes model watches. Reading it here is what redraws the
    /// page when it changes.
    @AppStorage(MeetingNotesModel.enabledKey) private var meetingNotesOn = MeetingNotesModel.onByDefault
    /// Permissions change in System Settings, outside this process, with no
    /// notification worth observing: bumped to read them again.
    @State private var refreshTick = 0
    /// Switched on, waiting for the go-ahead to ask macOS.
    @State private var confirming = false

    init(_ addOn: AddOn, subtitle: String, learnMore: [FeaturePage] = [], moreOptions: Binding<Bool>,
         anchorsInMoreOptions: Set<SettingsAnchor> = [], showsMissing: Bool = true,
         @ViewBuilder rows: @escaping () -> Rows, @ViewBuilder more: @escaping () -> More) {
        self.addOn = addOn
        self.subtitle = subtitle
        self.learnMore = learnMore
        _moreOptions = moreOptions
        self.anchorsInMoreOptions = anchorsInMoreOptions
        self.showsMissing = showsMissing
        self.rows = rows
        self.more = more
    }

    private var switches: AddOnSwitches? {
        guard let tray, let clipboard, let agents, let dictation else { return nil }
        return AddOnSwitches(tray: tray, clipboard: clipboard, agents: agents, dictation: dictation)
    }

    private var isOn: Bool {
        if let preview { return preview.isOn }
        if addOn == .meetingNotes { return meetingNotesOn }
        return switches?.isOn(addOn) ?? true
    }

    private var isConfirming: Bool { preview?.confirming ?? confirming }

    private var check: AddOnAccessCheck {
        if let preview { return AddOnAccessCheck.check(addOn) { preview.missing.contains($0) ? .notAllowed : .allowed } }
        guard let dictation, let calendar else { return AddOnAccessCheck.check(addOn) { _ in .allowed } }
        return AddOnAccessCheck.check(addOn, state: AddOnAccess.state(PermissionFacts.read(dictation: dictation, calendar: calendar)))
    }

    var body: some View {
        // Read in the body so a bump redraws what is missing.
        let _ = refreshTick
        let on = isOn
        let check = check
        LookPage(addOn.pane.title, subtitle: subtitle, learnMore: learnMore,
                 moreOptions: $moreOptions, anchorsInMoreOptions: anchorsInMoreOptions) {
            if isConfirming {
                AddOnAsksCard(addOn: addOn, confirm: confirm, cancel: { confirming = false })
                    .lookStandalone()
            } else if !on {
                AddOnOffCard(addOn: addOn, switchOn: { setSwitch(true) })
                    .lookStandalone()
            } else {
                if showsMissing, let sentence = check.sentence(for: addOn) {
                    AddOnMissingRow(sentence: sentence, button: check.buttonTitle, fix: { fix(check) })
                        .lookStandalone()
                }
                rows()
            }
        } more: {
            more()
        } accessory: {
            AddOnBigSwitch(name: addOn.displayName, isOn: on || isConfirming, set: setSwitch)
        }
        .hidingMore(!on || isConfirming)
        // Notices a switch flipped in System Settings while this page is
        // beside it, as the Permissions page does.
        .watchingPermissions { _ in
            refreshTick += 1
            calendar?.recheckAuthorization()
            dictation?.recheckHoldKey()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTick += 1
            // A tap narrowed under an old refusal stays narrowed until it is
            // rebuilt, so Input Monitoring needs more than a read.
            dictation?.recheckHoldKey()
        }
        .onChange(of: addOn) { confirming = false }
    }

    /// Nothing to ask: on at once. Something to ask: the card says what macOS
    /// will be asked first. Off is always immediate.
    private func setSwitch(_ on: Bool) {
        guard preview == nil else { return }
        if on {
            if addOn.needs.isEmpty { flip(true) } else { confirming = true }
        } else if confirming {
            confirming = false
        } else {
            flip(false)
        }
    }

    private func confirm() {
        confirming = false
        flip(true)
        // Just switched on, and it needs something: ask macOS now, one
        // question at a time. A no keeps it on; the page then says what is
        // missing.
        guard let dictation, let calendar else { return }
        Task {
            await AddOnAccess.askOnAdd(addOn, dictation: dictation, calendar: calendar)
            refreshTick += 1
        }
    }

    private func flip(_ on: Bool) {
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
            switches?.set(addOn, on: on)
            if addOn == .meetingNotes { meetingNotesOn = on }
        }
    }

    /// The button for what is missing. Read the page again once macOS has
    /// answered: without that the row kept its old sentence and the button
    /// looked as if it had done nothing.
    private func fix(_ check: AddOnAccessCheck) {
        guard let dictation else { return }
        Task {
            await AddOnAccess.fix(check, dictation: dictation)
            refreshTick += 1
            // Answers given in a system dialog that returns before it is
            // answered (Input Monitoring, Accessibility) land a moment later.
            try? await Task.sleep(for: .seconds(1))
            refreshTick += 1
        }
    }
}

extension AddOnPage where More == EmptyView {
    /// A page with nothing behind "More options".
    init(_ addOn: AddOn, subtitle: String, learnMore: [FeaturePage] = [], showsMissing: Bool = true,
         @ViewBuilder rows: @escaping () -> Rows) {
        self.init(addOn, subtitle: subtitle, learnMore: learnMore, moreOptions: .constant(false),
                  showsMissing: showsMissing, rows: rows, more: { EmptyView() })
    }
}

/// What the state gallery draws an add-on page as: on or off, waiting on the
/// permission card, and what macOS hasn't allowed.
struct AddOnPreview: Equatable {
    var isOn = true
    var confirming = false
    var missing: Set<MacAccess> = []
}

extension EnvironmentValues {
    @Entry var addOnPreview: AddOnPreview?
    @Entry var lookHidesMore = false
}

private extension View {
    func hidingMore(_ hides: Bool) -> some View { environment(\.lookHidesMore, hides) }
}

// MARK: - The pieces

/// "On" or "Off" and the big switch, beside the page's title.
private struct AddOnBigSwitch: View {
    let name: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(isOn ? "On" : "Off")
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(isOn ? Theme.textPrimary : Theme.textTertiary)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { isOn }, set: set)) { Text(name) }
                .toggleStyle(LookSwitchStyle(large: true))
                .labelsHidden()
        }
    }
}

/// The page of an add-on that is off: what it adds, where it shows up, what
/// macOS will be asked, and the button that switches it on.
private struct AddOnOffCard: View {
    let addOn: AddOn
    let switchOn: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            LookTile(symbol: addOn.symbol, tint: addOn.tint, size: 40, dimmed: true)
            Text("Switched off")
                .font(Theme.chrome(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(addOn.summary)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 1) {
                Text(addOn.notchPlace)
                Text(addOn.asks)
                if let badge = addOn.planBadge {
                    Text(badge).foregroundStyle(PlanTag.text(.plus))
                }
            }
            .font(Theme.chrome(11))
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            LookButton("Switch on", prominent: true, action: switchOn)
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// The permission card: which permissions, why, and that a no is fine.
private struct AddOnAsksCard: View {
    let addOn: AddOn
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Needs \(addOn.needs.map(\.name).formatted(.list(type: .and)))")
                .font(Theme.chrome(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let why = addOn.needsBecause {
                Text(why)
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("macOS asks next. If you say no, it stays on and you can allow it later.")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                LookButton("Allow", prominent: true, action: confirm)
                LookButton("Cancel", action: cancel)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(LookTint.bright(addOn.tint).opacity(0.6), lineWidth: 1))
    }
}

/// On, and macOS hasn't allowed all of it yet: what is missing, and the one
/// button that gets it.
private struct AddOnMissingRow: View {
    let sentence: String
    let button: String?
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.needs)
                .accessibilityHidden(true)
            Text(sentence)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.needs)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let button { LookButton(button, prominent: true, action: fix) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.needs.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.needs.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - What each add-on looks like here

extension AddOn {
    /// Where "Options" goes: a row to scroll to and light up, or a whole page
    /// when the add-on has one of its own.
    enum OptionsTarget: Equatable {
        case row(SettingsAnchor)
        case page(SettingsPane)
    }

    /// Each add-on has a page of its own now, so this is always that page;
    /// kept for the notch's "+" and anything that links to an add-on.
    var options: OptionsTarget { .page(pane) }

    /// The same symbols the Settings sidebar and the notch tabs use for these,
    /// so a page looks like the place it adds.
    var symbol: String {
        switch self {
        case .shelf: return "tray.full"
        case .clipboard: return "list.clipboard"
        case .meetingNotes: return "mic"
        case .codingAgents: return "sparkle"
        case .windowLayouts: return "rectangle.split.2x1"
        case .dictation: return "waveform"
        }
    }

    var tint: Color {
        switch self {
        case .shelf: return Self.rgb(0xA1, 0x62, 0x07)
        case .clipboard: return Self.rgb(0x0E, 0x74, 0x90)
        case .meetingNotes: return Self.rgb(0xBE, 0x12, 0x3C)
        case .codingAgents: return Self.rgb(0xC2, 0x41, 0x0C)
        case .windowLayouts: return Self.rgb(0x1F, 0x6F, 0x5A)
        case .dictation: return Self.rgb(0x7C, 0x3A, 0xED)
        }
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(nsColor: NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
    }
}
