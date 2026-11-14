import AppKit
import AirlockCore

/// Where "Words to know" is kept, for dictation and calls alike.
///
/// The typed words are the list calls have always used
/// (`MeetingNotesModel.knownWordsKey`), so nothing moves. Dictation adds the
/// built-ins someone took off, the "always write X as Y" entries and the two
/// learning switches, each a key of its own (`DictationWords`).
@MainActor
enum DictationWordsStore {
    static let replacementsKey = "words.replacements"
    static let builtInsRemovedKey = "words.builtInsRemoved"
    /// Off: no text box is ever read after a dictation.
    static let learnsKey = "dictation.learnsFromFixes"
    /// On: a fixed word joins the list without the notch asking first.
    static let learnsSilentlyKey = "dictation.learnsSilently"
    /// Posted after any of the lists changes, so a row drawn elsewhere follows.
    static let changed = Notification.Name("airlock.words.changed")

    static func load(_ settings: UserDefaults = .standard) -> DictationWords {
        DictationWords(typed: MeetingNotesModel.typedWords(in: settings),
                       builtInsRemoved: settings.stringArray(forKey: builtInsRemovedKey) ?? [],
                       replacements: replacements(settings))
    }

    static func replacements(_ settings: UserDefaults = .standard) -> [DictationWords.Replacement] {
        guard let data = settings.data(forKey: replacementsKey),
              let list = try? JSONDecoder().decode([DictationWords.Replacement].self, from: data)
        else { return [] }
        return list
    }

    static func saveTyped(_ list: [String], _ settings: UserDefaults = .standard) {
        settings.set(list, forKey: MeetingNotesModel.knownWordsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func saveReplacements(_ list: [DictationWords.Replacement], _ settings: UserDefaults = .standard) {
        settings.set(try? JSONEncoder().encode(list), forKey: replacementsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func saveBuiltInsRemoved(_ list: [String], _ settings: UserDefaults = .standard) {
        settings.set(list, forKey: builtInsRemovedKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: Spoken commands

    /// Saved texts (`SavedText`): kept here, on this Mac, and nowhere else.
    static let savedTextsKey = "words.savedTexts"
    static let spokenPunctuationKey = "dictation.spokenPunctuation"
    static let scratchThatKey = "dictation.scratchThat"
    static let savedTextsOnKey = "dictation.savedTexts"

    static func savedTexts(_ settings: UserDefaults = .standard) -> [SavedText] {
        guard let data = settings.data(forKey: savedTextsKey),
              let list = try? JSONDecoder().decode([SavedText].self, from: data) else { return [] }
        return list
    }

    static func saveSavedTexts(_ list: [SavedText], _ settings: UserDefaults = .standard) {
        settings.set(try? JSONEncoder().encode(list), forKey: savedTextsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The three switches, each on until the person turns it off.
    static func commandSwitches(_ settings: UserDefaults = .standard) -> SpokenCommands.Switches {
        SpokenCommands.Switches(
            punctuation: settings.object(forKey: spokenPunctuationKey) as? Bool ?? true,
            scratch: settings.object(forKey: scratchThatKey) as? Bool ?? true,
            savedTexts: settings.object(forKey: savedTextsOnKey) as? Bool ?? true)
    }

    /// On unless switched off.
    static var learns: Bool {
        UserDefaults.standard.object(forKey: learnsKey) as? Bool ?? true
    }

    /// On unless switched off (the owner's call, 2026-11-11).
    static var learnsSilently: Bool {
        UserDefaults.standard.object(forKey: learnsSilentlyKey) as? Bool ?? true
    }

    /// Keeps a fixed word: on the list, and "always write" when its letters
    /// changed.
    static func keep(_ learned: DictationCorrection.Learned) {
        let settings = UserDefaults.standard
        saveTyped(MeetingKnownWords.adding(learned.word, to: MeetingNotesModel.typedWords(in: settings)))
        if let heard = learned.heard {
            saveReplacements(DictationWords.adding(.init(heard: heard, written: learned.word),
                                                   to: replacements(settings)))
        }
    }

    /// Whether `word` (lowercase) is an ordinary word in any language the
    /// spell checker has on: such words are never respelled alone, and never
    /// learned.
    static func isDictionaryWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let checker = NSSpellChecker.shared
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }

    /// Names from recent calls (people invited, voices named) that are not
    /// on the list yet, most recent first, for Settings to suggest. Read off
    /// the main thread.
    static func namesFromCalls(limit: Int = 8) async -> [String] {
        let looked = MeetingNotesModel.namesLookedBack
        let names = await Task.detached(priority: .utility) { () -> [String] in
            MeetingStore().calls().prefix(looked).flatMap { call in
                (call.record.event?.attendees ?? [])
                    + call.record.names.filter { !$0.isYou }.map(\.name)
            }
        }.value
        let words = load()
        var seen: Set<String> = []
        return Array(names.compactMap { raw -> String? in
            let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !name.contains("@"), name.count >= 3, !words.knows(name),
                  seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }.prefix(limit))
    }
}
