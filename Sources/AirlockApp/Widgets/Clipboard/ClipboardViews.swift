import SwiftUI
import AirlockCore

/// The clipboard tab: search at the top, history below.
///
/// Search is the whole interaction. Scanning a list of two hundred rows is
/// slower than re-copying the thing, so the field takes focus the moment the
/// tab appears and every keystroke narrows the list.
/// The filter row's measurements, in one place because a test asserts against
/// them: this row is the only thing in the panel that provably does not fit at
/// the 460pt floor, and it fit fine at the 640pt default, which is why nobody saw
/// it. See `ClipboardFilterFitTests`.
@MainActor
enum FilterRowMetrics {
    static let horizontalPadding: CGFloat = 9
    static let spacing: CGFloat = 5
    static let height: CGFloat = 26
    /// Between the search field and the filter row.
    static let rowSpacing: CGFloat = 6
    /// The narrowest the search field may be squeezed to and still read as a
    /// search field rather than a stub. It loses the argument with the filter
    /// row on purpose — a placeholder reading "Search clip…" is legible, and a
    /// button reading "Imag…" is not.
    static let searchFieldFloor: CGFloat = 130
    /// The panel floor minus `NotchRootView`'s 10pt horizontal padding, twice.
    static let contentWidthAtPanelFloor: CGFloat = 440

    /// What a COLUMN gives this card if it is dragged into one at the panel
    /// floor: (440 - 25 gutter) / 2. The narrowest place the row can land.
    static let contentWidthInColumnAtFloor: CGFloat = (440 - 25) / 2

    /// The footer's incompressible half: the count and the Clear button. The
    /// privacy sentence beside them yields instead, so these two are what the
    /// budget is measured against.
    static func footerFixedWidth(count: String, clear: String) -> CGFloat {
        func width(_ text: String, _ weight: NSFont.Weight) -> CGFloat {
            (text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 10 * Theme.textScale, weight: weight)
            ]).width.rounded(.up)
        }
        // One 8pt gap: the count and the privacy sentence are one phrase
        // (the sentence starts with its own " · "), then Clear.
        return width(count, .regular) + width(clear, .medium) + 8
    }

    /// The privacy sentence — the footer's compressible third.
    static func privacyWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10 * Theme.textScale, weight: .regular)
        ]).width.rounded(.up)
    }

    /// The Accessibility warning, which now has a line to itself.
    static func warningWidth(_ text: String) -> CGFloat {
        let glyph: CGFloat = 14
        return (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10 * Theme.textScale, weight: .regular)
        ]).width.rounded(.up) + glyph + 4
    }

    /// The icon-only form. The glyph is 11pt and does NOT follow `textScale` —
    /// it is `.system(size: 11)`, like the search field's magnifier — so this
    /// width is the same at every scale, which is what makes it the reliable
    /// fallback.
    static func compactWidth(count: Int) -> CGFloat {
        let glyph: CGFloat = 14
        return CGFloat(count) * (glyph + horizontalPadding * 2)
            + spacing * CGFloat(max(count - 1, 0))
    }

    /// Semibold for every label, because the selected one is semibold and
    /// semibold is wider — the row must fit whichever button is on.
    static func intrinsicWidth(labels: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11 * Theme.textScale, weight: .semibold)
        let text = labels.reduce(CGFloat(0)) { total, label in
            let width = (label as NSString)
                .size(withAttributes: [.font: font]).width
            return total + width.rounded(.up) + horizontalPadding * 2
        }
        return text + spacing * CGFloat(max(labels.count - 1, 0))
    }
}

struct ClipboardSectionView: View {
    @Environment(ClipboardWidgetModel.self) private var clipboard
    @FocusState private var searchFocused: Bool
    @State private var confirmingClear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [ClipboardItem] { clipboard.items }
    private var shortcuts: [UUID: ClipboardShortcut] { ClipboardShortcuts.assign(items) }

    /// The row the pinned block ends at, or nil when there is no boundary to
    /// draw — nothing pinned, or nothing but pins. A rule with only one side is
    /// noise.
    private var firstUnpinnedID: UUID? {
        guard items.contains(where: \.pinned) else { return nil }
        return items.first { !$0.pinned }?.id
    }

