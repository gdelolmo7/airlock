import AirlockCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// The tray tab: a shelf you drag files onto and off again.
///
/// Dropping on the CUTOUT moves the file here, the way dropping it into a
/// folder would — drag something out of Downloads and Downloads no longer has
/// it. Option forces a copy, which is the same escape hatch Finder offers, and
/// a source that will not give the file up (a mounted DMG, a read-only volume)
/// is copied from instead of refused.
///
/// Dropping on the OPEN PANEL copies, and the badge under the cursor says so.
/// SwiftUI's `DropInfo` carries no source operation mask, so that seam cannot
/// tell a source that offers a move from one that does not — and the shelf does
/// not take a file on an assumption. `TrayModel.gestureFromPanelDrop` is where
/// that is written down.
///
/// Dragging an item back OUT is the same bargain in reverse: a destination that
/// takes the file empties the tile, and the file goes to the Trash rather than
/// being unlinked. "Takes the file" is not a guess — it is the destination
/// answering `.move`, which is the drag protocol's way of saying the source
/// should let its copy go. A drag abandoned over the desktop, cancelled with
/// Escape, refused, aliased, or merely read for its path leaves the tile exactly
/// where it was. `TrayDragOutcome.decide` is where that is written down and
/// `TrayTileDragSource` is what can ask the question at all.
struct TraySectionView: View {
    @Environment(TrayModel.self) private var tray
    @Environment(NotchUIState.self) private var uiState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shelfHeight: CGFloat?

    /// One signal for both routes now. The shelf used to carry its own
    /// `.onDrop` and OR its `isTargeted` in beside this, which meant two drop
    /// targets on one panel with two different type lists — the reason a drag
    /// got a different answer depending on whether it landed on the grid or
    /// beside it. `TrayPanelDropTarget` is the panel's only target and sets
    /// this, exactly as the cutout's catcher already did.
    private var isDropTarget: Bool { uiState.isDropTargeted && !uiState.isDraggingOut }

    private static let tileTransition = AnyTransition.scale(scale: 0.85).combined(with: .opacity)

    /// Set only while a refused drag hovers — red, with the reason.
    private var rejection: String? { uiState.dropRejection }

    private var accent: Color { rejection == nil ? Theme.running : Theme.danger }

    /// A file still landing counts as content: the shelf is showing placeholder
    /// tiles, so the dashed "nothing here yet" outline would contradict them.
    private var isEmptyShelf: Bool { tray.isEmpty }

