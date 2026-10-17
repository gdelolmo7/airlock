import AirlockTestSupport
import XCTest
@testable import SecretScan

/// The release's last look before notarizing: a bundle carrying anything
/// shaped like a secret key fails, the real shape of the app passes, and what
/// was found is never printed.
///
/// Every fake key here is put together while the test runs, from a prefix and
/// a body made of counted bytes. A whole key written out in this file would
/// be one in the public repository, where secret scanners would rightly
/// flag it.
final class SecretScanTests: XCTestCase {

    // MARK: - Fake keys

    /// `count` bytes that never repeat a pattern a reader would notice.
    private func bytes(_ count: Int, seed: Int) -> [UInt8] {
        var state = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
    }

    private func hex(_ count: Int, seed: Int) -> String {
        bytes(count / 2, seed: seed).map { String(format: "%02x", $0) }.joined()
    }

    private func letters(_ count: Int, seed: Int, from alphabet: String) -> String {
        let alphabet = Array(alphabet)
        return String(bytes(count, seed: seed).map { alphabet[Int($0) % alphabet.count] })
    }

    private let alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    private func base64Key(_ size: Int, seed: Int) -> String {
        Data(bytes(size, seed: seed)).base64EncodedString()
    }

    /// The web token spelling: `-` and `_` for `+` and `/`, no padding.
    private func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private var openRouterKey: String { "sk-or-v1-" + hex(64, seed: 1) }

    /// Each kind of key, as it would turn up.
    private var everyKind: [(SecretScan.Rule, String)] {
        let jwtHeader = base64url(#"{"typ":"JWT","alg":"RS256"}"#)
        let jwtBody = base64url(#"{"aud":"1","jti":"x","sub":"2"}"#)
        let pemKind = "PRIVATE " + "KEY"
        return [
            (.openRouter, openRouterKey),
            (.anthropic, "sk-ant-" + "api03-" + letters(80, seed: 2, from: alnum + "-_")),
            (.openAI, "sk-proj-" + letters(48, seed: 3, from: alnum + "-_")),
            (.openAI, "sk-" + letters(48, seed: 4, from: alnum)),
            (.google, "AIza" + letters(35, seed: 5, from: alnum + "-_")),
            (.gitHub, "ghp_" + letters(36, seed: 6, from: alnum)),
            (.gitHub, "github_pat_" + letters(82, seed: 7, from: alnum + "_")),
            (.sentryToken, "sntryu_" + hex(64, seed: 8)),
            (.stripe, "sk_live_" + letters(24, seed: 9, from: alnum)),
            (.aws, "AKIA" + letters(16, seed: 10, from: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")),
            (.slack, "xoxb-" + letters(40, seed: 11, from: alnum + "-")),
            (.webToken, jwtHeader + "." + jwtBody + "." + letters(43, seed: 12, from: alnum + "-_")),
            (.pem, "-----BEGIN " + pemKind + "-----\n" + base64Key(48, seed: 13)),
            (.pem, "-----BEGIN RSA " + pemKind + "-----"),
            (.ed25519PKCS8, "MC4CAQAwBQYDK2VwBCIEI" + String(base64Key(34, seed: 14).dropFirst(21))),
            (.key32, base64Key(32, seed: 15)),
            (.key64, base64Key(64, seed: 16)),
        ]
    }

    /// Something that reads like a program file: zeros, names, then `text`.
    private func programFile(with text: String = "") -> Data {
        var data = Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])
        data += Data("_$s7Airlock15LicenseVerifierV6verifyyAA0B0VSgSSF\0".utf8)
        data += Data("https://example.com/v1/refresh\0".utf8)
        data += Data(text.utf8) + Data([0, 0])
        return data
    }

    // MARK: - A bundle

    private let scratch = TestScratch("scan")
    override func tearDown() {
        scratch.remove()
        super.tearDown()
    }

    private let licencePublicKey = Data((0..<32).map { UInt8(($0 &* 41 &+ 7) & 0xFF) }).base64EncodedString()
    private let updatePublicKey = Data((0..<32).map { UInt8(($0 &* 29 &+ 3) & 0xFF) }).base64EncodedString()
    private var sentryDSN: String { "https://" + hex(32, seed: 20) + "@o1.ingest.de.sentry.io/2" }

    /// A small app shaped like the real one: the plist with its three public
    /// values, a program file that carries one of them, a text resource, a
    /// framework with a link inside, and the signature files.
    @discardableResult
    private func app(planting secret: String? = nil, in place: String = "Contents/MacOS/Airlock") throws -> URL {
        let app = scratch.folder("Airlock.app")
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.airlock.app",
            "ALLicensePublicKey": licencePublicKey,
            "SUPublicEDKey": updatePublicKey,
            "ALSentryDSN": sentryDSN,
            "ALLicenseAPIURL": "https://licence.example.com",
        ]
        try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  to: app, "Contents/Info.plist")
        try write(programFile(with: "verify\0" + licencePublicKey), to: app, "Contents/MacOS/Airlock")
        try write(programFile(), to: app, "Contents/MacOS/airlock-hook")
        try write(Data("All the code Airlock borrows, and under which licence.\n".utf8),
                  to: app, "Contents/Resources/THIRD-PARTY-LICENSES.txt")
        let framework = "Contents/Frameworks/Sparkle.framework"
        try write(programFile(with: "SUPublicEDKey"), to: app, "\(framework)/Versions/B/Sparkle")
        try FileManager.default.createSymbolicLink(
            atPath: app.appendingPathComponent("\(framework)/Versions/Current").path,
            withDestinationPath: "B")
        try FileManager.default.createSymbolicLink(
            atPath: app.appendingPathComponent("\(framework)/Sparkle").path,
            withDestinationPath: "Versions/Current/Sparkle")
        let hashes = "<key>hash2</key><data>\n" + base64Key(32, seed: 30) + "\n</data>"
        try write(Data(hashes.utf8), to: app, "Contents/_CodeSignature/CodeResources")
        try write(Data(hashes.utf8), to: app, "\(framework)/Versions/B/_CodeSignature/CodeResources")
        try write(Data([0, 1]) + Data(base64Key(32, seed: 31).utf8), to: app, "Contents/CodeResources")
        if let secret {
            // Added to what is there: a program file stays one, a new
            // resource is text.
            let file = app.appendingPathComponent(place)
            var data = (try? Data(contentsOf: file)) ?? Data()
            data += Data((secret + "\n").utf8)
            try write(data, to: app, place)
        }
        return app
    }

