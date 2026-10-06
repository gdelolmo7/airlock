import AppKit
import AirlockCore

/// The page of System Settings → Privacy & Security a problem card's button
/// opens.
///
/// Automation is here and not in `PermissionKind` because it has no Fix:
/// it is granted per app being controlled (Spotify, Music, System Events), so
/// there is no single record to clear. Everything else reuses
/// `PermissionKind`'s anchors, so a page is named in one place.
enum PermissionPage: Equatable {
    /// Controlling another app: Spotify and Music for the media card, System
    /// Events for the appearance.
    case automation
    case permission(PermissionKind)

    /// What a button that opens one of these says. "System Settings" in full:
    /// in the notch, "Settings" alone reads as Airlock's own.
    static let button = "Open System Settings"

    var url: URL? {
        switch self {
        case .automation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .permission(let kind):
            kind.settingsURL
        }
    }

    @MainActor
    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
