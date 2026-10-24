import AirlockCore
import AppKit
import SwiftUI

/// Which language Airlock speaks: the Mac's, or English or Spanish whatever
/// the Mac says. See `AppLanguage` for the rule.
///
/// The words on screen settle when Airlock starts, so a change waits for a
/// restart, and the row offers one.
struct LanguageRow: View {
    @AppStorage(AppLanguage.defaultsKey) private var stored: String?

    private var choice: Binding<AppLanguage> {
        Binding(get: { AppLanguage(storedValue: stored) },
                set: { stored = $0 == .automatic ? nil : $0.rawValue })
    }

    /// What this run is showing, against what the next one would.
    private var needsRestart: Bool {
        let running = Bundle.main.preferredLocalizations.first ?? "en"
        return choice.wrappedValue.resolved(macLanguages: AppLanguage.macLanguages()) != running
    }

    var body: some View {
        LookRow("Language", subtitle: Self.subtitle) {
            LookMenu(Self.name(choice.wrappedValue)) {
                Picker("Language", selection: choice) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(Self.name(language)).tag(language)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .settingsAnchor(.appLanguage)
        if needsRestart {
            ProblemCard(icon: "arrow.clockwise", sentence: String(localized: "Restart Airlock to see the new language."),
                        tone: .note, button: String(localized: "Restart")) {
                Self.restart()
            }
        }
    }

    /// What "Automatic" means, said once, so nobody has to guess.
    private static var subtitle: String {
        String(localized: "Automatic follows your Mac: Spanish if your Mac is in Spanish, English otherwise.")
    }

    /// "English" and "Español" are written in their own language, so either
    /// can be found by someone who can't read the other.
    static func name(_ language: AppLanguage) -> String {
        switch language {
        case .automatic: String(localized: "Automatic")
        case .english: "English"
        case .spanish: "Español"
        }
    }

    /// Opens a fresh copy once this one has gone, then quits. A quit that is
    /// called off (a call still taking notes) leaves the waiter to give up
    /// after half a minute instead of reopening Airlock at some later quit.
    private static func restart() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "for _ in $(/usr/bin/jot 150); do /bin/kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$0\"; /bin/sleep 0.2; done",
                              Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