    private func write(_ data: Data, to app: URL, _ path: String) throws {
        let url = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: - The release's two answers

    func testTheAppAsItShipsPasses() throws {
        let report = try SecretScan.scan(bundle: app())
        XCTAssertTrue(report.isClean, report.lines.joined(separator: "\n"))
        XCTAssertEqual(report.files, 5, "the plist, two programs, a text file, the framework; no signatures, no links")
        XCTAssertEqual(Set(report.allowed.map(\.because)),
                       ["ALLicensePublicKey", "SUPublicEDKey", "ALSentryDSN"])
        XCTAssertTrue(report.allowed.contains(.init(path: "Contents/MacOS/Airlock", because: "ALLicensePublicKey")),
                      "the licence key is allowed in the program as well as the plist")
        XCTAssertTrue(report.lines.contains { $0.contains("the licence check's public key") })
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("✓") })
    }

    func testAPlantedKeyFailsAndSaysWhere() throws {
        let report = try SecretScan.scan(bundle: app(planting: openRouterKey))
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.findings.count, 1)
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.path, "Contents/MacOS/Airlock")
        XCTAssertEqual(finding.rule, .openRouter)
        XCTAssertEqual(finding.prefix, "sk-or-v1-")
        XCTAssertEqual(finding.length, openRouterKey.utf8.count)
        let line = try XCTUnwrap(report.lines.last)
        XCTAssertTrue(line.hasPrefix("✗ Contents/MacOS/Airlock, byte"), line)
        XCTAssertTrue(line.contains("an OpenRouter key"), line)
    }

    func testAKeyInAResourceFailsToo() throws {
        let report = try SecretScan.scan(bundle: app(planting: "\nkey: " + openRouterKey + "\n",
                                                      in: "Contents/Resources/THIRD-PARTY-LICENSES.txt"))
        XCTAssertEqual(report.findings.map(\.path), ["Contents/Resources/THIRD-PARTY-LICENSES.txt"])
    }

    func testNothingFoundIsEverPrinted() throws {
        for (rule, key) in everyKind {
            let report = try SecretScan.scan(bundle: app(planting: key))
            let printed = report.lines.joined(separator: "\n")
            XCTAssertFalse(report.isClean, "\(rule)")
            let body = Array(key.utf8.dropFirst(report.findings.first?.prefix.utf8.count ?? 0))
            // No run of eight characters from past the rule's own prefix.
            for start in 0..<(body.count - 8) {
                let piece = String(decoding: body[start..<(start + 8)], as: UTF8.self)
                XCTAssertFalse(printed.contains(piece), "\(rule) printed part of the key")
            }
            scratch.remove()
        }
    }

    // MARK: - What counts

    func testEveryKindIsFoundInAProgramFile() {
        for (rule, key) in everyKind {
            let found = SecretScan.matches(in: [UInt8](programFile(with: key)), isText: false)
            XCTAssertEqual(found.map(\.rule), [rule], "\(rule)")
        }
    }

    func testEveryKindIsFoundInText() {
        for (rule, key) in everyKind {
            let text = "OPENROUTER_KEY=\"" + key + "\"\n"
            let found = SecretScan.matches(in: Array(text.utf8), isText: true)
            XCTAssertEqual(found.map(\.rule), [rule], "\(rule) keeps its own name in text")
        }
    }

    func testWhatAProgramIsMadeOfIsNotAKey() {
        let pemPublic = "-----BEGIN PUBLIC " + "KEY-----"
        let ordinary = [
            // A model's checksum: 64 hex digits, which is what the call
            // listener checks its download against.
            hex(64, seed: 40),
            // Swift's names are long and mixed.
            "$s11AirlockCore12CloudNotesV15planNextLook4from5after3nowAC0E0VSgSay10Foundation4DateVG_A2PtFZ",
            // Base64 without the padding, which Swift names also look like.
            String(base64Key(32, seed: 41).dropLast()),
            // A key's prefix inside a word, and one without a body.
            "desk-" + letters(40, seed: 42, from: alnum), "task_" + letters(40, seed: 43, from: alnum),
            "sk-or-v1-", "AIza", "eyJhbGciOiJIUzI1NiJ9",
            pemPublic, "-----BEGIN CERTIFICATE-----",
            "550e8400-e29b-41d4-a716-446655440000",
        ]
        for text in ordinary {
            XCTAssertEqual(SecretScan.matches(in: [UInt8](programFile(with: text)), isText: false), [], text)
        }
    }

    func testRandomLookingTextOnlyCountsInTextFiles() {
        let token = letters(40, seed: 50, from: alnum)
        XCTAssertEqual(SecretScan.matches(in: Array("token = \(token)\n".utf8), isText: true).map(\.rule),
                       [.randomText])
        XCTAssertEqual(SecretScan.matches(in: [UInt8](programFile(with: token)), isText: false), [])
        XCTAssertEqual(SecretScan.matches(in: Array("secret: \(hex(40, seed: 51))\n".utf8), isText: true).map(\.rule),
                       [.randomText], "hex in text")
    }

    func testOrdinaryTextIsNotRandom() {
        let text = """
            Airlock embeds Sparkle 2.6.4 (https://github.com/sparkle-project/Sparkle), MIT.
            THIRD-PARTY-LICENSES, Copyright (c) 2006-2013 Andy Matuschak, 2013-2025 Sparkle Project.
            com.apple.security.cs.disable-library-validation
            550e8400-e29b-41d4-a716-446655440000 2c3d4e5f
            ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
            """
        XCTAssertEqual(SecretScan.matches(in: Array(text.utf8), isText: true), [])
    }

    func testAProgramFileIsNotText() {
        XCTAssertFalse(SecretScan.isText([UInt8](programFile())))
        XCTAssertTrue(SecretScan.isText(Array("plain\n".utf8)))
        XCTAssertFalse(SecretScan.isText([]))
    }

    // MARK: - What is allowed

    func testAKeyOfTheRightShapeThatIsNotThePublicOneFails() throws {
        // The private half of the licence key has the public half's shape.
        let report = try SecretScan.scan(bundle: app(planting: base64Key(32, seed: 60),
                                                      in: "Contents/Resources/defaults.json"))
        XCTAssertEqual(report.findings.map(\.rule), [.key32])
    }

    func testTheCrashReportAddressIsAllowedWhereverItIs() throws {
        let report = try SecretScan.scan(bundle: app(planting: "{\"dsn\": \"\(sentryDSN)\"}",
                                                      in: "Contents/Resources/defaults.json"))
        XCTAssertTrue(report.isClean, report.lines.joined(separator: "\n"))
        XCTAssertTrue(report.allowed.contains(.init(path: "Contents/Resources/defaults.json", because: "ALSentryDSN")))
    }

    func testAFalseAlarmIsLetThroughByItsFingerprintOnly() throws {
        let bundle = try app(planting: openRouterKey)
        let fingerprint = try XCTUnwrap(SecretScan.scan(bundle: bundle).findings.first?.fingerprint)
        XCTAssertEqual(fingerprint.count, 12)

        let allowed = try SecretScan.scan(bundle: bundle, allowing: [fingerprint])
        XCTAssertTrue(allowed.isClean)
        XCTAssertTrue(allowed.lines.contains { $0.contains("fingerprint \(fingerprint)") })

        let other = try SecretScan.scan(bundle: bundle, allowing: ["000000000000"])
        XCTAssertFalse(other.isClean)
    }

    // MARK: - What is left out

    func testSignatureFilesAreLeftOut() throws {
        // `app()` puts a 32-byte base64 hash in each of the three.
        let report = try SecretScan.scan(bundle: app())
        XCTAssertTrue(report.isClean)
        XCTAssertFalse(report.allowed.contains { $0.path.contains("CodeResources") })
    }

    func testLinksAreNotFollowed() throws {
        let bundle = try app()
        let outside = scratch.file("outside.txt")
        try Data(openRouterKey.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Contents/Resources/linked.txt").path,
            withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Contents/Resources/folder").path,
            withDestinationPath: scratch.root.path)
        let report = try SecretScan.scan(bundle: bundle)
        XCTAssertTrue(report.isClean, report.lines.joined(separator: "\n"))
        XCTAssertEqual(report.files, 5)
    }

    func testABundleThatIsNotThereIsAnError() {
        XCTAssertThrowsError(try SecretScan.scan(bundle: scratch.file("Missing.app")))
        let file = scratch.file("Airlock.app")
        XCTAssertNoThrow(try Data("not a folder".utf8).write(to: file))
        XCTAssertThrowsError(try SecretScan.scan(bundle: file))
    }
}