    /// The empty state's dashed outline has to be legible enough to read as a
    /// drop target; `rowStroke` is tuned to separate populated rows and all but
    /// disappears here.
    private var borderColor: Color {
        if isDropTarget { return accent }
        return isEmptyShelf ? Theme.textTertiary.opacity(0.5) : Theme.rowStroke
    }

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 8)]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            shelf
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ShelfHeightKey.self, value: proxy.size.height)
                })
            // Matched to the shelf so the two read as one row. Under the kit's
            // `.fixedSize()` the panel is laid out at ideal height, so
            // `maxHeight: .infinity` does not stretch — the height has to be
            // measured and passed across.
            TrayRailView(height: shelfHeight)
        }
        .onPreferenceChange(ShelfHeightKey.self) { height in
            if height > 0 { shelfHeight = height }
        }
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rejection {
                // Replaces the grid rather than sitting above it: the answer to
                // "why didn't that work" should be the only thing you see.
                notice(rejection, dismiss: nil)
                    .padding(.vertical, 10)
            } else {
                // Above the grid, not instead of it. This used to live in the
                // empty state alone, so the one person who never saw it was the
                // one with a shelf — and "couldn't add that file" is exactly the
                // message that arrives while items are already sitting there.
                if let error = tray.lastError {
                    if tray.lastErrorFix != nil {
                        // A switch in System Settings fixes this one, so the
                        // card's one button goes there rather than only closing.
                        ProblemCard(sentence: error, tone: .needs, button: TrayFix.button,
                                    action: { tray.openFix() })
                    } else {
                        notice(error, dismiss: { tray.dismissError() })
                    }
                }
                if isEmptyShelf {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(tray.items) { item in
                            TrayTileView(item: item)
                                .transition(Self.tileTransition)
                        }
                        // Same geometry as a real tile, so the grid does not
                        // jump when the file lands and one replaces the other.
                        ForEach(tray.ingesting, id: \.self) { name in
                            TrayIngestingTileView(name: name)
                                .transition(.opacity)
                        }
                    }
                    // A dropped file grows into its place and a removed one
                    // shrinks out, the others sliding over (2026-10-04).
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                               value: tray.items.map(\.id))
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: tray.ingesting)
                    footer
                }
            }
        }
        // A floor, not a height: the rail beside this is taller than a one-row
        // shelf, and `.frame(height:)` on the rail neither clips nor grows it —
        // the cards would draw outside their own rounded rect. See
        // `TrayRailMetrics.shelfContentMinimum`.
        .frame(maxWidth: .infinity, minHeight: TrayRailMetrics.shelfContentMinimum,
               alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTarget ? accent.opacity(0.14) : Theme.rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(borderColor,
                                      style: StrokeStyle(lineWidth: isDropTarget ? 1.5 : 1,
                                                         dash: isEmptyShelf && !isDropTarget ? [5, 4] : []))
                )
        )
        .animation(MotionEffect.pointer, value: isDropTarget)
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: rejection)
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: tray.lastError)
    }

    /// One shape for both messages, because they say the same kind of thing.
    /// The difference is the X: a rejection lives exactly as long as the drag
    /// hovering over the panel, while an error outlives the thing it is about
    /// and would otherwise sit there for the rest of the session.
    private func notice(_ message: String, dismiss: (() -> Void)?) -> some View {
        ProblemCard(sentence: message, tone: dismiss == nil ? .needs : .stopped,
                    button: dismiss == nil ? nil : "Close", action: dismiss)
    }

    /// Centred glyph over label, filling the dashed area — an empty shelf should
    /// read as a target, not as a paragraph. What a drop DOES — it takes the
    /// file, and Option leaves it — moves to the tooltip: useful once, noise
    /// every time after. It is the one line that has to stay accurate, because
    /// a shelf that quietly empties Downloads and says nothing is a bug report.
    /// Errors are no longer smuggled in here; they have their own row above,
    /// where a shelf with items in it can show them too.
    /// The shelf's most common state, at 64pt instead of 250.
    ///
    /// **Empty is not the same as important.** A quarter of the panel given over
    /// to a dashed void said "this is the main event" about a tab that had
    /// nothing in it, and the void was mostly the drop target being drawn at the
    /// size of its own ambition. A strip still reads as a target — it is a
    /// dashed rectangle you can drop on — and leaves the rest of the tab to
    /// whatever else is on it.
    ///
    /// It also stops being the ONLY way in. A drag is the right gesture when
    /// your hand is already on the file and an impossible one when the panel is
    /// open over Finder, so the selection route sits right here.
    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Drop files here")
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("or add what's selected in Finder")
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 6)

            Button { Task { await tray.addFinderSelection() } } label: {
                Text("Add selection")
                    .font(Theme.chrome(11, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08)))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .help("Adds whatever is selected in Finder, leaving the originals in place.")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 64)
        .help("Dropping a file moves it here. Hold Option while you drop to leave the original where it is.")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(tray.items.count) item\(tray.items.count == 1 ? "" : "s") · \(TrayFormat.size(tray.totalSize))")
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Open folder") { tray.openFolder() }
                .buttonStyle(.plain)
                .clickable()
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(Theme.textSecondary)
            Button("Clear") { tray.clear() }
                .buttonStyle(.plain)
                .clickable()
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(Theme.textSecondary)
                .help("Moves everything to the Trash — recoverable from there.")
        }
    }

}

