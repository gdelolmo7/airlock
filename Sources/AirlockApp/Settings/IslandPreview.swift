import SwiftUI
import AirlockCore

/// A live picture of the island at the top of Settings → The notch (card
/// Settings 2): closed, and open, drawn by the island's own views so a change
/// on the page shows the instant it is made.
///
/// **The real views, not a copy.** `NotchController.preview()` builds this
/// with every model injected, the same list the island itself gets, so the
/// picture cannot drift from what the notch draws. It is a picture only: hit
/// testing is off, so a play button here never plays.
///
/// Two copies of the same view tree is safe because the island's views only
/// read their models; what they write (a tab choice, a drag) needs a click,
/// and the picture takes none. The one view that acts on appearing, the
/// clipboard list, is kept out by giving the picture its own tab state.
struct IslandPreview: View {
    let registry: WidgetRegistry
    @Environment(NotchAppearanceModel.self) private var appearance
    /// Its own, on Home, rather than the island's: the picture must never show
    /// the Clipboard tab, whose list takes the keyboard when it appears and
    /// would take it from Settings.
    @State private var ui = NotchUIState()

    /// How much of the open panel is shown, before scaling: the top bar and
    /// the first cards, which is what width, surface and text size change.
    private static let openHeight: CGFloat = 300
    /// The housing between the two closed halves. A stand-in width: the real
    /// one is the Mac's, and this is a picture.
    private static let housingWidth: CGFloat = 120
    private static let closedHeight: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Closed")
            closed
            caption("Open")
            GeometryReader { geo in
                let width = appearance.panelWidth
                let scale = min(1, geo.size.width / width)
                open(width: width)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width * scale, height: Self.openHeight * scale, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: Self.openHeight * previewScale)
        }
        .environment(ui)
        // The picture is the notch, so its problems wear the notch's look
        // even though Settings set the form's around it.
        .environment(\.problemCardLook, .notch)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Picture of the notch, closed and open")
    }

    /// A guess at the scale for the frame's height before the reader runs; the
    /// Settings column is about this wide.
    private var previewScale: CGFloat { min(1, 520 / appearance.panelWidth) }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    /// The closed island keeps the kit's black on every surface
    /// (`NotchSurface.isGlassGround`), so its picture does too.
    private var closed: some View {
        HStack(spacing: 0) {
            NotchCompactLeadingView(onTap: {})
                .frame(minWidth: 40)
            Color.black.frame(width: Self.housingWidth)
            NotchCompactTrailingView(onTap: {})
                .frame(minWidth: 40)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.closedHeight)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14,
                                           style: .continuous).fill(Color.black))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity)
    }

    private func open(width: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous)
        return NotchExpandedView(onCollapse: {}, onDragSettled: {}, onOpenSettings: {}, registry: registry)
            // The real panel cancels its host's top inset; the picture has no
            // host, so it is put back.
            .padding(.top, NotchScreen.notched.islandMetrics.foreignTopInset)
            .padding(.horizontal, 12)
            .frame(width: width, height: Self.openHeight, alignment: .top)
            .background(appearance.surface.background)
            .clipShape(shape)
            .environment(\.colorScheme, appearance.surface.colorScheme)
    }
}

/// How Settings asks the notch for the picture. Nil until the notch exists,
/// and in a Settings opened without one.
private struct IslandPreviewKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> AnyView)? = nil
}

extension EnvironmentValues {
    var islandPreview: (@MainActor () -> AnyView)? {
        get { self[IslandPreviewKey.self] }
        set { self[IslandPreviewKey.self] = newValue }
    }
}
