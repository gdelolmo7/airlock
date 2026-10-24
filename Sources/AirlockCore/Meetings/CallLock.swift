import CryptoKit
import Foundation

/// The part of a Free call past the notes limit: still heard, kept on this
/// Mac for a week, and unreadable there until the plan is Plus or Pro.
///
/// Hiding the words on screen would not be enough, since a call is plain
/// text on disk. So each line is sealed with a key made for the call, and
/// that key is sealed in turn to the server's public key (HPKE). Only the
/// server can open it, and it does so only for a paid licence on the Mac
/// that kept the call, before `keptUntil` (`CallUnlockWire`). The plain key
/// lives in memory while the call is heard, and nowhere else. The words
/// themselves never leave the Mac: the server is sent the sealed key alone.
///
/// Speaker and times stay in plain view, so a switch of language can still
/// replace one side's lines and the transcript can say how much is waiting.
public struct LockedPart: Codable, Equatable, Sendable {
    /// One locked line: who and when, and the line itself sealed.
    public struct Line: Codable, Equatable, Sendable {
        public var speaker: MeetingSpeaker
        public var start: TimeInterval
        public var end: TimeInterval
        /// The `MeetingSegment` as JSON, sealed with the call's key
        /// (ChaCha20-Poly1305, combined), in base64.
        public var sealed: String

        public init(speaker: MeetingSpeaker, start: TimeInterval, end: TimeInterval, sealed: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.sealed = sealed
        }
    }

    /// The call's key, sealed to the server's public key.
    public struct SealedKey: Codable, Equatable, Sendable {
        /// HPKE's encapsulated key, in base64.
        public var encapsulated: String
        /// The call's key, sealed, in base64.
        public var sealed: String

        public init(encapsulated: String, sealed: String) {
            self.encapsulated = encapsulated
            self.sealed = sealed
        }
    }

    /// Seconds from the start of the call where the lock begins.
    public var from: TimeInterval
    /// The end of the week the part is kept: removed then, and the server
    /// opens its key no later. Whole seconds, since it is part of what the
    /// key was sealed with and must read back the same from the file.
    public var keptUntil: Date
    /// The Mac the call was heard on (`MachineIdentity`), part of what the
    /// key was sealed with: the server opens it only for a licence on this
    /// Mac. Nil where the Mac can't be told.
    public var machine: String?
    /// Nil once the part is removed.
    public var key: SealedKey?
    /// In time order.
    public private(set) var lines: [Line]
    /// When the week ran out and the lines were removed.
    public var removedAt: Date?

    public init(from: TimeInterval, keptUntil: Date, machine: String?, key: SealedKey?,
                lines: [Line] = [], removedAt: Date? = nil) {
        self.from = from
        self.keptUntil = keptUntil
        self.machine = machine
        self.key = key
        self.lines = lines.sorted { $0.start < $1.start }
        self.removedAt = removedAt
    }

    /// Whether there is still something a paid plan could open.
    public func opens(at now: Date) -> Bool {
        key != nil && removedAt == nil && now < keptUntil
    }

    /// Inserted in time order, like `MeetingRecord.add`.
    public mutating func add(_ line: Line) {
        let index = lines.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
    }

    /// One side's lines from `seam` on, taken out for others heard again in
    /// another language (`MeetingRecord.switchLanguage`).
    public mutating func removeLines(of speaker: MeetingSpeaker, from seam: TimeInterval) {
        lines.removeAll { $0.speaker == speaker && $0.start >= seam }
    }

    /// At the end of the week the lines and the key go, and only what is
    /// needed to say so stays. True when that happened now.
    @discardableResult
    public mutating func removeIfDue(at now: Date) -> Bool {
        guard removedAt == nil, now >= keptUntil else { return false }
        lines = []
        key = nil
        removedAt = now
        return true
    }
}

public enum CallLock {
    /// How long a locked part is kept.
    public static let keptFor: TimeInterval = 7 * 86_400

    static let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
    static let info = Data("airlock call lock v1".utf8)

    /// The week a call's locked part is kept, from the call's start, in
    /// whole seconds.
    public static func keptUntil(startedAt: Date) -> Date {
        Date(timeIntervalSince1970: (startedAt.timeIntervalSince1970 + keptFor).rounded(.down))
    }

