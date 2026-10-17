import CryptoKit
import Foundation

/// Looks through a finished app for anything shaped like a secret key, so a
/// release that carries one stops before it is notarized and published.
///
/// The keys that cost money or mint licences (the model service key, the
/// shop's API key, the licence signing key, the updater's signing key) live on
/// the server or in the owner's keychain, never in the app, and 1.0.21 as
/// published scans clean. This is that check run by `release.sh` every time,
/// because online features keep growing and a key pasted into the wrong file
/// ships to every Mac and to the public repository's readers in one stroke.
///
/// **Shapes, not values.** The scan never reads a secret to compare against:
/// it would have to fetch them from the keychain to do that, which is a worse
/// place for a release script to be than a pattern. What it knows instead is
/// what each kind of key looks like (`Rule`), and two kinds of evidence:
///
/// - Everywhere, including program files: a known prefix with a body of the
///   right alphabet and length (`sk-or-v1-` plus 64 hex digits), a PEM private
///   key, a signed web token, and a standalone base64 Ed25519 key (43
///   characters and `=`, which is what both the licence key and the updater
///   key look like, the private halves included).
/// - In text files only: anything random-looking. In a program file that
///   rule fires tens of thousands of times on Swift's mangled names, measured
///   on 1.0.22, so it is not asked there.
///
/// **The public keys that are meant to be there are allowed by name**
/// (`publicByName`): whatever the bundle's own Info.plist holds under those
/// keys is reported as allowed, wherever it appears, and nothing else is. A
/// one-off false alarm is allowed by its fingerprint (`Finding.fingerprint`),
/// never by writing the matched text down anywhere.
///
/// **Nothing found is ever printed.** A finding says where, which rule, the
/// rule's public prefix and the length; the key's own characters never reach
/// the terminal, the scrollback or a log.
///
/// Never linked into the app: the scanner's own prefixes would sit in the
/// binary it scans, and the app has no use for it.
public enum SecretScan {

    /// What one kind of secret looks like, named for the person reading the
    /// release output.
    public enum Rule: String, CaseIterable, Sendable {
        case openRouter = "an OpenRouter key"
        case anthropic = "an Anthropic key"
        case openAI = "an OpenAI key"
        case google = "a Google API key"
        case gitHub = "a GitHub token"
        case sentryToken = "a Sentry auth token"
        case stripe = "a Stripe secret key"
        case aws = "an AWS access key"
        case slack = "a Slack token"
        case webToken = "a signed web token (the shop's API key is one)"
        case pem = "a private key (PEM)"
        case ed25519PKCS8 = "an Ed25519 private key (PKCS#8)"
        case key32 = "a 32-byte key in base64 (licence and update keys look like this)"
        case key64 = "a 64-byte key in base64"
        case randomText = "random-looking text"
    }

    /// The Info.plist entries that are public on purpose and may appear in the
    /// bundle. Each value is allowed wherever it turns up; the name is what the
    /// release output says it was.
    public static let publicByName: [String: String] = [
        "ALLicensePublicKey": "the licence check's public key",
        "SUPublicEDKey": "the updater's public key",
        "ALSentryDSN": "the crash reports address",
    ]

    /// Something that looked like a secret.
    public struct Finding: Equatable, Sendable {
        /// Inside the bundle, e.g. `Contents/MacOS/Airlock`.
        public let path: String
        /// Byte offset in that file.
        public let offset: Int
        public let length: Int
        public let rule: Rule
        /// The rule's own public prefix (`sk-or-v1-`), or empty. Never any of
        /// the key's characters past it.
        public let prefix: String
        /// The first twelve hex digits of the matched text's SHA-256: enough
        /// to allow one false alarm on purpose, and nothing to recover a key
        /// from.
        public let fingerprint: String
    }

    /// Something that looked like a secret and is meant to be there.
    public struct Allowed: Equatable, Sendable {
        public let path: String
        /// Why: an Info.plist key from `publicByName`, or "fingerprint …".
        public let because: String
    }

    public struct Report: Equatable, Sendable {
        public var findings: [Finding] = []
        public var allowed: [Allowed] = []
        public var files = 0
        public var bytes = 0
        public var isClean: Bool { findings.isEmpty }

