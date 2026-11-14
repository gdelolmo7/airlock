import AirlockCore
import Foundation

/// The answers given under "Check these words", kept in Settings so every
/// later call gets them (`MeetingWordMemory`).
enum MeetingWordAnswers {
    static let key = "meetings.wordAnswers"

    static func load(_ settings: UserDefaults = .standard) -> MeetingWordMemory {
        guard let data = settings.data(forKey: key),
              let memory = try? JSONDecoder().decode(MeetingWordMemory.self, from: data) else { return .init() }
        return memory
    }

    static func save(_ memory: MeetingWordMemory, _ settings: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        settings.set(data, forKey: key)
    }

    /// Keeps an answer for the calls after this one: in the list, and for
    /// "Use", the ways it was heard that are safe to change everywhere as
    /// "Always write X as Y" (shared with dictation).
    @MainActor static func keep(_ answer: CallNotesLibrary.WordAnswer, _ settings: UserDefaults = .standard) {
        let memory = load(settings).remembering(answer.best, heard: answer.heard, use: answer.use,
                                                listed: answer.listed)
        save(memory, settings)
        guard answer.use else { return }
        let forms = MeetingWordCheck.forms(answer.heard, listed: answer.listed, best: answer.best)
        let always = MeetingWordMemory.alwaysWritten(forms, as: answer.best,
                                                     isDictionaryWord: DictationWordsStore.isDictionaryWord)
        guard !always.isEmpty else { return }
        let before = DictationWordsStore.replacements(settings)
        let after = always.reduce(before) { list, heard in
            DictationWords.adding(.init(heard: heard, written: answer.best), to: list)
        }
        if after != before { DictationWordsStore.saveReplacements(after, settings) }
    }

    /// Answers, from the list, the words on the notes in `folder` that were
    /// answered the same way before, so they are not asked again. `held` is
    /// the record the app holds for that folder, if any. Returns the record
    /// as saved when anything changed it.
    @discardableResult
    static func applyRemembered(in folder: URL, store: MeetingStore, record held: MeetingRecord?,
                                settings: UserDefaults = .standard,
                                log: (String) -> Void) -> MeetingRecord? {
        guard let page = store.notesPage(in: folder) else { return nil }
        let listed = MeetingWordCheck.listed(in: page)
        guard !listed.isEmpty else { return nil }
        let memory = load(settings)
        var record = held
        var answered = 0
        for word in listed {
            guard let remembered = memory.answer(for: word.best, heard: word.heard) else { continue }
            do {
                switch remembered {
                case .use(let written):
                    record = try store.checkWord(written, heard: word.heard, use: true,
                                                 listed: written == word.best ? nil : word.best,
                                                 in: folder, record: record) ?? record
                case .leave:
                    record = try store.checkWord(word.best, heard: word.heard, use: false,
                                                 in: folder, record: record) ?? record
                }
                answered += 1
            } catch {
                log("words: remembered answer not saved: \(error.localizedDescription)")
            }
        }
        if answered > 0 { log("words: \(answered) answered as before") }
        return answered > 0 ? record : nil
    }
}