/// Shared by the footer's total and by each tile's tooltip, so the shelf never
/// spells the same number two ways.
///
/// `@MainActor` for the formatter alone: it is shared mutable state that Swift 6
/// will not let sit at file scope otherwise, and every caller is a view body.
@MainActor
private enum TrayFormat {
    /// `allowsNonnumericFormatting` off, because the default turns 0 into
    /// "Zero KB", which reads like a bug rather than an empty shelf.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func size(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Drop here to send rather than shelve. Its own box because a context menu on
/// an item you haven't shelved yet is a step too many — the common case is a
/// file in hand that belongs on another device, not in the tray.
///
/// It cannot own a SwiftUI drop target: the catcher intercepts every drop before
/// the panel sees it. So it publishes its frame and the catcher routes by
/// location instead.
/// The destinations rail: AirDrop, and — once there is something on the shelf —
/// somewhere to move it or throw it away.
///
/// The design's argument is aim: "so dragging out has somewhere to aim inside a
/// 640pt panel". Dragging a tile to the real Finder means leaving the panel,
/// which collapses it.
///
/// **Downloads and Trash appear only when the shelf has something on it.** An
/// empty shelf has nothing to send anywhere, so the rail is the AirDrop box it
/// has always been — and `TrayRailLayout` agrees, which is what stops an inbound
/// drop from finding a Trash card that is not drawn.
private struct TrayRailView: View {
    let height: CGFloat?
    @Environment(NotchUIState.self) private var uiState
    @Environment(TrayModel.self) private var tray

    private var hasDestinations: Bool { !tray.isEmpty }
    private func isTargeted(_ destination: TrayRailDestination) -> Bool {
        uiState.overRailDestination == destination
    }