    var body: some View {
        @Bindable var clipboard = clipboard
        return VStack(alignment: .leading, spacing: 8) {
            // Three forms, widest first, because this row has to survive two
            // widths nobody looks at: the 460pt panel floor, and the ~207pt a
            // COLUMN gives it if the clipboard is dragged into one (it is
            // movable — `effectiveColumn` honours a stored override).
            //
            // `.fixedSize` alone fixed the floor and made the column worse:
            // incompressible content in a 207pt column overflows and clips,
            // where before it merely truncated. `ViewThatFits` picks the first
            // that actually fits, so words become icons, and icons drop to their
            // own line, rather than any of it being cut off.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FilterRowMetrics.rowSpacing) {
                    searchField(text: $clipboard.query)
                    filterRow(compact: false).fixedSize(horizontal: true, vertical: false)
                }
                HStack(spacing: FilterRowMetrics.rowSpacing) {
                    searchField(text: $clipboard.query)
                    filterRow(compact: true).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    searchField(text: $clipboard.query)
                    filterRow(compact: true)
                }
            }

            // A picked picture whose file had gone. Above the list, because the
            // click that caused it was in the list and the notch stayed open.
            if clipboard.pictureGone != nil {
                ProblemCard(icon: "photo", sentence: ClipboardWidgetModel.pictureGoneSentence,
                            tone: .stopped, button: ClipboardWidgetModel.pictureGoneButton,
                            action: { clipboard.removeGonePicture() })
            }
            // A copy too large to keep never appears in the list, and nothing
            // else in the notch would say why.
            if let notice = clipboard.skipNotice {
                ProblemCard(sentence: notice, button: "Close",
                            action: { clipboard.dismissSkipNotice() })
            }

