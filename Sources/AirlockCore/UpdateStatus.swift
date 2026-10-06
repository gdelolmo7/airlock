import Foundation

/// What Settings › General says about updates, beyond "Last checked".
///
/// Sparkle draws its own windows for the moments that need a decision — an
/// update is available, it is ready to install. What it never draws is the
/// quiet in between: a check that could not get through, an update waiting for
/// the app to quit, or an updater that never started. Settings showed none of
/// those, and the last one left "Check Now" greyed out with no reason at all.
///
/// Pure, so the wording and the mapping from Sparkle's outcomes are tested
/// without Sparkle. Sparkle's error codes arrive as plain numbers for the same
/// reason (`SUErrors.h`).
public enum UpdateStatus: Equatable, Sendable {
    /// Nothing worth a sentence.
    case quiet
    /// The last check did not get through — offline, or the update server was
    /// unreachable. Sparkle tries again on its own schedule.
    case lastCheckFailed
    /// Running from the disk image, or from a copy macOS has moved aside, so
    /// an update would have nowhere to go.
    case needsMoving
    /// Downloaded and verified; it goes in when Airlock quits.
    case readyOnQuit(version: String)
    /// The updater refused to start. Never fatal, but nothing will arrive.
    case didNotStart

    /// What a finished update cycle leaves behind.
    ///
    /// - Parameters:
    ///   - errorCode: Sparkle's error code, or nil for a cycle that ended
    ///     normally (an update dismissed or skipped is also nil).
    ///   - previous: what was already showing. A downloaded update stays the
    ///     news until the app quits — a later "no update found" does not
    ///     unmake it.
    public static func after(errorCode: Int?, previous: UpdateStatus) -> UpdateStatus {
        if case .readyOnQuit = previous { return previous }
        guard let errorCode else { return .quiet }
        switch errorCode {
        case noUpdate, installationCanceled, installationAuthorizeLater:
            // Not failures: nothing new, or the person said "not now".
            return .quiet
        case runningFromDiskImage, runningTranslocated:
            return .needsMoving
        default:
            return .lastCheckFailed
        }
    }

    /// The line under the Updates switch, or nil for none.
    ///
    /// `canCheck` is whether Check Now can be pressed. When it can't, the line
    /// says why — that is the half that was missing.
    public static func line(_ status: UpdateStatus, canCheck: Bool) -> String? {
        switch status {
        case .didNotStart:
            return "Updates couldn't start in this copy of Airlock. New versions are at useairlock.app."
        case .readyOnQuit(let version):
            let name = version.isEmpty ? "A new version of Airlock" : "Airlock \(version)"
            return "\(name) is downloaded and installs when you quit Airlock."
        case .needsMoving:
            return "Move Airlock to your Applications folder to get updates."
        case .quiet, .lastCheckFailed:
            // A check under way outranks how the last one went.
            if !canCheck { return "Checking for updates…" }
            return status == .lastCheckFailed
                ? "The last check didn't get through. Airlock tries again on its own."
                : nil
        }
    }

    // MARK: - Sparkle's codes (SUErrors.h)

    static let noUpdate = 1001
    static let runningFromDiskImage = 1003
    static let runningTranslocated = 1005
    static let installationCanceled = 4007
    static let installationAuthorizeLater = 4008
}
