import Foundation

/// The Apple Intelligence row in first-run setup: what it says and whether it
/// offers a way to fix it.
///
/// It writes call notes on the Mac, and on Free that is the only way they get
/// written, so the time to find out it is off is during setup, not after the
/// first call comes back with a transcript and no notes.
///
/// **Apple has no separate reason for a Mac whose language or region is not
/// supported yet.** Such a Mac reports Apple Intelligence as switched off, and
/// System Settings then has no switch to offer. So the switched-off line says
/// what to do when the switch is not there, rather than sending somebody to
/// look for something that does not exist.
public struct AppleIntelligenceSetup: Equatable, Sendable {
    /// A short word after the name, in the warning colour. Nil when on.
    public let tag: String?
    public let detail: String
    /// The row's button, when there is something the person can do.
    public let button: Button?
    /// Drawn ticked, like a granted permission.
    public let isOn: Bool

    public enum Button: Equatable, Sendable {
        /// Apple Intelligence & Siri in System Settings.
        case openSystemSettings

        public var title: String {
            switch self {
            case .openSystemSettings: String(localized: "Open System Settings")
            }
        }

        /// Apple Intelligence & Siri, the pane with the switch.
        public var url: URL? {
            switch self {
            case .openSystemSettings: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
            }
        }
    }

    /// What the notes are, said once so each line can lead with it.
    public static let purpose = String(localized: "Writes your call notes and to-dos on this Mac.")

    public static func row(_ availability: ModelAvailability) -> AppleIntelligenceSetup {
        switch availability {
        case .ready:
            return AppleIntelligenceSetup(tag: nil, detail: String(localized: "On. \(purpose)"), button: nil, isOn: true)
        case .needsAppleIntelligence:
            return AppleIntelligenceSetup(
                tag: String(localized: "switched off"),
                detail: String(localized: "\(purpose) Turn it on in System Settings. If it isn't there, your Mac's language or region doesn't have it yet."),
                button: .openSystemSettings, isOn: false)
        case .deviceNotEligible:
            return AppleIntelligenceSetup(
                tag: String(localized: "not on this Mac"),
                detail: String(localized: "This Mac can't run it. On Free, calls get a transcript but no notes. Plus writes notes online on any Mac."),
                button: nil, isOn: false)
        case .modelNotReady:
            return AppleIntelligenceSetup(
                tag: String(localized: "downloading"),
                detail: String(localized: "\(purpose) macOS is still downloading it, and call notes work once it finishes."),
                button: nil, isOn: false)
        case .unknown:
            // A reason this build doesn't know: say what it is for and where
            // it lives, without guessing what is wrong.
            return AppleIntelligenceSetup(
                tag: nil,
                detail: String(localized: "\(purpose) It's in System Settings, under Apple Intelligence & Siri."),
                button: .openSystemSettings, isOn: false)
        }
    }
}