    /// What the call's key is sealed with besides the key itself. The server
    /// builds the same from what it is sent, so changing the Mac or the date
    /// in the file makes the key impossible to open.
    public static func aad(machine: String?, keptUntil: Date) -> Data {
        Data("airlock-call-lock-v1|\(machine ?? "")|\(Int(keptUntil.timeIntervalSince1970))".utf8)
    }

    /// The server's public key, from the base64 of its 32 bytes. Nil for
    /// anything else, and Free then stops listening at its limit as before.
    public static func publicKey(_ base64: String?) -> Curve25519.KeyAgreement.PublicKey? {
        guard let text = base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    /// Seals one call's lines. Made when the lock starts and kept in memory
    /// only, for as long as the call is heard.
    public struct Sealer: Sendable {
        let key: SymmetricKey
        /// The part as it starts: no lines yet, the key sealed.
        public let part: LockedPart

        public init(publicKey: Curve25519.KeyAgreement.PublicKey, machine: String?,
                    keptUntil: Date, from: TimeInterval) throws {
            let key = SymmetricKey(size: .bits256)
            var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: CallLock.suite, info: CallLock.info)
            let sealed = try key.withUnsafeBytes {
                try sender.seal(Data($0), authenticating: CallLock.aad(machine: machine, keptUntil: keptUntil))
            }
            self.key = key
            self.part = LockedPart(from: from, keptUntil: keptUntil, machine: machine,
                                   key: .init(encapsulated: sender.encapsulatedKey.base64EncodedString(),
                                              sealed: sealed.base64EncodedString()))
        }

        public func seal(_ segment: MeetingSegment) throws -> LockedPart.Line {
            let box = try ChaChaPoly.seal(try JSONEncoder().encode(segment), using: key)
            return .init(speaker: segment.speaker, start: segment.start, end: segment.end,
                         sealed: box.combined.base64EncodedString())
        }
    }

    public enum OpenError: Error, Equatable {
        case unreadable
    }

    /// The part's lines, opened with the call's key. Throws when any line
    /// doesn't open: a wrong key opens none of them.
    public static func open(_ part: LockedPart, with key: SymmetricKey) throws -> [MeetingSegment] {
        try part.lines.map { line in
            guard let data = Data(base64Encoded: line.sealed) else { throw OpenError.unreadable }
            let plain = try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: data), using: key)
            return try JSONDecoder().decode(MeetingSegment.self, from: plain)
        }
    }
}

/// Asking the server to open a locked part's key (`POST /unlock`). The token
/// proves the plan; the rest is what the key was sealed with. No words.
public enum CallUnlockWire {
    public static func requestBody(token: String, part: LockedPart) -> Data? {
        guard let key = part.key else { return nil }
        var body: [String: Any] = ["token": token, "keptUntil": Int(part.keptUntil.timeIntervalSince1970),
                                   "enc": key.encapsulated, "key": key.sealed]
        if let machine = part.machine { body["machine"] = machine }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// What the server said.
    public enum Reply: Equatable, Sendable {
        /// 200: the call's key, as its 32 bytes.
        case key(Data)
        /// 401: the token wasn't accepted.
        case badToken
        /// 402: the licence isn't paid up.
        case notPaid
        /// 403: the licence is for another Mac.
        case otherMachine
        /// 410: the week is over.
        case gone
        /// 422: the key doesn't open with what was sent. Asking again won't
        /// change that.
        case wontOpen
        /// 5xx, a timeout, or an answer that can't be read: ask later.
        case unavailable

        public static func read(status: Int, body: Data) -> Reply {
            switch status {
            case 200:
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                guard let text = object?["key"] as? String, let key = Data(base64Encoded: text),
                      key.count == 32 else { return .unavailable }
                return .key(key)
            case 401: return .badToken
            case 402: return .notPaid
            case 403: return .otherMachine
            case 410: return .gone
            case 400, 422: return .wontOpen
            default: return .unavailable
            }
        }

        /// For the log: the kind only, never the key.
        public var logName: String {
            switch self {
            case .key: return "opened"
            case .badToken: return "token refused"
            case .notPaid: return "not paid"
            case .otherMachine: return "other Mac"
            case .gone: return "past its week"
            case .wontOpen: return "won't open"
            case .unavailable: return "unavailable"
            }
        }
    }
}
