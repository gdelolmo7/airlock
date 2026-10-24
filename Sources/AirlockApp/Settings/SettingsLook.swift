import SwiftUI
import AirlockCore

/// Settings in the notch's look: black, rounded rows, one line per
/// setting, the long explanations behind "More options".
///
/// The pieces a page is built from, so every page that moves over reads the
/// same: a header, rows grouped in a column, a chip for a choice, a switch, a
/// status dot. The numbers are the notch's own: the panel's near-black and
/// border, the row fill and stroke a card wears in the island, the green a
/// finished agent shows.
///
/// **Fonts come from `Theme.chrome`**, the notch's type, so the Text size
/// setting reaches Settings too. That is the point of one look: a reader who
/// made the notch bigger to read it wants these words bigger as well.
enum SettingsLook {
    /// The window's ground: the island's near-black.
    static let ground = Theme.pill
    static let rowFill = Color.white.opacity(0.035)
    static let rowStroke = Color.white.opacity(0.05)
    static let chipFill = Color.white.opacity(0.07)
    /// The page you are on, in either kind of tabs.
    static let selectedFill = Color.white.opacity(0.12)
    static let selectedStroke = Color.white.opacity(0.08)
    /// A switch that is on, and "All set".
    static let on = Theme.done
    static let rowRadius: CGFloat = 12
    static let rowSpacing: CGFloat = 6
}

// MARK: - Page

/// Title and one sentence saying what the page is for, and "Learn more" at
/// the end of the title's line when the website has a page about it.
struct LookPageHeader: View {
    let title: String
    let subtitle: String
    var learnMore: [FeaturePage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Theme.chrome(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                LookLearnMore(pages: learnMore)
            }
            Text(subtitle)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small heading over a group of rows inside "More options".
struct LookGroupLabel: View {
    let text: Text

    init(_ text: LocalizedStringKey) { self.text = Text(text) }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) { self.text = Text(text) }

    var body: some View {
        text
            .textCase(.uppercase)
            .font(Theme.label)
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A whole page: the header, the rows most people come for, then "More
/// options" over everything else. Every page is built on this, so they all
/// open the same way.
struct LookPage<Rows: View, More: View>: View {
    let title: String
    let subtitle: String
    /// The website's pages about what this page sets up (`LookLearnMore`).
    var learnMore: [FeaturePage] = []
    @Binding var moreOptions: Bool
    /// Rows that live behind "More options": a link to one opens them first,
    /// or it would scroll to a row that is not there.
    var anchorsInMoreOptions: Set<SettingsAnchor> = []
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var more: () -> More

    /// Optional so the state gallery can draw a page without the window.
    @Environment(SettingsModel.self) private var settings: SettingsModel?

    init(_ title: String, subtitle: String, learnMore: [FeaturePage] = [], moreOptions: Binding<Bool>,
         anchorsInMoreOptions: Set<SettingsAnchor> = [],
         @ViewBuilder rows: @escaping () -> Rows, @ViewBuilder more: @escaping () -> More) {
        self.title = title
        self.subtitle = subtitle
        self.learnMore = learnMore
        _moreOptions = moreOptions
        self.anchorsInMoreOptions = anchorsInMoreOptions
        self.rows = rows
        self.more = more
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
                LookPageHeader(title: title, subtitle: subtitle, learnMore: learnMore)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                rows()
                if More.self != EmptyView.self {
                    LookMoreButton(isOpen: $moreOptions)
                        .padding(.top, 6)
                    if moreOptions {
                        VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
                            more()
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsLook.ground)
        .environment(\.colorScheme, .dark)
        .environment(\.problemCardLook, .notch)
        .onAppear(perform: openForReveal)
        .onChange(of: settings?.revealRequest?.serial) { openForReveal() }
    }

    private func openForReveal() {
        guard let anchor = settings?.revealRequest?.anchor,
              anchorsInMoreOptions.contains(anchor) else { return }
        moreOptions = true
    }
}

extension LookPage where More == EmptyView {
    /// A page short enough to have nothing behind "More options".
    init(_ title: String, subtitle: String, learnMore: [FeaturePage] = [],
         @ViewBuilder rows: @escaping () -> Rows) {
        self.init(title, subtitle: subtitle, learnMore: learnMore, moreOptions: .constant(false),
                  rows: rows, more: { EmptyView() })
    }
}

/// "Learn more ↗": the website's page about what a Settings page sets up,
/// opened in the browser. A page that sets up several things ("The notch")
/// offers their pages in a menu instead.
///
/// Quiet on purpose, in the colour and size of "More options": it is there
/// for whoever wonders what a page is for, not a call to action. Nothing is
/// fetched to draw it; the page opens only on a click, so it sends nothing
/// the app did not send before.
struct LookLearnMore: View {
    let pages: [FeaturePage]

    var body: some View {
        if pages.count == 1, let page = pages.first {
            Button { NSWorkspace.shared.open(page.url) } label: { label(arrow: "arrow.up.right") }
                .buttonStyle(.plain)
                .clickable()
                .fixedSize()
                .help("Opens \u{201c}\(page.title)\u{201d} on useairlock.app, in your browser.")
                .accessibilityLabel("Learn more about \(page.title), on the website")
        } else if !pages.isEmpty {
            Menu {
                ForEach(pages, id: \.self) { page in
                    Button(page.title) { NSWorkspace.shared.open(page.url) }
                }
            } label: {
                label(arrow: "chevron.down")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .clickable()
            .help("Pages on useairlock.app about what this page sets up. They open in your browser.")
            .accessibilityLabel("Learn more on the website")
        }
    }

    private func label(arrow: String) -> some View {
        HStack(spacing: 3) {
            Text("Learn more")
            Image(systemName: arrow)
                .font(.system(size: 8.5, weight: .semibold))
        }
        .font(Theme.chrome(11.5))
        .foregroundStyle(Theme.textSecondary)
        .contentShape(.rect)
    }
}

/// Rows drawn on their own, outside a page: what the state gallery uses to
/// show one part of a page at a time.
struct LookColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsLook.ground)
        .environment(\.colorScheme, .dark)
        .environment(\.problemCardLook, .notch)
    }
}

// MARK: - Rows

/// One setting on one line: what it is on the left, its value on the right.
/// The optional second line is short, a few words, never a paragraph: the
/// paragraphs live behind "More options".
struct LookRow<Trailing: View>: View {
    let title: Text
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: LocalizedStringKey, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: Text(title), subtitle: subtitle, trailing: trailing)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: Text(title), subtitle: subtitle, trailing: trailing)
    }

    init(title: Text, subtitle: String?, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .lookRowBox()
    }
}