        /// What the release prints. Safe to show: see `Finding`.
        public var lines: [String] {
            var lines = ["scanned \(files) files (\(bytes / 1_000_000) MB)"]
            let reasons = Dictionary(grouping: allowed, by: \.because)
            for because in reasons.keys.sorted() {
                let paths = Set(reasons[because]!.map(\.path)).sorted().joined(separator: ", ")
                let what = SecretScan.publicByName[because].map { "\(because), \($0)" } ?? because
                lines.append("allowed: \(what) (\(paths))")
            }
            if findings.isEmpty {
                lines.append("✓ nothing shaped like a secret key")
            }
            for finding in findings {
                let shown = finding.prefix.isEmpty ? "" : "\(finding.prefix)…, "
                lines.append("✗ \(finding.path), byte \(finding.offset): \(finding.rule.rawValue) "
                    + "(\(shown)\(finding.length) characters) [fingerprint \(finding.fingerprint)]")
            }
            return lines
        }
    }

    /// Looks through every file in `bundle`. Symbolic links are not followed
    /// (a framework's `Versions/Current` would be read twice), and Apple's
    /// signature files are left out: `_CodeSignature` is full of base64
    /// hashes, and `Contents/CodeResources` is the notarization ticket.
    ///
    /// `allowing` holds fingerprints of false alarms let through on purpose.
    public static func scan(bundle: URL, allowing fingerprints: Set<String> = []) throws -> Report {
        let root = bundle.standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue,
              let walk = FileManager.default.enumerator(atPath: root.path)
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let publicValues = publicValues(in: root)
        var report = Report()
        // Paths as the walk gives them, relative to the bundle: resolving
        // links to compare absolute paths goes wrong under /private, which
        // macOS shortens to /var and /tmp on the way back.
        var paths: [String] = []
        while let relative = walk.nextObject() as? String {
            let type = walk.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory, (relative as NSString).lastPathComponent == "_CodeSignature" {
                walk.skipDescendants()
            }
            guard type == .typeRegular, relative != "Contents/CodeResources" else { continue }
            paths.append(relative)
        }
        for relative in paths.sorted() {
            let data = try Data(contentsOf: root.appendingPathComponent(relative), options: .alwaysMapped)
            report.files += 1
            report.bytes += data.count
            let bytes = [UInt8](data)
            for match in matches(in: bytes, isText: isText(bytes)) {
                let text = bytes[match.offset..<(match.offset + match.length)]
                if let name = publicValues.first(where: { $0.value.firstRange(of: text) != nil })?.name {
                    report.allowed.append(Allowed(path: relative, because: name))
                    continue
                }
                let fingerprint = Self.fingerprint(text)
                if fingerprints.contains(fingerprint) {
                    report.allowed.append(Allowed(path: relative, because: "fingerprint \(fingerprint)"))
                    continue
                }
                report.findings.append(Finding(
                    path: relative, offset: match.offset, length: match.length,
                    rule: match.rule, prefix: match.prefix, fingerprint: fingerprint))
            }
        }
        return report
    }

    /// The values `publicByName` allows, read from the bundle's own Info.plist.
    static func publicValues(in bundle: URL) -> [(name: String, value: [UInt8])] {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return publicByName.keys.sorted().compactMap { name in
            guard let value = info[name] as? String, !value.isEmpty else { return nil }
            return (name, Array(value.utf8))
        }
    }

