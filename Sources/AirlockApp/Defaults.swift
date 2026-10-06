import Foundation

/// Typed reads and writes against `UserDefaults`.
///
/// One copy, module-wide. This started as a `private enum` next to whichever
/// model needed it and had been duplicated twice by the time a third feature
/// wanted it — with the copies already diverging (one had `string`, the other
/// `bool` and `int`, both had identical `binding` codecs). A settings helper is
/// exactly the kind of thing that should not have two definitions.
///
/// `object(forKey:) as? Bool` rather than `bool(forKey:)` throughout: the
/// convenience accessors return `false`/`0` for a missing key, which makes a
/// default of `true` impossible to express.
enum Defaults {
    static func string(_ key: String, default fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static func int(_ key: String, default fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    static func set(_ value: some Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Empty rather than nil for an unset key: every caller wants a list to
    /// append to, and none of them can tell "never set" from "emptied" apart —
    /// or would do anything different if they could.
    static func stringArray(_ key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func setStringArray(_ value: [String], _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func binding(_ key: String, default fallback: GlobalHotkey.Binding) -> GlobalHotkey.Binding {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(GlobalHotkey.Binding.self, from: data)
        else { return fallback }
        return value
    }

    static func setBinding(_ value: GlobalHotkey.Binding, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