    var body: some View {
        VStack(spacing: TrayRailMetrics.spacing) {
            hero
            if hasDestinations {
                ForEach(TrayRailDestination.allCases.filter { $0 != .airDrop }, id: \.self) { destination in
                    row(destination)
                }
            }
        }
        .frame(width: TrayRailMetrics.width)
        .frame(height: height)
        .padding(.vertical, height == nil ? 24 : 0)
        // A preference rather than writing straight from a GeometryReader:
        // publishing during the update phase is a state mutation mid-layout,
        // which SwiftUI is free to drop — and dropping it meant the frame stayed
        // nil, so the hit test never matched and nothing lit up or received
        // anything. Preferences resolve after layout.
        //
        // ONE publisher, for the whole column. Three cards each publishing their
        // own rect into one key would collapse to whichever `reduce` happened to
        // see last, and the router would aim every drop at that one.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TrayRailKey.self, value: proxy.frame(in: .global))
            }
        )
        .onPreferenceChange(TrayRailKey.self) { frame in
            if frame.width > 0 { uiState.railFrame = frame }
        }
        .animation(MotionEffect.pointer, value: uiState.overRailDestination)
    }

    private var hero: some View {
        VStack(spacing: TrayRailMetrics.heroSpacing) {
            Image(systemName: TrayRailDestination.airDrop.symbol)
                .font(.system(size: 19, weight: .light))
                .frame(height: TrayRailMetrics.heroGlyph)
                .foregroundStyle(isTargeted(.airDrop) ? Theme.running : Theme.textTertiary)
            Text(TrayRailDestination.airDrop.label)
                .font(Theme.chrome(12, .medium))
                .foregroundStyle(isTargeted(.airDrop) ? Theme.textPrimary : Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, TrayRailMetrics.heroPadding)
        .background(card(isTargeted: isTargeted(.airDrop), destructive: false))
        .help("Drop a file here to AirDrop it — it isn't shelved, and the original stays where it is.")
    }

    /// The two fixed rows. `ViewThatFits` because "Downloads" is 56pt at text
    /// scale 1.0 and 75 at 1.4, against a 67pt budget — it truncates at the top
    /// of the range, so the icon-only form is required rather than defensive.
    private func row(_ destination: TrayRailDestination) -> some View {
        let on = isTargeted(destination)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: TrayRailMetrics.rowGap) {
                Image(systemName: destination.symbol)
                    .frame(width: TrayRailMetrics.rowIcon)
                Text(destination.label)
                    .font(Theme.chrome(10, .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack {
                Spacer(minLength: 0)
                Image(systemName: destination.symbol)
                    .frame(width: TrayRailMetrics.rowIcon)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        // Warm, not blue, and only these two: the accent says "this one changes
        // your files", which AirDrop does not.
        .foregroundStyle(on ? Theme.needs : Theme.textSecondary)
        .padding(.horizontal, TrayRailMetrics.rowPadding)
        .frame(height: TrayRailMetrics.rowHeight)
        .background(card(isTargeted: on, destructive: destination.isDestructive))
        .help(destination == .downloads
              ? "Drag a shelf item here to move it to your Downloads folder."
              : "Drag a shelf item here to put it in the Trash — recoverable from there.")
    }

    private func card(isTargeted: Bool, destructive: Bool) -> some View {
        let accent = destructive ? Theme.needs : Theme.running
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isTargeted ? accent.opacity(0.16) : Theme.rowFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isTargeted ? accent : Theme.rowStroke,
                                  lineWidth: isTargeted ? 1.5 : 1)
            )
    }
}

/// Why one click can only ever trash one file.
///
/// The remove x appears under the pointer, and the tile it sits on answers a
/// DOUBLE-click by opening the file. Double-click the x on a five-item shelf
/// and the first click trashes item 1, the grid reflows item 2 into the slot
/// the pointer is still resting in, hover re-establishes, and the second click
/// of that one gesture lands on item 2's x. Two files in the Trash, one of
/// which was never pointed at.
///
/// The discriminator is the one macOS itself uses to decide what a double-click
/// is: time AND place. Two clicks close together at the same spot are one
/// gesture, whatever ended up underneath them in between. Moving the pointer to
/// another tile's x is a second gesture and is never refused, so removing
/// several items in a row stays as fast as the pointer.
///
/// Pure and value-typed so the rule can be tested without a window.
struct TrayRemoveGuard {
    /// A second click of a double-click lands within a point or two of the
    /// first, never across a tile.
    static let slop: CGFloat = 4

    private var last: (at: Date, point: CGPoint)?

    /// `interval` is the system's double-click interval at the call site.
    ///
    /// A refusal deliberately does NOT become the new baseline: a triple-click
    /// is measured from the click that actually removed something, so its third
    /// click cannot slip through by being late relative to its second.
    mutating func allowsRemoval(at point: CGPoint, on now: Date,
                                within interval: TimeInterval) -> Bool {
        if let last,
           now.timeIntervalSince(last.at) < interval,
           abs(point.x - last.point.x) <= Self.slop,
           abs(point.y - last.point.y) <= Self.slop {
            return false
        }
        last = (now, point)
        return true
    }
}

/// One guard for the whole shelf, because the two clicks land on two different
/// tiles: a per-tile flag would see a single click each and let both through.
@MainActor
enum TrayRemoveGate {
    private static var shelf = TrayRemoveGuard()

    static func allowsRemoval(at point: CGPoint) -> Bool {
        shelf.allowsRemoval(at: point, on: Date(), within: NSEvent.doubleClickInterval)
    }
}

/// What a tile can honestly say about itself, and nothing more.
///
/// Both facts arrive with a sentinel meaning "not known yet", and both sentinels
/// format into something that reads as a fact: `.distantPast` prints as
/// "1 Jan 1", and a folder whose size walk has not landed yet is a plain 0,
/// which reads as an empty folder for however long the walk takes — seconds, on
/// a network mount. A tooltip with one fact in it is fine. A tooltip with a
/// false one is not.
@MainActor
enum TrayTileDetails {
    static func parts(for item: TrayItem) -> [String] {
        var parts: [String] = []
        // A directory's size is measured off the main actor and is a
        // placeholder 0 until that walk reports back — so an unmeasured folder
        // gets no size at all, and a measured empty one says so in words.
        if item.sizeIsKnown {
            parts.append(item.isDirectory && item.size == 0 ? "empty" : TrayFormat.size(item.size))
        }
        // `.distantPast` is `reload`'s stand-in for a modification date the
        // filesystem would not give up.
        if item.modified > .distantPast {
            parts.append("modified \(TrayFormat.date(item.modified))")
        }
        return parts
    }

    /// The line under a tile's name: "PNG · 2.4 MB", "Folder · 12 MB". A folder
    /// still being measured says only "Folder"; a measured empty one says
    /// "Folder · Empty" — it used to read "Folder · Zero KB" in both cases, and
    /// in the first one for as long as the walk took.
    static func subtitle(for item: TrayItem) -> String {
        guard item.isDirectory else {
            let size = TrayFormat.size(item.size)
            let ext = item.url.pathExtension.uppercased()
            return ext.isEmpty ? size : "\(ext) · \(size)"
        }
        guard item.sizeIsKnown else { return "Folder" }
        return item.size == 0 ? "Folder · Empty" : "Folder · \(TrayFormat.size(item.size))"
    }

    /// What the tile under an arriving file says, where a size will go.
    static let arrivingSubtitle = "Adding…"

    /// The tooltip. The gesture is the one thing that is always true, so it is
    /// what remains when both facts are missing.
    static func help(for item: TrayItem) -> String {
        let parts = parts(for: item)
        guard !parts.isEmpty else { return "Double-click to open" }
        return "\(parts.joined(separator: " · ")) — double-click to open"
    }
}

private struct TrayTileView: View {
    let item: TrayItem

    /// "PNG · 2.4 MB", or "Folder · 12 MB" — what you need to tell two
    /// exports apart without opening either.
    private var subtitle: String { TrayTileDetails.subtitle(for: item) }
    @Environment(TrayModel.self) private var tray
    /// Read only from gesture callbacks, never from `body` — see `onHover`.
    /// Touching it in `body` would make every drag out re-render its own source.
    @Environment(NotchUIState.self) private var uiState
    @State private var thumbnail: NSImage?
    /// A rendered preview fills the tile; a document/folder icon has to sit
    /// smaller and centred or it looks stretched and wrong.
    @State private var isIcon = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: isIcon ? 34 : .infinity, maxHeight: isIcon ? 34 : .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: isIcon ? 0 : 8, style: .continuous))
                }
            }
            .frame(height: 56)

            VStack(alignment: .leading, spacing: 0) {
                // Two lines, the way Finder names an icon: one line cut long
                // names mid-word ("Notes f…sday.txt"). Space for both is kept
                // on every tile, so a row of tiles keeps one baseline.
                Text(item.name)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.middle)
                // Both of these lived ONLY in the tooltip, which is to say they
                // lived nowhere: a shelf is a staging area and "which of these
                // two exports is the big one" is the question it exists to
                // answer. Neither is worth a hover.
                Text(subtitle)
                    .font(Theme.chrome(9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        // The drag out, and the double-click that opens the file, both live in
        // this layer now. `.onDrag` cannot say whether the drop happened — it
        // returns an item provider and stops talking — and a shelf tile is a
        // real file, so a removal it cannot justify is a file it deleted on a
        // hunch. See `TrayTileDragSource`.
        .overlay { dragSource }
        // OUTSIDE the drag source, and that is the whole point: the affordance
        // shows and hides with the pointer, and the pointer leaving is exactly
        // how a drag out begins. Inside the source — which is where this used to
        // be — every appearance change was a change to the view AppKit is
        // dragging, and the note above records what that costs. Applied after
        // the drag layer, the x is a sibling over it rather than part of it, so
        // hover can do what it likes for the length of the drag. Hit testing
        // goes with the opacity so an invisible target can't take a click, and
        // the drag layer declines this exact square so a click that lands here
        // reaches it — see `TrayDragOutLayer.hitTest`.
        .overlay(alignment: .topTrailing) {
            removeAffordance
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        // Frozen for the length of a drag out. Belt to the overlay's braces:
        // the pointer leaving is the first thing a drag does, so this is the one
        // hover event guaranteed to arrive mid-gesture, and the tile it would
        // redraw is the tile being dragged. `uiState` is read here and never in
        // `body`, so observing it costs no re-render of its own.
        .onHover { hovering in
            guard !uiState.isDraggingOut else { return }
            isHovering = hovering
        }
        .contextMenu {
            // Open leads because it is what a double-click does, and a context
            // menu whose first item is not the default action teaches the wrong
            // default.
            Button("Open") { tray.open(item) }
            Button("Reveal in Finder") { tray.reveal(item) }
            Button("AirDrop…") { tray.airDrop(item) }
            Divider()
            // Stays, corner affordance or not: the pointer route is the fast
            // one, this is the one you can find.
            Button("Remove") { tray.remove(item) }
        }
        // The name is already drawn under the tile, so the tooltip carries what
        // the tile cannot show instead of repeating it.
        .help(TrayTileDetails.help(for: item))
        // `.ignore`, because the parts are a picture with no name and a label
        // that says nothing about being a file. Without this a tile reads as an
        // unlabelled image sitting next to some text.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.isDirectory ? "folder" : "file")")
        .accessibilityValue(TrayTileDetails.parts(for: item).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tray.open(item) }
        // The corner affordance appears under the pointer and the context menu
        // needs one too, so without this the only way to empty the shelf a file
        // at a time is a gesture VoiceOver never makes.
        .accessibilityAction(named: "Remove") { tray.remove(item) }
        .task(id: item.id) { await loadThumbnail() }
    }

    /// The AppKit drag source, sized to the whole tile and invisible.
    ///
    /// `onOpen` is here rather than on a SwiftUI tap gesture because this layer
    /// takes the press that could become a drag, so it is the only thing in a
    /// position to see the second click of a double-click.
    private var dragSource: some View {
        TrayTileDragSource(
            url: item.url,
            // The tile has already rendered a preview or the file's own icon;
            // the drag carries the same picture rather than a second one.
            image: thumbnail,
            onBegin: { tray.beganDragOut() },
            onOpen: { tray.open(item) },
            onEnd: { operation in tray.finishedDragOut(item, operation: operation) })
            // Said out loud rather than inherited: an `NSView` with no intrinsic
            // size is at the mercy of whatever SwiftUI proposes, and a drag
            // layer laid out at zero is a tile that cannot be dragged at all.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tap gesture, not a `Button`: a button takes the mouse-down, and this
    /// tile is a drag source, so pressing here and moving has to still start the
    /// drag. A tap only resolves once the pointer has stayed put — the same
    /// reason double-click-to-open can sit alongside a drag.
    ///
    /// Unlabelled on purpose: the tile is one accessibility element, so this is
    /// invisible to VoiceOver and the named `Remove` action above is its way in.
    private var removeAffordance: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12))
            .symbolRenderingMode(.palette)
            // Two layers, because the glyph sits over a thumbnail of anything at
            // all — a white x on a white document is not there.
            .foregroundStyle(Theme.textPrimary, Color.black.opacity(0.55))
            // 20×20 is the macOS minimum control size; the glyph stays 12pt.
            // The constant is the drag layer's, because that layer has to carve
            // this exact square out of its own hit test and two transcriptions
            // of "20" is how the x quietly stops being clickable.
            .frame(width: TrayDragOutLayer.removeAffordanceSide,
                   height: TrayDragOutLayer.removeAffordanceSide)
            .contentShape(.rect)
            // Where the click landed, not just that one did: `TrayRemoveGate`
            // refuses a second removal at the same spot inside the double-click
            // interval, which is the only way one gesture can trash two files.
            .onTapGesture(coordinateSpace: .global) { point in
                guard TrayRemoveGate.allowsRemoval(at: point) else { return }
                tray.remove(item)
            }
            .clickable()
            .help("Remove — moves it to the Trash")
    }

    /// Folders skip QuickLook entirely — it renders them as a blank page, which
    /// is exactly what a folder is not. Everything else tries for a real preview
    /// and falls back to the file's own system icon, so a PDF looks like a PDF
    /// and an unknown type looks like whatever Finder would show, rather than
    /// every non-previewable item collapsing into one generic glyph.
    private func loadThumbnail() async {
        if !item.isDirectory {
            let request = QLThumbnailGenerator.Request(
                fileAt: item.url, size: CGSize(width: 128, height: 112),
                scale: 2, representationTypes: .thumbnail)
            if let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = generated.nsImage
                isIcon = false
                return
            }
        }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 64, height: 64)
        thumbnail = icon
        isIcon = true
    }
}

