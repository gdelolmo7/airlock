import AppKit
import AirlockCore
import SwiftUI

/// "What each plan writes": the same made-up call, written by Free, Plus
/// and Pro, side by side (`NotesComparisonSample`). Opened by "See what Plus
/// writes" beside notes the Mac wrote, and on a Mac that can't write notes.
///
/// What it shows was written once, by each plan's own model, and ships with
/// the app: opening it asks nothing of the network or of the Mac's model,
/// and none of the person's own calls is in it.
@MainActor
final class NotesComparisonWindowController {
    static let shared = NotesComparisonWindowController()

    private var window: NSWindow?
    private var showPlans: @MainActor () -> Void = {}

    func show(showPlans: @escaping @MainActor () -> Void) {
        self.showPlans = showPlans
        if window == nil {
            let window = Self.makeWindow(close: { [weak self] in self?.window?.close() },
                                         showPlans: { [weak self] in self?.showPlans() })
            window.centerOnNotchScreen()
            self.window = window
        }
        if let window { DockPresenceController.shared.willShow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window `show` puts up, sized and laid out, not yet on screen.
    static func makeWindow(close: @escaping @MainActor () -> Void,
                           showPlans: @escaping @MainActor () -> Void) -> NSWindow {
        let hosting = NSHostingController(rootView: NotesComparisonView(close: close, showPlans: showPlans))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "What each plan writes"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(SettingsLook.ground)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1000, height: 720))
        hosting.view.layoutSubtreeIfNeeded()
        return window
    }
}

/// The three columns, under a title that says it is an example, with the
/// plans' buttons at the foot.
struct NotesComparisonView: View {
    let close: @MainActor () -> Void
    let showPlans: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What each plan writes")
                        .font(Theme.chrome(19, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("The same \(NotesComparisonSample.minutes)-minute call, written three ways. "
                         + "An example call, not one of yours.")
                        .font(Theme.chrome(13))
                        .foregroundStyle(Theme.textSecondary)
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
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(AirlockPlan.allCases, id: \.self) { plan in
                        NotesComparisonColumn(plan: plan)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.automatic)
            HStack(spacing: 10) {
                Text("Free notes are written on your Mac and never leave it. Plus and Pro write them online.")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                CallNotesOfferButton("Get Plus", tone: .plus, action: showPlans)
                CallNotesOfferButton("Get Pro", tone: .pro, action: showPlans)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(minWidth: 820, minHeight: 520)
        .background(SettingsLook.ground)
    }
}

/// One plan's notes of the example call: its name and tag, where and how
/// much of the call they were written from, and the cards.
private struct NotesComparisonColumn: View {
    let plan: AirlockPlan

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let people = CallPeople.people(of: NotesComparisonSample.record)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(plan.label)
                        .font(Theme.chrome(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    PlanTag(plan)
                }
                Text(subtitle)
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)
            ForEach(Array(NotesComparisonSample.sections(plan).enumerated()), id: \.offset) { _, section in
                CallNotesCard(call: nil, section: section, people: people)
            }
            if plan == .free {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("The last \(NotesComparisonSample.freeLeavesOut) minutes are not in these notes.")
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tint.opacity(plan == .free ? 0.02 : 0.035)))
        .overlay(shape.strokeBorder(plan == .free ? Color.white.opacity(0.07) : tint.opacity(0.32), lineWidth: 1))
    }

    private var subtitle: String {
        switch plan {
        case .free: "On your Mac · first \(Int(NotesComparisonSample.freeListened / 60)) minutes"
        case .plus: "Online, a better model · the whole call"
        case .pro: "Online, the best model · the whole call"
        }
    }

    private var tint: Color {
        plan == .free ? .white : PlanTag.tint(plan)
    }
}
