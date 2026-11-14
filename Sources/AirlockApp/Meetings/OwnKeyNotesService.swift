import AirlockCore
import Foundation
import Security

/// The person's own Anthropic key, kept in the login keychain and nowhere
/// else: never in preferences, never in a file, never in the log.
enum OwnKeyStore {
    static let service = "com.airlock.app.anthropic-key"
    static let account = "anthropic"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The saved key, or nil.
    static func key() -> String? {
        var item: CFTypeRef?
        var ask = query
        ask[kSecReturnData as String] = true
        ask[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(ask as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    static var hasKey: Bool { key() != nil }

    /// Saves `key` in place of any earlier one. False when the keychain
    /// wouldn't take it.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(OwnKeyNotes.cleaned(key).utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        // This Mac only: never synced to iCloud, never in a backup restored elsewhere.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Airlock: Anthropic API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Call notes written by Claude with the person's own key (`OwnKeyNotes`):
/// asked before the usual path whenever a key is saved, on every plan.
/// Any failure leaves the notes to the usual path, and says why on the page.
///
/// The log says kinds, sizes and timings, never a word of the call or of
/// the notes, and never the key.
@MainActor
final class OwnKeyNotesService {
    static let shared = OwnKeyNotesService()

    /// A long call is a long answer: up to `OwnKeyNotes.maxTokens` written
    /// in one go.
    nonisolated static let timeout: TimeInterval = 240

    /// Sends one request and reads its answer: the network in the app, a
    /// stand-in in tests.
    typealias Transport = @Sendable (_ key: String, _ body: Data) async -> OwnKeyNotes.Reply

    private let transport: Transport
    /// The saved key: the keychain in the app, a stand-in in tests.
    var key: () -> String? = { OwnKeyStore.key() }
    /// The model picked in Settings: the preference in the app, a stand-in
    /// in tests.
    var choice: () -> OwnKeyNotes.Choice = {
        OwnKeyNotes.Choice.saved(UserDefaults.standard.string(forKey: OwnKeyNotes.Choice.preference))
    }

    init(transport: Transport? = nil) {
        self.transport = transport ?? { await OwnKeyNotesService.send(key: $0, body: $1) }
    }

    enum Attempt {
        /// Claude wrote them, checked against the transcript.
        case written(MeetingNotes, model: String?)
        /// Not asked: no key, too little said, too long.
        case skipped
        /// Asked, and it didn't work: the usual path writes them.
        case problem(OwnKeyNotes.Problem)
    }

    func write(_ record: MeetingRecord, log: @escaping (String) -> Void) async -> Attempt {
        let key = key()
        let prompt = CallNotesPrompts.cloud(for: record, language: CallLanguage.check(record).decision?.name)
        let route = OwnKeyNotes.decide(hasKey: key != nil, words: NumberedTranscript(record).wordCount,
                                       promptSize: CloudNotes.size(prompt))
        guard case .ask = route, let key else {
            if case .skip(let why) = route, why != .noKey { log("notes with own key: no, \(why)") }
            return .skipped
        }
        let started = Date()
        let asked = choice().id
        log("notes with own key: asking \(asked), prompt \(CloudNotes.size(prompt)) units, \(record.segments.count) line(s)")
        let body = OwnKeyNotes.requestBody(instructions: CallNotesPrompts.cloudTopicsInstructions, prompt: prompt,
                                           model: asked)
        let reply = await transport(key, body)
        let took = String(format: "%.1fs", Date().timeIntervalSince(started))
        switch reply {
        case .problem(let problem):
            log("notes with own key: \(problem.rawValue) in \(took), written the usual way")
            return .problem(problem)
        case .notes(let text, let model, let cutOff):
            guard let draft = CloudNotes.parse(text) else {
                log("notes with own key: answer unreadable (\(CloudNotes.size(text)) units\(cutOff ? ", cut off" : "")) in \(took)")
                return .problem(.nothingHeldUp)
            }
            let (notes, tally) = CloudNotes.notes(from: draft, record: record)
            log("notes with own key: \(model ?? asked) in \(took), kept \(tally.kept), "
                + "dropped \(tally.dropped)\(cutOff ? ", cut off" : "")")
            guard !notes.isEmpty else { return .problem(.nothingHeldUp) }
            return .written(notes, model: model ?? asked)
        }
    }

    /// Whether `key` works with the model picked, with the smallest request
    /// there is. Nil: it does.
    func check(_ key: String) async -> OwnKeyNotes.Problem? {
        switch await transport(key, OwnKeyNotes.checkBody(model: choice().id)) {
        case .notes: return nil
        case .problem(let problem): return problem
        }
    }

    /// The request itself, off the main actor. A request that never left
    /// the Mac (`CloudNotes.neverLeft`) is `.offline`; every other failure,
    /// a timeout included, is `.unavailable`.
    nonisolated static func send(key: String, body: Data) async -> OwnKeyNotes.Reply {
        let request = OwnKeyNotes.request(key: key, body: body, timeout: timeout)
        // Nothing kept on disk: no cache, no cookies.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .problem(.unavailable) }
            return OwnKeyNotes.Reply.read(status: http.statusCode, body: data)
        } catch let error as URLError {
            return .problem(CloudNotes.neverLeft(error.code) ? .offline : .unavailable)
        } catch {
            return .problem(.unavailable)
        }
    }
}
