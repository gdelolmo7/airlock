import Foundation

/// What someone just dragged at the notch, judged from the pasteboard's type
/// identifiers alone — pure, so the rules are testable without a drag session.
///
/// The tray holds real files, so anything that isn't a file has to be turned
/// away. The point of naming the kind is that "nothing happened" is a terrible
/// answer: dragging an image out of a web page feels exactly like dragging an
/// image, and the person doing it deserves to be told it arrived as a link or as
/// raw pixels rather than a file.
public enum TrayDropKind: Equatable, Sendable {
    case files
    case webLink
    case imageData
    case text
    case unknown(String)

    public var isSupported: Bool {
        switch self {
        case .files, .imageData: return true
        case .webLink, .text, .unknown: return false
        }
    }

    /// Shown in the panel when the drop is refused. Says what arrived and what
    /// to do instead — a bare "unsupported" leaves you stuck.
    public var explanation: String {
        switch self {
        case .files, .imageData:
            return ""
        case .webLink:
            return "That's a link with no image behind it. Drag the picture itself, or save it first."
        case .text:
            return "That's text, not a file. The Shelf holds files."
        case .unknown:
            // The identifier is for classification and the log, never the
            // sentence: "com.apple.mail.PasteboardTypeMessageTransfer isn't a
            // file" names something nobody has heard of. What to do instead is
            // the same for every kind of thing we do not know.
            return Self.unknownExplanation
        }
    }

    /// What anything unrecognised is told, whatever it was.
    public static let unknownExplanation =
        "That isn't a file, so the Shelf can't hold it. Drag the file from Finder instead."

    /// Every drag flavour the notch listens for, and the ONE place the list is
    /// written down. Both drop surfaces read it: the AppKit catcher over the
    /// cutout registers these as dragged types, and the open panel declares the
    /// same identifiers as its content types.
    ///
    /// They used to disagree. The panel took `public.file-url` alone, so a text
    /// selection, an image dragged out of a browser or a Mail attachment landed
    /// on the open panel and did nothing at all — no tile, no refusal, no
    /// cursor — while the identical drag onto the cutout was either kept or
    /// explained. Which pixels the drag happened to land on decided whether the
    /// app responded, which is indistinguishable from it being broken.
    ///
    /// Deliberately WIDER than what `isSupported` keeps. A flavour we never
    /// admit is a drag that falls straight through to whatever is behind the
    /// notch while the notch sits there ignoring it; admitting it costs nothing
    /// and buys the chance to say why it can't stay. Everything here that is
    /// not `.files` or `.imageData` exists purely to be refused out loud, and
    /// `TrayDropKindTests` holds each one to having something to say.
    ///
    /// Note what these gate and what they don't: on both paths this decides
    /// only whether the drag is OFFERED to us. Classification then reads
    /// everything the drag actually carries — a jpeg with no `public.jpeg` in
    /// this list still classifies as `.imageData` once it is admitted on the
    /// strength of the page URL beside it.
    public static let watchedTypeIdentifiers: [String] = [
        "public.file-url", "public.url", "public.png", "public.tiff",
        "com.adobe.pdf", "public.html", "public.rtf", "public.utf8-plain-text",
    ]

    /// Order matters, and image data must outrank the link. A drag out of a web
    /// page advertises BOTH — the page URL and the actual pixels — so checking
    /// the URL first made every genuine jpg or png from a browser read as a bare
    /// link and get refused, when the image was sitting right there on the
    /// pasteboard the whole time.
    ///
    /// A Finder drag likewise advertises a file URL alongside other flavours, so
    /// files stay first: a real file on disk beats a copy of its pixels.
    public static func classify(typeIdentifiers: [String]) -> TrayDropKind {
        if typeIdentifiers.contains("public.file-url") { return .files }
        if typeIdentifiers.contains(where: isImage) { return .imageData }
        if typeIdentifiers.contains(where: { $0 == "public.url" || $0 == "public.url-name" }) { return .webLink }
        if typeIdentifiers.contains(where: isText) { return .text }
        return .unknown(typeIdentifiers.first ?? "That")
    }

    private static func isImage(_ identifier: String) -> Bool {
        let known = ["public.image", "public.png", "public.jpeg", "public.tiff",
                     "public.heic", "com.compuserve.gif", "org.webmproject.webp",
                     "com.google.webp", "public.webp"]
        return known.contains(identifier) || identifier.hasSuffix(".webp")
    }

    private static func isText(_ identifier: String) -> Bool {
        let known = ["public.utf8-plain-text", "public.plain-text", "public.text",
                     "public.html", "public.rtf", "NSStringPboardType"]
        return known.contains(identifier)
    }
}
