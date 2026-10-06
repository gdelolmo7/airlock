import AppKit
import AirlockCore

/// What to call an app, given its bundle identifier.
///
/// Lives in the app layer because the first and best answer comes from
/// LaunchServices, which `AirlockCore` deliberately cannot see. The rest of the
/// answer — our own names, and the readable guess — is in `AppDisplayName`,
/// where it can be tested.
enum AppName {
    static func of(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            // Display name first: it is the one the Finder shows, and the two
            // differ for exactly the apps people rename in their heads.
            let installed = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if !installed.isEmpty { return installed }
        }
        return AppDisplayName.known[bundleID] ?? AppDisplayName.readable(bundleID)
    }
}
