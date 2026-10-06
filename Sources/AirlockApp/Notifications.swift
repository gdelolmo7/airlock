import AirlockCore
import UserNotifications

/// The one channel that survives Airlock not being frontmost.
///
/// **Why this exists.** Dictation types into OTHER apps, so when it fails the
/// panel reporting it is by construction the surface the user is not looking
/// at. A transcript can be recovered from the clipboard; knowing it happened
/// cannot be recovered from anywhere. Fifteen words once went missing with no
/// visible trace, and the status line saying why was on screen the whole time —
/// in the notch, behind the window being typed into.
///
/// **Authorization is asked for at the moment it is first needed, never at
/// launch.** That is the same rule the microphone follows, and for the same
/// reason recorded there: a prompt at launch is the one people deny reflexively.
/// A dictation that just failed is an explicit user action that earns the ask.
///
/// **Nothing the user said ever goes in a notification.** The transcript is
/// theirs and may be anything; the body says where it went, not what it was.
enum Notifications {
    /// The notification center, or nil in a process with no app bundle.
    ///
    /// **Everything that touches the center gets it here.** Without a bundle,
    /// `UNUserNotificationCenter.current()` raises an Objective-C exception,
    /// and nothing can catch it: the raise happens inside `dispatch_once`, and
    /// libdispatch ends the process when an exception escapes one of its
    /// callouts. `ALExceptionCatcher` on the stack makes no difference — tried.
    /// That is how `AIRLOCK_DEMO=1 swift run AirlockApp` died at launch from
    /// 2eaa587 on: the delegate was set on every launch, and `swift run` has no
    /// bundle.
    ///
    /// Such a run simply has no notifications — there is nowhere for one to
    /// come from, and nothing for a click on it to open. A test keeps this the
    /// only caller of `current()`, so the next notification cannot reintroduce
    /// the crash by asking directly.
    static func center() -> UNUserNotificationCenter? {
        AppBundle.isBundled ? UNUserNotificationCenter.current() : nil
    }

    /// Post, asking for permission first if it has never been asked.
    ///
    /// Silent on refusal by design: somebody who declined notifications has
    /// said what they want, and a fallback nag would be worse than the silence
    /// this was written to fix.
    ///
    /// - Parameter opens: where clicking it lands. **Required, with no default**
    ///   — a notification that reports a problem and then drops you nowhere is
    ///   half a feature, and a default would let the next one inherit a
    ///   destination nobody chose for it.
    static func post(title: String, body: String, identifier: String,
                     opens pane: SettingsPane) {
        post(title: title, body: body, identifier: identifier, userInfo: [Key.pane: pane.rawValue])
    }

    /// The same, landing on the exact row rather than just its page — see
    /// `SettingsAnchor`.
    static func post(title: String, body: String, identifier: String,
                     opens anchor: SettingsAnchor) {
        post(title: title, body: body, identifier: identifier,
             userInfo: [Key.pane: anchor.pane.rawValue, Key.anchor: anchor.rawValue])
    }

    private static func post(title: String, body: String, identifier: String,
                             userInfo: [String: String]) {
        Task {
            // Fetched inside the task rather than held as a static: under Swift
            // 6 a non-Sendable singleton in a global is a compile error, and
            // `center()` is cheap.
            guard let center = Self.center() else { return }
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                guard let granted = try? await center.requestAuthorization(options: [.alert]),
                      granted else { return }
            case .denied:
                return
            default:
                break
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Carried on the notification rather than looked up from the
            // identifier, so the destination travels with the message. A table
            // mapping identifiers to panes elsewhere is a table that goes stale
            // the first time somebody adds a notification and forgets it.
            content.userInfo = userInfo
            // A stable identifier per KIND, so ten failed dictations leave one
            // notification rather than ten. The newest replaces the last.
            try? await center.add(UNNotificationRequest(identifier: identifier,
                                                       content: content,
                                                       trigger: nil))
        }
    }

    enum Key {
        static let pane = "airlock.pane"
        static let anchor = "airlock.anchor"
    }

    /// Identifiers, so a repeat of the same problem replaces rather than stacks.
    enum ID {
        static let accessibilityMissing = "dictation.accessibility"
        /// The hold key is dead. Distinct from the one above because it is a
        /// distinct permission with a distinct pane, and collapsing the two is
        /// exactly the mistake that made this failure unfindable.
        static let inputMonitoringMissing = "dictation.inputMonitoring"
    }

    /// Opens the settings window at a pane. Set once, at launch, by
    /// `AppDelegate` — the router below has no way to reach the window
    /// controller otherwise, and a notification arriving before this is set is
    /// simply ignored rather than crashing on a force-unwrap.
    @MainActor static var openSettings: ((SettingsPane, SettingsAnchor?) -> Void)?
}

/// Makes a notification clickable.
///
/// **Without a delegate, clicking one does nothing at all** — macOS activates
/// the app and that is the end of it, which for an `LSUIElement` agent with no
/// windows means the notification visibly leads nowhere. Every notification this
/// app posts is about something the user has to go and fix, so landing them on
/// the pane that fixes it is most of the value; telling somebody their hold key
/// is dead and then making them find the setting themselves is the same failure
/// one step later.
///
/// `NSObject` and not `@MainActor`: the protocol is imported unisolated, so the
/// callbacks arrive off the main actor and hop explicitly.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// A click. `UNNotificationDefaultActionIdentifier` is the notification
    /// body itself — a dismiss must not open a window, which is why this is
    /// matched rather than assumed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        // Read to a String before hopping: `UNNotificationResponse` is a
        // reference type and not Sendable, so it must not cross the boundary.
        let info = response.notification.request.content.userInfo
        let raw = info[Notifications.Key.pane] as? String
        let anchor = info[Notifications.Key.anchor] as? String
        await MainActor.run {
            Notifications.openSettings?(raw.flatMap(SettingsPane.init(rawValue:)) ?? .permissions,
                                        anchor.flatMap(SettingsAnchor.init(rawValue:)))
        }
    }

    /// Show it even when Airlock is the active app.
    ///
    /// The default is to suppress notifications for a frontmost app, on the
    /// reasoning that you can already see it. That reasoning does not hold here:
    /// "frontmost" for this app means the settings window is open, which is a
    /// different surface from the notch the message would otherwise appear in —
    /// and the dictation failures these report happen while you are typing into
    /// something else entirely.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
