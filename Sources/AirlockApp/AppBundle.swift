import Foundation

/// Whether this process was launched from a real `.app` bundle.
///
/// `swift run` starts a bare executable out of `.build`, and some system
/// services have nothing to attach to without a bundle. Most of them fail
/// quietly: launchd has nothing to register, Sparkle nothing to update, and a
/// permission request is credited to whatever launched the process rather than
/// to Airlock. `UNUserNotificationCenter.current()` does not — it raises, and
/// the process dies. That is how the documented demo command,
/// `AIRLOCK_DEMO=1 swift run AirlockApp`, came to crash at launch; see
/// `Notifications.center()`.
///
/// **One definition.** The same expression had been copied into five places,
/// and the two call sites that needed it most had no copy at all. Anything
/// that needs a bundle asks here, so the next one gets the same answer.
enum AppBundle {
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}
