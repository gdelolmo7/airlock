import AppKit
import AirlockCore
import SwiftUI

/// "What each plan writes": the same made-up call, written by Free, Plus
/// and Pro (`NotesComparisonSample`). Opened by "See what Plus writes"
/// beside notes the Mac wrote, on a Mac that can't write notes, and from
/// Settings › Plans.
///
/// What it shows was written once, by each plan's own model, and ships with
/// the app: opening it asks nothing of the network or of the Mac's model,
/// and none of the person's own calls is in it.
@MainActor
final class NotesComparisonWindowController {
    static let shared = NotesComparisonWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<NotesComparisonView>?
    private var showPlans: @MainActor () -> Void = {}

    /// `plan` is the one this Mac is on: its tile says "Yours", the page
    /// opens on the plan above it, and the foot offers only what is above it.
    func show(plan: AirlockPlan, showPlans: @escaping @MainActor () -> Void) {
        self.showPlans = showPlans
        let view = NotesComparisonView(plan: plan,
                                       close: { [weak self] in self?.window?.close() },
                                       showPlans: { [weak self] in self?.showPlans() })
        if let hosting {
            // Opened again, perhaps on another plan: start from its pick.
            hosting.rootView = view
        } else {
            let (window, hosting) = Self.makeWindow(view)
            window.centerOnNotchScreen()
            self.window = window
            self.hosting = hosting
        }
        if let window { DockPresenceController.shared.willShow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window `show` puts up, sized and laid out, not yet on screen.
    static func makeWindow(_ view: NotesComparisonView) -> (NSWindow, NSHostingController<NotesComparisonView>) {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "What each plan writes")
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(SettingsLook.ground)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(NotesComparisonView.size)
        hosting.view.layoutSubtreeIfNeeded()
        return (window, hosting)
    }
}

/// Three plan tiles across the top, each saying where its notes are written,
/// how much of the call they heard, how many to-dos they found and whether
/// they told the voices apart; under
/// them, the notes of the one picked, as one readable page. The foot offers
/// only plans above the one this Mac is on.
struct NotesComparisonView: View {
    static let size = NSSize(width: 840, height: 800)

    let plan: AirlockPlan
    let close: @MainActor () -> Void
    let showPlans: @MainActor () -> Void
    @State private var picked: AirlockPlan

    /// `picked` is the state gallery's; the window opens on the plan above
    /// the one this Mac is on, or on Pro for Pro.
    init(plan: AirlockPlan, picked: AirlockPlan? = nil,
         close: @escaping @MainActor () -> Void, showPlans: @escaping @MainActor () -> Void) {
        self.plan = plan
        self.close = close
        self.showPlans = showPlans
        _picked = State(initialValue: picked ?? (plan == .free ? .plus : .pro))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 34)
            HStack(alignment: .top, spacing: 10) {
                ForEach(AirlockPlan.allCases, id: \.self) { tile in
                    NotesComparisonTile(plan: tile, picked: picked == tile, yours: plan == tile) {
                        picked = tile
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.top, 18)
            ScrollView {
                NotesComparisonPage(plan: picked)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
            }
            .scrollIndicators(.automatic)
            .id(picked)
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
            foot
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(SettingsLook.ground)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What each plan writes")
                    .font(Theme.chrome(19, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("The same \(NotesComparisonSample.minutes)-minute call, written by each plan. Pick one to read its notes. An example call, not one of yours.")
                    .font(Theme.chrome(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button(action: close) {
                Label("Close", systemImage: "xmark")
                    .font(Theme.chrome(12.5, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .clickable()
        }
    }

    /// Where the notes are written, and only the plans above this Mac's.
    private var foot: some View {
        HStack(spacing: 10) {
            Text("Free notes are written on your Mac and never leave it. Plus and Pro write them online, and no audio is kept.")
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if plan == .free {
                CallNotesOfferButton("Get Plus", tone: .plus, action: showPlans)
            }
            if plan != .pro {
                CallNotesOfferButton("Get Pro", tone: .pro, action: showPlans)
            }
        }
    }
}

/// One plan, as a tile to pick: its name and tag, where its notes are
/// written and by what, how much of the call they heard, how many to-dos
/// they found, and whether each voice was told apart. The picked one takes
/// its plan's colour.
private struct NotesComparisonTile: View {
    let plan: AirlockPlan
    let picked: Bool
    let yours: Bool
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let tint = PlanTag.tint(plan)
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text(plan.label)
                        .font(Theme.chrome(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if plan != .free { PlanTag(plan) }
                    Spacer(minLength: 4)
                    if yours {
                        Text("Yours")
                            .font(Theme.chrome(10.5, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                fact(written, symbol: plan == .free ? "laptopcomputer" : "cloud")
                    .padding(.top, 10)
                fact(heard, symbol: "waveform")
                    .padding(.top, 5)
                fact(String(localized: "\(NotesComparisonSample.todos(plan)) to-dos found"), symbol: "checklist")
                    .padding(.top, 5)
                fact(voices, symbol: "person.2")
                    .padding(.top, 5)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(picked
                ? AnyShapeStyle(RadialGradient(colors: [tint.opacity(plan == .pro ? 0.16 : 0.20),
                                                        tint.opacity(0.03)],
                                               center: .topLeading, startRadius: 0, endRadius: 260))
                : AnyShapeStyle(Color.white.opacity(hovered ? 0.05 : 0.025))))
            .overlay(shape.strokeBorder(picked ? tint.opacity(plan == .free ? 0.5 : 0.45)
                                               : Color.white.opacity(0.08),
                                        lineWidth: picked ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint("Shows \(plan.label)'s notes of the example call")
    }

    private func fact(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(picked ? PlanTag.text(plan) : Theme.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.chrome(12))
                .foregroundStyle(picked ? Theme.textPrimary.opacity(0.9) : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var written: String {
        switch plan {
        case .free: String(localized: "On your Mac, basic model")
        case .plus: String(localized: "Online, a better model")
        case .pro: String(localized: "Online, the best model")
        }
    }

    private var heard: String {
        plan == .free
            ? String(localized: "First \(Int(NotesComparisonSample.freeListened / 60)) of \(NotesComparisonSample.minutes) minutes")
            : String(localized: "The whole call")
    }

    /// Who said what: `PlanLimits.tellsVoicesApart`, said as the transcript
    /// shows it.
    private var voices: String {
        PlanSnapshot(plan: plan, isPaid: plan != .free).limits.tellsVoicesApart
            ? String(localized: "Each voice told apart")
            : String(localized: "Everyone else is \u{201C}Them\u{201D}")
    }
}

/// The picked plan's notes, as the notes window draws them, with Free's
/// missing minutes said first.
private struct NotesComparisonPage: View {
    let plan: AirlockPlan

    var body: some View {
        let people = CallPeople.people(of: NotesComparisonSample.record)
        VStack(alignment: .leading, spacing: 12) {
            if plan == .free {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Free's notes stopped at \(Int(NotesComparisonSample.freeListened / 60)) minutes: the last \(NotesComparisonSample.freeLeavesOut) aren't in them.")
                        .font(Theme.chrome(12.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.needs)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.needs.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.needs.opacity(0.32), lineWidth: 1))
            }
            ForEach(Array(MeetingPage.cards(NotesComparisonSample.sections(plan)).enumerated()), id: \.offset) { _, card in
                switch card {
                case .section(let section):
                    CallNotesCard(call: nil, section: section, people: people)
                case .topics(let head, let topics):
                    CallNotesTopics(call: nil, head: head, topics: topics)
                }
            }
        }
    }
}
