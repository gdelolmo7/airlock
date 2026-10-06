import AirlockCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The open panel's drop target — the SwiftUI half of "a drag gets the same
/// answer wherever on the notch it lands".
///
/// `NotchDropCatcher` owns the cutout and admits
/// `TrayDropKind.watchedTypeIdentifiers`; this owns the panel and admits the
/// same identifiers, from the same constant. The two used to disagree: the
/// panel declared `public.file-url` alone, so a text selection, an image
/// dragged out of a browser or a Mail attachment dropped on the OPEN panel did
/// nothing whatsoever, while the identical drag onto the cutout was kept or
/// refused with a reason. Which pixels you hit decided whether the app existed.
///
/// A plain `.onDrop(of:isTargeted:perform:)` cannot do this job, which is why
/// this is a delegate. Two things are only knowable while the drag is still in
/// flight: what is being dragged, which is what the refusal message is made of
/// (`settleAfterDrag` clears the message the instant a drop resolves, so saying
/// it afterwards says it to nobody), and whether to promise a move or a copy.
///
/// It is the panel's ONLY drop target. The shelf used to carry a second one of
/// its own, which meant two targets with two type lists and a highlight that
/// depended on which of them the pointer was over; the shelf now lights up from
/// `uiState.isDropTargeted`, the same flag the catcher already drove.
@MainActor
struct TrayPanelDropTarget: DropDelegate {
    let tray: TrayModel
    let uiState: NotchUIState
    /// Runs once the drop has been handed off — the panel switches to the tray
    /// so you can see where the thing went, and releases the drag pin.
    let onSettled: () -> Void

    /// What SwiftUI is told to offer us. `compactMap` rather than force-mapped:
    /// an identifier the system does not know is a list entry to fix, not a
    /// crash on launch.
    static let contentTypes: [UTType] =
        TrayDropKind.watchedTypeIdentifiers.compactMap(UTType.init(_:))

    /// True even for a drag the tray cannot keep. Refusing here would skip
    /// `dropEntered`, and the refusal would then have nowhere to be said —
    /// `dropUpdated` is where the cursor is told no.
    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        uiState.isDropTargeted = !uiState.isDraggingOut
        uiState.dropRejection = kind(of: info).flatMap { $0.isSupported ? nil : $0.explanation }
        if !uiState.isDraggingOut {
            Moments.shared.announce(uiState.dropRejection == nil ? .fileOver : .dropRefused, "over the panel")
        }
    }

    func dropExited(info: DropInfo) {
        uiState.isDropTargeted = false
        uiState.dropRejection = nil
    }

    /// What the cursor promises, and it has to be what actually happens.
    ///
    /// It is NOT the same answer as `DropCatcherView.operation(for:kind:)`, and
    /// claiming it was is what made this wrong. The catcher can read
    /// `draggingSourceOperationMask` and so may promise a move; `DropInfo`
    /// exposes no mask, so this seam badges every file drop `.copy` and copies
    /// — see `TrayModel.gestureFromPanelDrop`. Same rule
    /// (`TrayIngestGesture.fromPointerDrag`), different evidence, and the badge
    /// is computed from the very call that decides the file's fate so the two
    /// cannot drift again.
    ///
    /// Pixels off a web page are `.copy` for a second reason: there is no
    /// original to take. An unclassifiable drag proposes `.copy` rather than
    /// `.forbidden`, because a wrong "no" is unrecoverable — `performDrop`
    /// classifies again with the providers definitely in hand, and refuses
    /// there if it must.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let kind = kind(of: info) else { return DropProposal(operation: .copy) }
        guard kind.isSupported else { return DropProposal(operation: .forbidden) }
        guard kind == .files else { return DropProposal(operation: .copy) }
        return DropProposal(operation:
            TrayModel.gestureFromPanelDrop() == .drag(allowsMove: true) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        uiState.selectedTab = .tray
        let accepted = tray.accept(providers: info.itemProviders(for: Self.contentTypes),
                                   gesture: TrayModel.gestureFromPanelDrop())
        Moments.shared.announce(accepted ? .fileDropped : .dropRefused, "on drop")
        onSettled()
        return accepted
    }

    /// Nil means "not answerable yet", which is a different thing from
    /// `.unknown` and must not be shown as a refusal. `registeredTypeIdentifiers`
    /// is everything a provider vends rather than only what we asked for, so
    /// this sees the same full flavour list the pasteboard shows the catcher —
    /// a jpeg admitted on the strength of the page URL beside it still reads as
    /// an image, exactly as it does over the cutout.
    private func kind(of info: DropInfo) -> TrayDropKind? {
        let identifiers = info.itemProviders(for: Self.contentTypes)
            .flatMap(\.registeredTypeIdentifiers)
        guard !identifiers.isEmpty else { return nil }
        return TrayDropKind.classify(typeIdentifiers: identifiers)
    }
}
