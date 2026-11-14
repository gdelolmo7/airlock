import Foundation

/// Notes written with the person's own Anthropic key: when one is saved in
/// Settings, a finished call's notes and to-dos go straight from the Mac to
/// Anthropic's Messages API, with Claude (Sonnet unless the person picked
/// Opus or Haiku), and never through
/// Airlock's server. On every plan, Free included: the person pays for it.
///
/// Asked first, before the usual path (online notes on Plus and Pro, the
/// Mac's own model otherwise). Any failure falls back to that usual path,
/// and the page says why in plain words (`Problem.line`), so a call's notes
/// are never lost to a bad key.
///
/// The answer is the same JSON the online notes service gets
/// (`CallNotesPrompts.cloudTopicsInstructions`), read and checked exactly
/// as it is (`CloudNotes.parse`, `CloudNotes.notes(from:record:)`).
///
/// Here, not in the App, so the request, the reading of the answer and the
/// decisions are tested without a network.
public enum OwnKeyNotes {
    /// Anthropic's Messages API.
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    /// The model asked for when none was picked: Sonnet.
    public static let model = Choice.sonnet.id

    /// The models the person can pick in Settings, Sonnet unless they
    /// picked another. Kept as `Choice.preference`.
    public enum Choice: String, CaseIterable, Sendable {
        case sonnet
        case opus
        case haiku

        /// Where the pick is kept; missing or unknown reads as Sonnet.
        public static let preference = "callNotes.ownKeyModel"

        public static func saved(_ raw: String?) -> Choice {
            raw.flatMap(Choice.init(rawValue:)) ?? .sonnet
        }

        /// The model the request asks for.
        public var id: String {
            switch self {
            case .sonnet: return "claude-sonnet-5-5"
            case .opus: return "claude-opus-5-5"
            case .haiku: return "claude-haiku-5-5"
            }
        }

        /// The name the menu and the page use.
        public var name: String {
            switch self {
            case .sonnet: return "Claude Sonnet"
            case .opus: return "Claude Opus"
            case .haiku: return "Claude Haiku"
            }
        }

        /// What the menu says beside the name.
        public var note: String {
            switch self {
            case .sonnet: return String(localized: "Recommended")
            case .opus: return String(localized: "Strongest, slower, uses more credit")
            case .haiku: return String(localized: "Fastest, plainer notes")
            }
        }

        /// The pick a model's id belongs to, read from the name Anthropic
        /// answers with ("claude-opus-5-5", or a dated one), nil when it is
        /// none of them.
        public static func of(model: String?) -> Choice? {
            guard let model = model?.lowercased() else { return nil }
            return allCases.first { model.contains($0.rawValue) }
        }
    }
    /// Enough for the longest notes by topic, with room to spare.
    public static let maxTokens = 8_000

    // MARK: - The request