/// The one thing SwiftUI cannot do: start a drag and then be told how it ended.
///
/// `.onDrag` hands back an `NSItemProvider` and stops talking. There is no
/// completion, no operation, no distinction between a file filed into a folder
/// and a drag let go of over the desktop — and a shelf item is a real file in
/// `~/Airlock/tray`, so "remove the tile" and "delete the file" are the same
/// sentence. Approximating the answer with a timer, or with "the pointer left
/// the panel", would delete files on a hunch.
///
/// `NSDraggingSource` is the supported way to ask. It reports the operation the
/// DESTINATION chose, once the drag has resolved; `TrayDragOutcome.decide`
/// turns that into keep-or-trash, and refuses to remove on anything less than
/// an unambiguous `.move`. The pasteboard contents are unchanged from what
/// `.onDrag` wrote — one `NSURL`, `public.file-url` — so every destination that
/// accepted a shelf item before still does. A file promise would have been the
/// other way to get a trustworthy answer, and it was not taken: it would have
/// swapped the file URL for a promise type that plenty of destinations decline
/// outright, breaking real drags to buy proof for the ones that remain.
private struct TrayTileDragSource: NSViewRepresentable {
    let url: URL
    let image: NSImage?
    let onBegin: () -> Void
    let onOpen: () -> Void
    let onEnd: (TrayDragOperation) -> Void