            if items.isEmpty {
                emptyState
            } else {
                list
                footer
            }
        }
        .onAppear {
            searchFocused = true
            clipboard.beginKeyboardSession()
        }
        .onDisappear { clipboard.endKeyboardSession() }
    }

    /// What activating a row actually does — three states, not two.
    ///
    /// The hint used to promise a paste whenever the setting was on, but
    /// `pasteIfEnabled()` copies and stops when Accessibility is not granted,
    /// which is the state the footer already warns about. Promising a paste
    /// there tells a VoiceOver user the one thing that will not happen.
    private var activationHint: String {
        guard clipboard.pastesAutomatically else { return "Puts this item on the clipboard" }
        return clipboard.pasteIsTrusted
            ? "Pastes this item into the app in front"
            : "Puts this item on the clipboard. Auto-paste is on but needs Accessibility permission"
    }

    // MARK: - Search

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            TextField("Search clipboard", text: text)
                .textFieldStyle(.plain)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                // No `.onKeyPress` here: navigation, shortcuts and dismissal
                // all run through the model's local event monitor, which is the
                // only thing that sees ⌘-modified keys.

            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .clickable()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Theme.rowFill, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rowStroke, lineWidth: 1)
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        if item.id == firstUnpinnedID { groupDivider }
                        ClipboardRowView(item: item,
                                         isSelected: item.id == clipboard.selection,
                                         isFlashing: item.id == clipboard.flashing,
                                         shortcut: shortcuts[item.id])
                            .id(item.id)
                            // Something copied slides in at the top; a deleted
                            // row fades and the rest close up behind it.
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                            .onTapGesture { clipboard.activate(item) }
                            .clickable()
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint(activationHint)
                            .accessibilityAction { clipboard.activate(item) }
                            // Pin appears on hover for the unpinned, and delete
                            // only ever does. `children: .combine` folds the row
                            // into one element, so without these the actions
                            // exist for a pointer and for nothing else.
                            //
                            // Each is added ONLY while its button is absent from
                            // the tree: a visible button's own action is already
                            // folded in by `.combine`, and a second entry with
                            // the same name is indistinguishable from the first
                            // in the rotor. A pinned row always shows its pin
                            // button, so it was offering "Unpin" twice.
                            .accessibilityActions {
                                if !(item.pinned || item.id == clipboard.selection) {
                                    Button("Pin") { clipboard.togglePin(item) }
                                }
                                if item.id != clipboard.selection {
                                    Button("Delete") { clipboard.delete(item) }
                                }
                            }
                            // The highlight follows the pointer and leaves with
                            // it. Clearing is guarded on this row still being
                            // the selected one: arrowing down while the pointer
                            // rests on a row moves the selection off it, and the
                            // eventual hover-out would otherwise wipe a choice
                            // the keyboard had just made.
                            .onHover { hovering in
                                if hovering {
                                    clipboard.selection = item.id
                                } else if clipboard.selection == item.id {
                                    clipboard.selection = nil
                                }
                            }
                    }
                }
                // Keyed on the HISTORY, not on what is shown: a new copy or a
                // delete animates, a filter switch or a search keystroke does
                // not. Keyed on the shown rows, switching from All to Links
                // slid and faded every one of ~200 rows at once, and the panel
                // sat frozen for up to two seconds before anything changed
                // (owner, 2026-10-04).
                .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                           value: clipboard.history.items.map(\.id))
                // Breathing room inside the scroll content, not outside it.
                // A row sits flush against the ScrollView's bounds otherwise,
                // and the clip takes the top of its rounded corners and border
                // — most visible on the first pinned row, which is the one
                // wearing a highlight worth seeing whole.
                .padding(.vertical, 4)
                .padding(.horizontal, 1)
            }
            .frame(maxHeight: 260)
            .ticksAtScrollEnds()
            // Driven by `scrollTarget`, which ONLY the arrow keys set — never by
            // `selection`, which the pointer also sets.
            //
            // Scrolling on selection made the list fight the mouse: hovering a
            // row selected it, that scrolled the row to centre, which slid a
            // different row under the stationary pointer, which selected that
            // one, and so on. Worst at the bottom, where the trip to centre is
            // longest.
            //
            // No anchor either. `.center` yanked a row that was already
            // perfectly visible into the middle on every keypress; the default
            // scrolls the minimum needed to bring it into view.
            .onChange(of: clipboard.scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(MotionEffect.pointer) { proxy.scrollTo(id) }
            }
        }
    }

    /// Separates the pinned block from the rest. It also happens to explain the
    /// two shortcut families — everything above is ⌥, everything below is ⌘ —
    /// which is otherwise something you would have to infer from the badges.
    private var groupDivider: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(Theme.rowStroke)
                .frame(height: 1)
            Text("RECENT")
                .font(Theme.chrome(10, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.6)
            Rectangle()
                .fill(Theme.rowStroke)
                .frame(height: 1)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Its own line, above the counts.
            //
            // It was inline, and inline it did not fit: with the warning present
            // the footer needed 509pt at textScale 1.0 and 667pt at 1.4, against
            // the 440 a 460pt panel gives. Something had to give and SwiftUI
            // chose — the privacy sentence collapsed and the warning itself
            // truncated, so the one state where a switched-on feature silently
            // does nothing announced itself as "Auto-paste needs Access…".
            //
            // Above rather than below, because it sits directly under the list
            // where the eye already is, and because a warning under a Clear
            // button reads as being about the Clear button.
            if clipboard.pastesAutomatically && !clipboard.pasteIsTrusted {
                ProblemCard(sentence: "Auto-paste needs the Accessibility permission.",
                            button: "Turn it on",
                            action: { PasteService.openAccessibilitySettings() })
            }

            HStack(spacing: 8) {
                // The count and the sentence as one phrase, with the count's own
                // " · " between them. They were two views 8pt apart, and the
                // sentence's dot then sat a gap away: "1 pinned  · nothing…".
                HStack(spacing: 0) {
                    Text(countLabel)
                        .font(Theme.chrome(10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()

                    // The privacy promise, where it can actually be read.
                    //
                    // It lived in the empty state, which meant the only person who
                    // ever saw it was somebody with nothing in their clipboard —
                    // everyone with 71 items and a reason to wonder never did. This
                    // is the one sentence a clipboard manager has to be able to
                    // point at.
                    //
                    // It is also the designated loser of this row. At maximum text
                    // scale with a four-digit count the line is a point over budget,
                    // and truncating a sentence that has a tooltip is better than
                    // truncating a number or a button: "Clea…" is not a control.
                    Text(" · nothing from a password manager")
                        .font(Theme.chrome(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                        .help("Entries marked confidential by password managers are never recorded.")
                }

                Spacer(minLength: 0)

                Button(confirmingClear ? "Sure?" : "Clear") {
                    if confirmingClear {
                        clipboard.clearUnpinned()
                        confirmingClear = false
                    } else {
                        confirmingClear = true
                    }
                }
                .buttonStyle(.plain)
                .clickable()
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(confirmingClear ? Theme.danger : Theme.textTertiary)
                .fixedSize()
            }
        }
        // Two clicks, not a dialog — but the armed state must not linger and
        // catch a later, unrelated click.
        .task(id: confirmingClear) {
            guard confirmingClear else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            confirmingClear = false
        }
    }

    private var countLabel: String {
        let pinned = clipboard.history.items.filter(\.pinned).count
        let total = clipboard.history.items.count
        if clipboard.isSearching { return "\(items.count) of \(total)" }
        return pinned > 0 ? "\(total) items · \(pinned) pinned" : "\(total) items"
    }

    /// The type filter, beside the search field rather than above it.
    ///
    /// The design's argument for it: with seventy items, "the link I copied" and
    /// "that screenshot" are different searches and neither is a word you can
    /// type. That is also why it sits next to the field — it is the other half
    /// of finding something, not a separate control.
    ///
    /// No counts on the buttons. An earlier pass had them; the design does not,
    /// and it is right — a number beside every button is five more things to
    /// read in a row whose whole job is to be glanced at.
    private func filterRow(compact: Bool) -> some View {
        HStack(spacing: FilterRowMetrics.spacing) {
            ForEach(ClipboardFilter.allCases) { option in
                let isOn = clipboard.filter == option
                Button {
                    HoverTrace.note("clipboard filter tap \(option.rawValue)")
                    clipboard.filter = option
                } label: {
                    Group {
                        if compact {
                            Image(systemName: option.symbol)
                                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        } else {
                            Text(option.label)
                                .font(Theme.chrome(11, isOn ? .semibold : .regular))
                        }
                    }
                        .foregroundStyle(isOn ? Theme.running : Theme.textSecondary)
                        .padding(.horizontal, FilterRowMetrics.horizontalPadding)
                        .frame(height: FilterRowMetrics.height)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isOn ? Theme.running.opacity(0.14) : .clear)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isOn ? Theme.running : Theme.rowStroke,
                                                      lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
                .clickable()
                .help(option.label)
                .accessibilityLabel("\(option.label) filter")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            // The character gets the "nothing here yet" case and not the
            // search miss: a mascot shrugging at your query reads as the app
            // being cute about failing you, where the magnifying glass just
            // says what happened.
            if clipboard.isSearching {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                BloubView(expression: .unimpressed, motion: .breathing)
                    .frame(width: 34, height: 34)
            }
            Text(clipboard.isSearching ? clipboard.filter.searchMissMessage(query: clipboard.query)
                                       : clipboard.filter.emptyMessage)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
            // A miss under a filter may be only the filter's. One tap widens
            // it and keeps what was typed.
            if clipboard.isSearching && clipboard.filter != .all {
                Button(ClipboardFilter.searchEverythingButton) { clipboard.filter = .all }
                    .buttonStyle(.plain)
                    .clickable()
                    .font(Theme.chrome(11, .semibold))
                    .foregroundStyle(Theme.running)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.running.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(Theme.running.opacity(0.4), lineWidth: 1))
                    .padding(.top, 2)
            }
            if !clipboard.isSearching {
                Text("Passwords and anything an app marks private are never stored.")
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Theme.rowFill.opacity(0.5), in: .rect(cornerRadius: 10))
    }

    // MARK: - Actions

}

// MARK: - Row

private struct ClipboardRowView: View {
    /// Image previews are a filename, never code — see `ClipboardTextKind`.
    private var kind: ClipboardTextKind {
        item.textKind
    }

    private var previewFont: Font {
        kind == .code ? Theme.code : Theme.chrome(11.5)
    }

    private var previewColor: Color {
        switch kind {
        case .code: return Theme.codeText
        case .link: return Theme.running
        case .prose: return Theme.textPrimary
        }
    }

    @Environment(ClipboardWidgetModel.self) private var clipboard
    let item: ClipboardItem
    let isSelected: Bool
    let isFlashing: Bool
    let shortcut: ClipboardShortcut?

    @State private var decoded: NSImage?

    private var isMissingPicture: Bool { clipboard.pictureIsMissing(item) }

    var body: some View {
        HStack(spacing: 9) {
            thumbnail

            // ONE line, not two. Nine items now fit where six did, and the
            // second line was metadata nobody scans for — it moves to the
            // trailing edge where it reads as an aside instead of as content.
            //
            // The face follows the CONTENT: mono is quarantined to code, so a
            // paragraph is set in the UI face, a command in amber mono, and a
            // link in the running accent. Everything was mono before, which
            // made prose look like something you could run.
            if isMissingPicture {
                // Said on the row, before anyone picks it: a picture row with no
                // picture behind it used to look like any other.
                Text(ClipboardWidgetModel.missingPictureRowText)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            } else {
                Text(item.preview)
                    .font(previewFont)
                    .foregroundStyle(previewColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The full text is a tooltip after a hover pause — nothing
                    // expands in place, so the list never reflows under the pointer.
                    .help(item.preview)
            }

            Spacer(minLength: 4)

            if let app = item.sourceAppName {
                Text(app)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            // Always visible: a shortcut nobody can see is a shortcut nobody
            // uses, and these renumber as you pin, search and copy.
            if let shortcut {
                Text(shortcut.label)
                    .font(Theme.chrome(10, .medium))
                    .foregroundStyle(isFlashing ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isFlashing ? Theme.running : Theme.rowStroke.opacity(0.6),
                                in: .rect(cornerRadius: 3))
            }

            // Pin state is permanent information, so it shows always; the
            // destructive action only appears under the pointer.
            if item.pinned || isSelected {
                iconButton(item.pinned ? "pin.fill" : "pin",
                           tint: item.pinned ? Theme.needs : Theme.textTertiary,
                           label: item.pinned ? "Unpin" : "Pin") {
                    clipboard.togglePin(item)
                }
            }
            if isSelected {
                iconButton("xmark", tint: Theme.textTertiary,
                           label: "Delete") { clipboard.delete(item) }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(rowFill, in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(rowStroke, lineWidth: 1)
        }
        .contentShape(.rect)
        .help(item.preview)
        // Snaps on, eases off — the confirmation should register before the
        // panel goes, not fade in as it leaves.
        .animation(isFlashing ? nil : MotionEffect.pointer, value: isFlashing)
        // Keyed on the item, so a recycled row in the LazyVStack reloads rather
        // than showing the previous item's picture.
        .task(id: item.id) { await loadThumbnail() }
    }

    /// Reads and decodes off the main actor, then hands back an image.
    ///
    /// `NSImage(contentsOf:)` is lazy about decoding, so forcing it here — via
    /// a representation — is what actually moves the work. Without that the
    /// decode still happens on the main actor, at first draw, and the change
    /// would look like an improvement while being none.
    private func loadThumbnail() async {
        guard item.isImage, let url = clipboard.imageURL(for: item) else {
            decoded = nil
            return
        }
        let image = await BlockingWork.run { () -> NSImage? in
            guard let image = NSImage(contentsOf: url) else { return nil }
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return image
        }
        decoded = image
    }

    private var rowFill: Color {
        if isFlashing { return Theme.running.opacity(0.45) }
        return isSelected ? Theme.running.opacity(0.16) : Theme.rowFill
    }

    private var rowStroke: Color {
        if isFlashing { return Theme.running }
        return isSelected ? Theme.running.opacity(0.42) : Theme.rowStroke
    }

    /// Cached in `@State` and loaded once per item, not decoded in `body`.
    ///
    /// This used to be `NSImage(contentsOf:)` inside a computed property — a
    /// disk read and a full decode, on the main actor, for a 26×20 slot, on
    /// EVERY render of the row. And the row re-renders constantly: `.onHover`
    /// writes `clipboard.selection` per row, so moving the pointer down the list
    /// re-decoded every image it passed, and so did each keystroke in the search
    /// field. The pattern here is `TrayViews`, which already did it correctly.
    @ViewBuilder
    private var thumbnail: some View {
        if isMissingPicture {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(Theme.needs)
                .frame(width: 26, height: 20)
        } else if let image = decoded {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 20)
                .clipShape(.rect(cornerRadius: 4))
        } else {
            Image(systemName: item.isImage ? "photo"
                              : item.isFile ? "doc" : "text.alignleft")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 26, height: 20)
        }
    }

    private func iconButton(_ symbol: String, tint: Color, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                // 20×20 is the macOS minimum control size; this was 18. The
                // glyph is unchanged — only the target grew.
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        // An SF Symbol is a picture, and a picture has no name. Required rather
        // than defaulted: a new caller that forgets it should not compile.
        .accessibilityLabel(label)
    }
}