    /// The body: the fixed instructions as a cached system block, so every
    /// call after the first in five minutes pays a tenth for them, and the
    /// call's numbered transcript as the one user turn.
    public static func requestBody(instructions: String, prompt: String,
                                   maxTokens: Int = maxTokens, model: String = model) -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [[
                "type": "text",
                "text": instructions,
                "cache_control": ["type": "ephemeral"],
            ] as [String: Any]],
            "messages": [["role": "user", "content": prompt]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// The whole request, the key in its header and nowhere else.
    public static func request(key: String, body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = body
        return request
    }

    /// The smallest request that proves a key works: it checks the key,
    /// that it may use the model, and that the account has credit, for a
    /// fraction of a cent.
    public static func checkBody(model: String = model) -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "Hi"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - The answer

    /// What Anthropic said, read from its status and body.
    public enum Reply: Equatable, Sendable {
        /// 200 with text. `cutOff` when it stopped at `max_tokens`.
        case notes(text: String, model: String?, cutOff: Bool)
        case problem(Problem)

        public static func read(status: Int, body: Data) -> Reply {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            switch status {
            case 200:
                let blocks = object["content"] as? [[String: Any]] ?? []
                let text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined()
                guard !text.isEmpty else { return .problem(.unavailable) }
                return .notes(text: text, model: object["model"] as? String,
                              cutOff: object["stop_reason"] as? String == "max_tokens")
            default:
                return .problem(Problem.of(status: status, body: object))
            }
        }

        /// For the log: the kind only, never the text.
        public var logName: String {
            switch self {
            case .notes(_, _, let cutOff): return cutOff ? "notes, cut off" : "notes"
            case .problem(let problem): return problem.rawValue
            }
        }
    }

    /// Why notes couldn't be written with the key: kept with the notes
    /// (`MeetingNotesWriter.ownKeyProblem`) and said on the page.
    public enum Problem: String, Codable, CaseIterable, Equatable, Sendable {
        /// 401: the key was refused.
        case badKey
        /// 400 about the credit balance: the account has no credit left.
        case noCredit
        /// 403, or a 404 for the model: the key may not use the model picked.
        case notAllowed
        /// 413, or a prompt too long: the call is too long to send.
        case tooLong
        /// 429: too many requests, or the account's limit.
        case busy
        /// 5xx, 529, a timeout, or an answer that can't be read.
        case unavailable
        /// The request never left: no network.
        case offline
        /// An answer came, and nothing in it held up.
        case nothingHeldUp

        static func of(status: Int, body: [String: Any]) -> Problem {
            let error = body["error"] as? [String: Any] ?? [:]
            let message = (error["message"] as? String ?? "").lowercased()
            let type = error["type"] as? String ?? ""
            switch status {
            case 401: return .badKey
            case 403: return .notAllowed
            case 404: return .notAllowed
            case 413: return .tooLong
            case 429: return .busy
            case 400:
                if message.contains("credit balance") || message.contains("billing") { return .noCredit }
                if message.contains("prompt is too long") || message.contains("too many tokens") { return .tooLong }
                if type == "authentication_error" { return .badKey }
                return .unavailable
            default: return .unavailable
            }
        }

        /// The line under the date of notes written the usual way because
        /// the key didn't work, in plain words.
        public var line: String {
            let fallback = "so these notes were written the usual way."
            switch self {
            case .badKey:
                return "Your Claude key was refused, \(fallback) Check it in Settings › Meeting notes."
            case .noCredit:
                return "Your Anthropic account has no credit left, \(fallback)"
            case .notAllowed:
                return "Your Claude key can't use the model picked in Settings, \(fallback)"
            case .tooLong:
                return "This call was too long to send to Claude, \(fallback)"
            case .busy:
                return "Claude was too busy just then, \(fallback)"
            case .unavailable:
                return "Claude didn't answer, \(fallback)"
            case .offline:
                return "Your Mac was offline when the call ended, so Claude couldn't write these notes."
            case .nothingHeldUp:
                return "Claude's notes didn't match the transcript, \(fallback)"
            }
        }

        /// What Settings says after "Check", for a key that doesn't work, in
        /// the app's language. `line` stays English: it goes in the notes file.
        public var checkLine: String {
            switch self {
            case .badKey: return String(localized: "Anthropic refused this key. Copy it again from your Anthropic account.")
            case .noCredit: return String(localized: "The key works, but the account has no credit left.")
            case .notAllowed: return String(localized: "This key can't use this model. Pick another one.")
            case .busy: return String(localized: "Anthropic is busy. Try again in a minute.")
            case .offline: return String(localized: "Your Mac is offline. Try again once it's back online.")
            case .tooLong, .unavailable, .nothingHeldUp: return String(localized: "Anthropic didn't answer. Try again in a minute.")
            }
        }
    }

    // MARK: - Deciding

    /// Whether to ask Claude for a call's notes: only with a key, only for a
    /// call with enough said to write notes from, and only when it fits.
    public enum Route: Equatable, Sendable {
        case ask
        case skip(Skip)

        public enum Skip: Equatable, Sendable {
            case noKey
            case tooShort
            case tooLong
        }
    }

    /// The biggest prompt sent, in UTF-16 units: about 100,000 tokens of
    /// transcript, a two-hour meeting, well inside the model's window.
    public static let promptLimit = 390_000

    public static func decide(hasKey: Bool, words: Int, promptSize: Int) -> Route {
        guard hasKey else { return .skip(.noKey) }
        guard words >= MeetingNotes.minimumWords else { return .skip(.tooShort) }
        guard promptSize <= promptLimit else { return .skip(.tooLong) }
        return .ask
    }

    // MARK: - The key

    /// What a pasted key is, once spaces and line breaks around it are gone.
    public static func cleaned(_ pasted: String) -> String {
        pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a pasted text looks like an Anthropic key: "sk-ant-" and a
    /// long body, nothing else. Not a check that it works (`checkBody`).
    public static func looksLikeKey(_ pasted: String) -> Bool {
        let key = cleaned(pasted)
        guard key.hasPrefix("sk-ant-"), key.count >= 40, key.count <= 300 else { return false }
        return key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The key as Settings shows it: its start and last four, never the
    /// rest. "sk-ant-…abcd".
    public static func masked(_ key: String) -> String {
        let key = cleaned(key)
        guard key.count > 12 else { return "••••" }
        let start = key.hasPrefix("sk-ant-") ? "sk-ant-" : String(key.prefix(4))
        return start + "…" + String(key.suffix(4))
    }

    /// The footer of notes Claude wrote with the person's key, naming the
    /// model that wrote them ("Claude" when it is none of the picks).
    public static func footer(model: String?) -> String {
        "Written by \(Choice.of(model: model)?.name ?? "Claude"), with your own Anthropic key"
    }
}