    func makeNSView(context: Context) -> TrayDragOutLayer {
        let layer = TrayDragOutLayer()
        apply(to: layer)
        return layer
    }

    func updateNSView(_ layer: TrayDragOutLayer, context: Context) {
        apply(to: layer)
    }

    /// Updated in place rather than rebuilt: the view is the drag source for as
    /// long as a session lasts, and a session outlives any number of re-renders
    /// of the tile it started from.
    private func apply(to layer: TrayDragOutLayer) {
        layer.url = url
        layer.image = image
        layer.onBegin = onBegin
        layer.onOpen = onOpen
        layer.onEnd = onEnd
    }
}

/// The AppKit half. It is deliberately the smallest thing that can own a drag:
/// no drawing, no state of its own beyond the press it is waiting to see turn
/// into a drag.
final class TrayDragOutLayer: NSView, NSDraggingSource {
    /// Shared with the SwiftUI x this layer has to let through.
    static let removeAffordanceSide: CGFloat = 20
    /// Far enough that a shaky click is not a drag, close enough that a
    /// deliberate one starts where the pointer expects it to.
    private static let dragThreshold: CGFloat = 3
    /// Matches the preview `.onDrag` used to carry.
    private static let previewSide: CGFloat = 64

    var url: URL?
    var image: NSImage?
    var onBegin: () -> Void = {}
    var onOpen: () -> Void = {}
    var onEnd: (TrayDragOperation) -> Void = { _ in }