    static func fingerprint<C: Collection>(_ text: C) -> String where C.Element == UInt8 {
        SHA256.hash(data: Data(text)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A file with no zero byte is read as text, where the random-looking
    /// rule applies too. Program files, compiled interfaces and binary plists
    /// all have zeros.
    static func isText(_ bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && !bytes.contains(0)
    }

    // MARK: - Matching

    struct Match: Equatable {
        let offset: Int
        let length: Int
        let rule: Rule
        let prefix: String
    }

    /// Every secret-shaped run in `bytes`, earliest first, none overlapping.
    static func matches(in bytes: [UInt8], isText: Bool) -> [Match] {
        // The shapes are kept first, so where a random-looking run overlaps
        // one of them, the more telling name is the one reported.
        var kept: [Match] = []
        let shapes = (prefixed(in: bytes) + base64Keys(in: bytes)).sorted { $0.offset < $1.offset }
        for match in shapes + (isText ? randomText(in: bytes) : []) {
            let overlaps = kept.contains {
                match.offset < $0.offset + $0.length && $0.offset < match.offset + match.length
            }
            if !overlaps { kept.append(match) }
        }
        return kept.sorted { $0.offset < $1.offset }
    }

    /// Which bytes a key's body may be made of.
    enum Alphabet {
        case hex, alnum, urlSafe, base64, upperDigits, slack

        func allows(_ byte: UInt8) -> Bool {
            switch self {
            case .hex: isDigit(byte) || (byte >= 0x61 && byte <= 0x66)
            case .alnum: isAlnum(byte)
            case .urlSafe: isAlnum(byte) || byte == 0x2D || byte == 0x5F
            case .base64: isAlnum(byte) || byte == 0x2B || byte == 0x2F || byte == 0x3D || byte == 0x5F || byte == 0x2D
            case .upperDigits: isDigit(byte) || (byte >= 0x41 && byte <= 0x5A)
            case .slack: isAlnum(byte) || byte == 0x2D
            }
        }
    }

    /// A key that announces itself: the provider's prefix, then a body.
    struct Prefixed {
        let marker: [UInt8]
        let body: Alphabet
        let minimum: Int
        let rule: Rule
        /// The byte before the marker must not be a letter or digit, for
        /// markers short enough to turn up inside a word (`desk-…`).
        let alone: Bool

        init(_ marker: String, _ body: Alphabet, _ minimum: Int, _ rule: Rule, alone: Bool = false) {
            self.marker = Array(marker.utf8)
            self.body = body
            self.minimum = minimum
            self.rule = rule
            self.alone = alone
        }
    }

    /// Longest marker first where two share a first byte, so `sk-or-v1-`
    /// names a key before `sk-` gets the chance.
    static let prefixes: [Prefixed] = [
        Prefixed("sk-or-v1-", .hex, 64, .openRouter),
        Prefixed("sk-svcacct-", .urlSafe, 32, .openAI),
        Prefixed("sk-proj-", .urlSafe, 32, .openAI),
        Prefixed("sk-ant-", .urlSafe, 32, .anthropic),
        Prefixed("sk_live_", .alnum, 20, .stripe, alone: true),
        Prefixed("sk_test_", .alnum, 20, .stripe, alone: true),
        Prefixed("sk-", .alnum, 32, .openAI, alone: true),
        Prefixed("rk_live_", .alnum, 20, .stripe, alone: true),
        Prefixed("AIza", .urlSafe, 35, .google, alone: true),
        Prefixed("github_pat_", .urlSafe, 60, .gitHub, alone: true),
        Prefixed("ghp_", .alnum, 36, .gitHub, alone: true),
        Prefixed("gho_", .alnum, 36, .gitHub, alone: true),
        Prefixed("ghu_", .alnum, 36, .gitHub, alone: true),
        Prefixed("ghs_", .alnum, 36, .gitHub, alone: true),
        Prefixed("ghr_", .alnum, 36, .gitHub, alone: true),
        Prefixed("sntrys_", .base64, 40, .sentryToken),
        Prefixed("sntryu_", .hex, 64, .sentryToken),
        Prefixed("AKIA", .upperDigits, 16, .aws, alone: true),
        Prefixed("ASIA", .upperDigits, 16, .aws, alone: true),
        Prefixed("xoxb-", .slack, 20, .slack, alone: true),
        Prefixed("xoxp-", .slack, 20, .slack, alone: true),
        Prefixed("xoxa-", .slack, 20, .slack, alone: true),
        Prefixed("xoxs-", .slack, 20, .slack, alone: true),
        Prefixed("xapp-", .slack, 20, .slack, alone: true),
        // DER for "PKCS#8, version 0, algorithm Ed25519, 32-byte key", in
        // base64: how the Worker holds the licence signing key.
        Prefixed("MC4CAQAwBQYDK2VwBCIEI", .base64, 20, .ed25519PKCS8),
    ]

    private static let pemStart = Array("-----BEGIN ".utf8)
    private static let pemEnd = Array("PRIVATE KEY-----".utf8)
    private static let pemEndLine = Array("-----END ".utf8)
    private static let webTokenStart = Array("eyJ".utf8)

    static func prefixed(in bytes: [UInt8]) -> [Match] {
        var byFirst = [[Prefixed]](repeating: [], count: 256)
        for rule in prefixes { byFirst[Int(rule.marker[0])].append(rule) }
        var found: [Match] = []
        var i = 0
        let n = bytes.count
        scanning: while i < n {
            let first = bytes[i]
            for rule in byFirst[Int(first)] where has(rule.marker, at: i, in: bytes) {
                if rule.alone, i > 0, isAlnum(bytes[i - 1]) { continue }
                let bodyStart = i + rule.marker.count
                var end = bodyStart
                while end < n, rule.body.allows(bytes[end]) { end += 1 }
                guard end - bodyStart >= rule.minimum else { continue }
                found.append(Match(offset: i, length: end - i, rule: rule.rule,
                                   prefix: String(decoding: rule.marker, as: UTF8.self)))
                i = end
                continue scanning
            }
            if first == pemStart[0], has(pemStart, at: i, in: bytes),
               let length = pemPrivateKey(at: i, in: bytes) {
                found.append(Match(offset: i, length: length, rule: .pem, prefix: "-----BEGIN"))
                i += length
                continue
            }
            if first == webTokenStart[0], has(webTokenStart, at: i, in: bytes),
               i == 0 || !Alphabet.urlSafe.allows(bytes[i - 1]),
               let length = webToken(at: i, in: bytes) {
                found.append(Match(offset: i, length: length, rule: .webToken, prefix: "eyJ"))
                i += length
                continue
            }
            i += 1
        }
        return found
    }

    /// `-----BEGIN … PRIVATE KEY-----` (RSA, EC, OPENSSH, ENCRYPTED or none)
    /// and the base64 lines under it, up to the `-----END` line if there is
    /// one: the length, or nil for any other PEM block, public keys and
    /// certificates included. One finding for the whole key, rather than the
    /// header and then its body as random-looking text.
    static func pemPrivateKey(at start: Int, in bytes: [UInt8]) -> Int? {
        guard let header = pemPrivateKeyHeader(at: start, in: bytes) else { return nil }
        var i = start + header
        while i < bytes.count, isStandardBase64(bytes[i]) || [0x3D, 0x0A, 0x0D, 0x20, 0x09].contains(bytes[i]) {
            i += 1
        }
        if has(pemEndLine, at: i, in: bytes),
           let close = (i + pemEndLine.count..<min(bytes.count, i + 48)).first(where: { has(pemEnd, at: $0, in: bytes) }) {
            i = close + pemEnd.count
        }
        return i - start
    }

    static func pemPrivateKeyHeader(at start: Int, in bytes: [UInt8]) -> Int? {
        var i = start + pemStart.count
        let limit = min(bytes.count, i + 24)
        while i < limit, bytes[i] != 0x2D {
            guard (bytes[i] >= 0x41 && bytes[i] <= 0x5A) || bytes[i] == 0x20 else { return nil }
            i += 1
        }
        // `i` is at the first dash: the header ends `PRIVATE KEY-----`, whose
        // dashes start eleven bytes after "PRIVATE".
        let keyword = i - (pemEnd.count - 5)
        guard keyword >= start + pemStart.count, has(pemEnd, at: keyword, in: bytes) else { return nil }
        return keyword + pemEnd.count - start
    }

    /// Three base64url parts joined by dots, the first two starting `eyJ`
    /// (`{"` encoded): the length, or nil.
    static func webToken(at start: Int, in bytes: [UInt8]) -> Int? {
        var i = start
        for part in 0..<3 {
            if part == 1, !has(webTokenStart, at: i, in: bytes) { return nil }
            let partStart = i
            while i < bytes.count, Alphabet.urlSafe.allows(bytes[i]) { i += 1 }
            guard i - partStart >= 10 else { return nil }
            if part < 2 {
                guard i < bytes.count, bytes[i] == 0x2E else { return nil }
                i += 1
            }
        }
        return i - start
    }

    /// Standard base64 that stands alone and decodes to exactly 32 bytes (43
    /// characters and `=`) or 64 (86 and `==`). An Ed25519 key in either
    /// half, and Sparkle's older 64-byte form. The unpadded URL-safe spelling
    /// is not looked for: 43 letters and digits is also a Swift symbol.
    static func base64Keys(in bytes: [UInt8]) -> [Match] {
        var found: [Match] = []
        let n = bytes.count
        var i = 0
        while i < n {
            defer { i += 1 }
            guard bytes[i] == 0x3D else { continue }
            let padding = (i + 1 < n && bytes[i + 1] == 0x3D) ? 2 : 1
            let characters = padding == 1 ? 43 : 86
            let start = i - characters
            guard start >= 0 else { continue }
            let after = i + padding
            if after < n, isTokenByte(bytes[after]) || bytes[after] == 0x3D { continue }
            if start > 0, isTokenByte(bytes[start - 1]) { continue }
            guard bytes[start..<i].allSatisfy(isStandardBase64),
                  let decoded = Data(base64Encoded: Data(bytes[start..<after])),
                  decoded.count == (padding == 1 ? 32 : 64)
            else { continue }
            found.append(Match(offset: start, length: after - start,
                               rule: padding == 1 ? .key32 : .key64, prefix: ""))
            i = after - 1
        }
        return found
    }

    /// Runs of 32 or more key characters that look like they were drawn at
    /// random: hex with a spread of digits, or base64 with upper case, lower
    /// case and digits mixed and little repetition. Text files only.
    static func randomText(in bytes: [UInt8]) -> [Match] {
        var found: [Match] = []
        let n = bytes.count
        var i = 0
        while i < n {
            guard isRandomTextByte(bytes[i]) else { i += 1; continue }
            var start = i
            while i < n, isRandomTextByte(bytes[i]) { i += 1 }
            // Judged on what is between its first and last letter or digit:
            // the `//` of an address is not part of the key after it.
            var end = i
            while start < end, !isAlnum(bytes[start]) { start += 1 }
            while end > start, !isAlnum(bytes[end - 1]) { end -= 1 }
            let run = bytes[start..<end]
            if looksRandom(run) {
                found.append(Match(offset: start, length: run.count, rule: .randomText, prefix: ""))
            }
        }
        return found
    }

    static func looksRandom(_ run: ArraySlice<UInt8>) -> Bool {
        guard run.count >= 32 else { return false }
        // An alphabet written out (`ABCDEF…`, `0123…`) is as varied as a key
        // and nothing like one.
        let steps = zip(run, run.dropFirst()).count(where: { $1 == $0 &+ 1 })
        guard steps * 4 < run.count else { return false }
        if run.allSatisfy({ isDigit($0) || ($0 >= 0x61 && $0 <= 0x66) })
            || run.allSatisfy({ isDigit($0) || ($0 >= 0x41 && $0 <= 0x46) }) {
            // Sixteen symbols allow at most 4 bits, and 32 random hex digits
            // usually score about 3.6, a quarter of them under 3.5.
            return run.contains(where: isDigit) && run.contains(where: { !isDigit($0) })
                && entropy(run) >= 3.0
        }
        let upper = run.count(where: { $0 >= 0x41 && $0 <= 0x5A })
        let lower = run.count(where: { $0 >= 0x61 && $0 <= 0x7A })
        let digits = run.count(where: isDigit)
        return upper >= 3 && lower >= 3 && digits >= 3 && entropy(run) >= 4.5
    }

    /// Bits per character.
    static func entropy(_ run: ArraySlice<UInt8>) -> Double {
        var counts = [Int](repeating: 0, count: 256)
        for byte in run { counts[Int(byte)] += 1 }
        let total = Double(run.count)
        return counts.reduce(0) { sum, count in
            guard count > 0 else { return sum }
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    private static func has(_ marker: [UInt8], at i: Int, in bytes: [UInt8]) -> Bool {
        guard i + marker.count <= bytes.count else { return false }
        for k in 0..<marker.count where bytes[i + k] != marker[k] { return false }
        return true
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isAlnum(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isStandardBase64(_ byte: UInt8) -> Bool {
        isAlnum(byte) || byte == 0x2B || byte == 0x2F
    }

    /// What can sit either side of a key without being part of it is
    /// anything else: quotes, brackets, spaces, `=` after a name, a zero.
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        isStandardBase64(byte) || byte == 0x2D || byte == 0x5F
    }

    /// The random-looking rule splits on everything but key characters, `=`
    /// included, so `token=…` is judged on what follows the name.
    private static func isRandomTextByte(_ byte: UInt8) -> Bool {
        isTokenByte(byte)
    }
}