extension LookRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: String? = nil) {
        self.init(title: Text(title), subtitle: subtitle) { EmptyView() }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, subtitle: String? = nil) {
        self.init(title: Text(title), subtitle: subtitle) { EmptyView() }
    }
}

/// A row that is a switch. The whole row flips it, not just the knob.
struct LookToggleRow: View {
    let title: Text
    var subtitle: String?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.subtitle = subtitle
        _isOn = isOn
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.subtitle = subtitle
        _isOn = isOn
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        LookRow(title: title, subtitle: subtitle) {
            Toggle(isOn: $isOn) { title }
                .toggleStyle(LookSwitchStyle())
                .labelsHidden()
        }
        .contentShape(.rect)
        .onTapGesture { if isEnabled { isOn.toggle() } }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The box a row sits in: the island card's fill and hairline.
    func lookRowBox() -> some View {
        padding(.vertical, 9)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsLook.rowRadius, style: .continuous)
                .fill(SettingsLook.rowFill))
            .overlay(RoundedRectangle(cornerRadius: SettingsLook.rowRadius, style: .continuous)
                .strokeBorder(SettingsLook.rowStroke, lineWidth: 1))
    }
}

// MARK: - Values

/// A value shown as a small key-cap-like chip, as in "⌃ Control".
struct LookChip: View {
    let text: Text
    var showsArrows = false

    init(text: String, showsArrows: Bool = false) {
        self.init(text: Text(text), showsArrows: showsArrows)
    }

    init(text: Text, showsArrows: Bool = false) {
        self.text = text
        self.showsArrows = showsArrows
    }

    var body: some View {
        HStack(spacing: 4) {
            text
                .font(Theme.chrome(11.5, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if showsArrows {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsLook.chipFill))
        .fixedSize()
    }
}

/// A choice: the chip is the button, and the menu lists the options.
struct LookMenu<Items: View>: View {
    let value: Text
    @ViewBuilder var items: () -> Items

    init(_ value: LocalizedStringKey, @ViewBuilder items: @escaping () -> Items) {
        self.value = Text(value)
        self.items = items
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ value: S, @ViewBuilder items: @escaping () -> Items) {
        self.value = Text(value)
        self.items = items
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            items()
        } label: {
            LookChip(text: value, showsArrows: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .clickable()
    }
}

/// A plain-words button at the end of a row ("Allow", "Edit…").
///
/// `large` is the size a window's own footer uses (the welcome window),
/// and `isDefault` answers Return there.
struct LookButton: View {
    let title: Text
    var prominent = false
    var large = false
    var isDefault = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, prominent: Bool = false, large: Bool = false,
         isDefault: Bool = false, action: @escaping () -> Void) {
        self.init(title: Text(title), prominent: prominent, large: large, isDefault: isDefault, action: action)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, prominent: Bool = false, large: Bool = false,
                            isDefault: Bool = false, action: @escaping () -> Void) {
        self.init(title: Text(title), prominent: prominent, large: large, isDefault: isDefault, action: action)
    }

    private init(title: Text, prominent: Bool, large: Bool, isDefault: Bool, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.large = large
        self.isDefault = isDefault
        self.action = action
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            title
                .font(Theme.chrome(large ? 13 : 11.5, .semibold))
                .foregroundStyle(prominent ? Theme.pill : Theme.textPrimary)
                .padding(.horizontal, large ? 14 : 10)
                .padding(.vertical, large ? 7 : 4)
                .background(RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Theme.textPrimary) : AnyShapeStyle(Color.white.opacity(0.10))))
                .contentShape(.rect)
        }
        .keyboardShortcut(isDefault ? .defaultAction : nil)
        .buttonStyle(.plain)
        .clickable()
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A value at the end of a row, in the quieter colour: "12 items".
struct LookValue: View {
    let text: Text
    var monospaced = false

