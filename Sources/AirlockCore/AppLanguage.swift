import Foundation

/// Which language Airlock speaks: English or Spanish, chosen once at launch.
///
/// By default it follows the Mac, and only the Mac's FIRST language counts.
/// macOS on its own would pick Spanish for someone whose list reads French,
/// Spanish, English, because Spanish is the first one Airlock has. The owner's
/// rule is plainer (2026-10-22): Spanish if the Mac is in Spanish, otherwise
/// English. Settings can pin either one.
///
/// The choice is applied by putting `AppleLanguages` in the app's argument
/// domain before anything reads a string, which is the same thing a
/// `-AppleLanguages (es)` launch argument does. It is never written to disk,
/// so a later change to the Mac's own list is followed on the next launch.
/// Changing it while running needs a relaunch: bundles settle their language
/// on first use.
public enum AppLanguage: String, CaseIterable, Sendable {
    case automatic
    case english
    case spanish

    /// The settings key. Holds a raw value; missing means automatic.
    public static let defaultsKey = "app.language"

    /// The languages the bundle carries, base first.
    public static let available = ["en", "es"]

    public init(storedValue: String?) {
        self = storedValue.flatMap(AppLanguage.init(rawValue:)) ?? .automatic
    }

    /// The bundle language this choice comes to, given the Mac's own list of
    /// preferred languages (most preferred first).
    public func resolved(macLanguages: [String]) -> String {
        switch self {
        case .english: return "en"
        case .spanish: return "es"
        case .automatic:
            let first = macLanguages.first?.lowercased() ?? "en"
            return first == "es" || first.hasPrefix("es-") || first.hasPrefix("es_") ? "es" : "en"
        }
    }

    /// The Mac's own list, read from the global domain so neither the app's
    /// domain nor an earlier launch's choice can colour it.
    public static func macLanguages() -> [String] {
        CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
            ?? Locale.preferredLanguages
    }

    /// Sets the language for this run. Call first thing at launch.
    ///
    /// A launch that already names `AppleLanguages` on its command line keeps
    /// it: that is someone checking a language on purpose.
    @discardableResult
    public static func apply(defaults: UserDefaults = .standard) -> String {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if let named = arguments["AppleLanguages"] as? [String], let first = named.first {
            return first
        }
        let language = AppLanguage(storedValue: defaults.string(forKey: defaultsKey))
            .resolved(macLanguages: macLanguages())
        arguments["AppleLanguages"] = [language]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        return language
    }
}