    /// The mouse-down that has not yet become a drag or a click.
    private var press: NSEvent?

    /// This layer covers the whole tile, so what it does NOT take is the whole
    /// design.
    ///
    /// It answers only for the left mouse-down that could begin a drag.
    /// Everything else — hover tracking, the tooltip, the right-click that opens
    /// the context menu — hit-tests through to the SwiftUI content underneath,
    /// which is what keeps `onHover`, `.help` and `.contextMenu` working exactly
    /// as they did. `NSApp.currentEvent` is the event being dispatched right
    /// now, which is what makes the question answerable at all.
    ///
    /// The remove x is carved out for the same reason: it is a SwiftUI view
    /// below this one, and a press it never receives is a button that does
    /// nothing. It is only visible while the pointer is on the tile — which is
    /// every press — so the square is excluded unconditionally rather than
    /// tracking a hover flag that would have to be right at exactly the wrong
    /// moment.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), !removeAffordanceRect.contains(local) else { return nil }
        return self
    }

    private var removeAffordanceRect: NSRect {
        NSRect(x: bounds.maxX - Self.removeAffordanceSide,
               y: bounds.maxY - Self.removeAffordanceSide,
               width: Self.removeAffordanceSide, height: Self.removeAffordanceSide)
    }

    override func mouseDown(with event: NSEvent) {
        press = event
    }

    /// Once this view has taken the mouse-down, AppKit routes the rest of the
    /// gesture here without hit-testing again — so the drag threshold is
    /// measured against the press, not against the last move.
    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let dx = event.locationInWindow.x - press.locationInWindow.x
        let dy = event.locationInWindow.y - press.locationInWindow.y
        guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return }
        self.press = nil
        beginDrag(from: press)
    }

    /// A press that never moved. Two of them in a row is the gesture that opens
    /// the file in Finder, so it is the gesture that opens it here.
    override func mouseUp(with event: NSEvent) {
        press = nil
        guard event.clickCount == 2 else { return }
        onOpen()
    }

    private func beginDrag(from event: NSEvent) {
        guard let url else { return }
        let preview = image ?? NSWorkspace.shared.icon(forFile: url.path)
        let dragged = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragged.setDraggingFrame(previewFrame(around: convert(event.locationInWindow, from: nil),
                                              for: preview),
                                 contents: preview)
        let session = beginDraggingSession(with: [dragged], event: event, source: self)
        // A drag that comes to nothing flies back to the tile, which is now the
        // truthful animation: the file is still there.
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Aspect-fit, because a tile's thumbnail is whatever shape the file is and
    /// `setDraggingFrame` stretches to whatever it is given.
    private func previewFrame(around point: NSPoint, for image: NSImage) -> NSRect {
        let size = image.size
        let scale = size.width > 0 && size.height > 0
            ? min(Self.previewSide / size.width, Self.previewSide / size.height)
            : 1
        let fitted = NSSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        return NSRect(x: point.x - fitted.width / 2, y: point.y - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    // MARK: - NSDraggingSource

    /// What this drag is allowed to become, and it is the same list Finder
    /// offers for a file of its own.
    ///
    /// Only `.move` can empty the shelf. The rest are advertised because a
    /// destination can only choose from what the source permits: strip them and
    /// everything that can merely copy — Mail attaching, a folder on another
    /// volume, an editor taking a path — would refuse the drop outright. That
    /// would trade drags that work today for a removal that happens more often,
    /// which is the wrong way round.
    ///
    /// `ignoreModifierKeysForDraggingSession` is deliberately not implemented,
    /// so it stays false and AppKit narrows this mask by the modifier keys the
    /// way it does everywhere else on the system. Option-drag therefore reports
    /// `.copy`, and a `.copy` never removes anything — which is exactly the
    /// escape hatch Option is for, on the way out as well as on the way in.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication:
            // The AirDrop box is the only destination inside this app, and its
            // own tooltip promises the original stays where it is. The catcher
            // decides what to answer by reading THIS mask, so offering `.move`
            // here would have it answer `.move`, and a file would go to the
            // Trash for the crime of having been sent to a phone.
            return .copy
        default:
            return [.copy, .move, .link, .generic, .delete]
        }
    }

    /// The side effect the shelf needs, raised here rather than at the call that
    /// started the session. `onBegin` flips observable state the tray reads, and
    /// a view rebuilt underneath a drag that has not fully begun is what used to
    /// make AppKit abandon the first drag out of every session. By this message
    /// the session owns its own snapshot of the tile and no longer cares.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onBegin()
    }

    /// The answer this whole file exists to hear.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onEnd(TrayDragOperation(rawValue: operation.rawValue))
    }
}

/// A tile for a file still on its way in. The file work runs off the main actor
/// now, so without this the shelf sits unchanged for however long a large file
/// takes and the drop reads as having missed.
///
/// It says "adding" rather than "moving" or "copying" on purpose: which of the
/// two this is can still change while the tile is on screen, because a move a
/// read-only source refuses falls back to a copy.
private struct TrayIngestingTileView: View {
    let name: String

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(height: 56)
                .overlay { WaitingIndicator(words: "Adding \(name)…", dotsOnly: true) }

            // The real tile's two lines, in the real tile's frame: with the
            // name alone it was shorter, and the grid centred it lower than the
            // tiles beside it.
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.middle)
                Text(TrayTileDetails.arrivingSubtitle)
                    .font(Theme.chrome(9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help("Adding \(name)…")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), adding")
    }
}

private struct ShelfHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TrayRailKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}