    init(_ text: LocalizedStringKey, monospaced: Bool = false) {
        self.text = Text(text)
        self.monospaced = monospaced
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S, monospaced: Bool = false) {
        self.text = Text(text)
        self.monospaced = monospaced
    }

    var body: some View {
        text
            .font(monospaced ? Theme.chrome(11.5).monospaced() : Theme.chrome(11.5))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .truncationMode(.middle)
    }
}

/// A slider at the end of a row, with what it is set to beside it.
struct LookSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(Theme.textSecondary)
                .frame(width: 170)
            Text(label)
                .font(Theme.chrome(11.5).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

/// A coloured dot and a word: "● All set".
struct LookStatus: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? SettingsLook.on : Theme.needs)
                .frame(width: 7, height: 7)
            Text(text)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
        }
        .fixedSize()
    }
}

/// The notch's switch: a small capsule, green when on.
struct LookSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Button {
            withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { configuration.isOn.toggle() }
        } label: {
            Capsule()
                .fill(on ? SettingsLook.on : Color.white.opacity(0.14))
                .frame(width: 30, height: 18)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// "More options ›", centred under the rows, and "Fewer options" once open.
struct LookMoreButton: View {
    @Binding var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(isOpen ? "Fewer options" : "More options")
                // Up once open: "Fewer options" folds them back up, and an
                // arrow pointing down said the opposite.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? -90 : 0))
            }
            .font(Theme.chrome(11.5))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tabs

/// The pages as a column down the left: an icon and a word each, the one you
/// are on in the brighter fill, sliding to the next.
///
/// With `calls`, the Airlock window's column: Calls first, then the Settings
/// pages under their label. One highlight slides between all of them.
struct LookSideTabs: View {
    let pages: [SettingsPane]
    @Binding var selection: SettingsPane
    /// Whether Calls is the row chosen; nil leaves the row out (call notes
    /// are off, or this is Settings on its own, as in the gallery).
    var calls: Binding<Bool>?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let onCalls = calls?.wrappedValue == true
        VStack(alignment: .leading, spacing: 2) {
            if let calls {
                tab(String(localized: "Calls"), symbol: "phone",
                    help: String(localized: "Every call's notes, what was said, and its recording."),
                    selected: onCalls) { calls.wrappedValue = true }
                LookGroupLabel("Settings")
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            ForEach(pages) { page in
                tab(page.tabTitle, symbol: page.symbol, help: page.blurb,
                    selected: !onCalls && selection == page) { selection = page }
            }
        }
    }

    private func tab(_ title: String, symbol: String, help: String, selected: Bool,
                     choose: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { choose() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(Theme.chrome(12.5, selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SettingsLook.selectedFill)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(SettingsLook.selectedStroke, lineWidth: 1))
                        .matchedGeometryEffect(id: "selectedPage", in: highlight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .help(help)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The window's left column: search at the top, the pages under it, and
/// with `calls` the Calls row above them.
struct LookSidebar: View {
    let pages: [SettingsPane]
    @Binding var selection: SettingsPane
    var calls: Binding<Bool>?
    @Binding var query: String
    /// Changes when ⌘F is pressed; the field takes the cursor.
    var focusRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // It searches the settings only; the calls have their own field
            // above their list.
            LookSearchField(text: $query, hint: calls == nil ? String(localized: "Search") : String(localized: "Search settings"),
                            focusRequest: focusRequest)
            LookSideTabs(pages: pages, selection: $selection, calls: calls)
            Spacer(minLength: 0)
        }
        // The window's title bar is already above this (the safe area), and
        // clears the close and minimise buttons on its own.
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .trailing) {
            Rectangle().fill(SettingsLook.rowStroke).frame(width: 1)
        }
    }

    static let width: CGFloat = 176
}

/// "Search", in the row box's fill. Esc clears it.
struct LookSearchField: View {
    @Binding var text: String
    var hint = String(localized: "Search")
    var focusRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField(hint, text: $text, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
                // A grey hint drawn here: the field's own placeholder came
                // out white, which read as something already typed.
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(hint)
                            .font(Theme.chrome(12))
                            .foregroundStyle(Theme.textTertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .clickable()
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SettingsLook.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(focused ? SettingsLook.selectedStroke : SettingsLook.rowStroke, lineWidth: 1))
        .onChange(of: focusRequest) { focused = true }
    }
}
