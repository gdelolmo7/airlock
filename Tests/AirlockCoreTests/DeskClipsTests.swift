import Foundation
import Testing
@testable import AirlockCore

@Suite struct DeskClipsTests {
    func text(_ value: String, _ minutesAgo: Double, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(payload: .text(value), fingerprint: value,
                      copiedAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), pinned: pinned,
                      sourceAppName: "Notes")
    }

    @Test func newestFirstUpToTheLimit() {
        let items = (0..<10).map { text("copy \($0)", Double($0)) }
        let clips = DeskClips.make(items.shuffled(), planShows: nil, isOn: true, surface: .darkGlass)
        #expect(clips.clips.map(\.text) == (0..<6).map { "copy \($0)" })
        #expect(clips.isOn && clips.surface == .darkGlass)
    }

    @Test func keepsToWhatThePlanShows() {
        // History order: pinned first, then newest.
        let items = [text("pinned old", 90, pinned: true)] + (0..<5).map { text("copy \($0)", Double($0)) }
        let clips = DeskClips.make(items, planShows: 2, isOn: true, surface: nil)
        #expect(clips.clips.map(\.text) == ["copy 0", "copy 1", "pinned old"])
    }

    @Test func offCarriesNothing() {
        let clips = DeskClips.make([text("a", 1)], planShows: nil, isOn: false, surface: nil)
        #expect(clips.clips.isEmpty && !clips.isOn)
    }

    @Test func secretTextIsWrittenAsItsLengthOnly() throws {
        let key = "sk-ant-api03-" + String(repeating: "aB3dE5fG7h", count: 5)
        let clips = DeskClips.make([text(key, 1)], planShows: nil, isOn: true, surface: nil)
        let clip = try #require(clips.clips.first)
        #expect(clip.text == nil && clip.hiddenLength == key.count && clip.isHidden)
        let data = try DeskShelf.encoder().encode(clips)
        #expect(!String(decoding: data, as: UTF8.self).contains("aB3dE5fG7h"))
        #expect(!clip.line.contains("aB3d"))
    }

    @Test func textIsOneLineCutShort() throws {
        let long = String(repeating: "word ", count: 100) + "\nsecond line"
        let clip = try #require(DeskClips.make([text(long, 1)], planShows: nil, isOn: true, surface: nil).clips.first)
        #expect((clip.text?.count ?? 0) <= DeskClips.textLimit)
        #expect(clip.text?.contains("\n") == false)
    }

    @Test func picturesAndFiles() {
        let picture = ClipboardItem(payload: .image(file: "x.png", width: 800, height: 600), fingerprint: "p",
                                    copiedAt: .now)
        let file = ClipboardItem(payload: .file(path: "/Users/a/Invoice.pdf"), fingerprint: "f", copiedAt: .now)
        let clips = DeskClips.make([picture, file], planShows: nil, isOn: true, surface: nil) { _ in "t.png" }
        #expect(clips.clips.contains { $0.kind == .image && $0.thumb == "t.png" && $0.width == 800 })
        #expect(clips.clips.contains { $0.kind == .file && $0.text == "Invoice.pdf" && $0.thumb == nil })
    }

    @Test func linksNameACopyOrNothing() throws {
        let clip = DeskClips.clip(for: text("hello", 1))
        #expect(DeskClips.clipID(from: clip.copyURL) == clip.id)
        #expect(!DeskClips.isOpenURL(clip.copyURL))
        #expect(DeskClips.isOpenURL(DeskClips.openURL))
        #expect(DeskClips.clipID(from: URL(string: "airlock://clip?id=nope")!) == nil)
        #expect(DeskClips.clipID(from: URL(string: "https://clip?id=\(clip.id.uuidString)")!) == nil)
        #expect(!DeskClips.isOpenURL(URL(string: "airlock://shelf")!))
    }

    @Test func stalePicturesAreTheUnusedOnes() {
        let clips = DeskClips(clips: [.init(id: UUID(), kind: .image, copiedAt: .now, thumb: "1.png")])
        #expect(clips.staleThumbs(among: ["1.png", "2.png", "notes.txt"]) == ["2.png"])
    }

    @Test func snapshotRoundTrips() throws {
        let clips = DeskClips.make([text("a", 1)], planShows: nil, isOn: true, surface: .lightGlass)
        let data = try DeskShelf.encoder().encode(clips)
        #expect(try DeskShelf.decoder().decode(DeskClips.self, from: data) == clips)
    }
}

@Suite struct DeskSecretCheckTests {
    @Test(arguments: [
        "sk-proj-" + String(repeating: "Ab1Cd2Ef3G", count: 4),
        "ghp_" + String(repeating: "a1B2c3D4e5", count: 4),
        "AKIAIOSFODNN7EXAMPLE",
        "xoxb-1234567890-abcdefghijkl",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
        "export OPENAI_API_KEY=sk-" + String(repeating: "Zy9Xw8Vu7T", count: 4),
        "Tr0ub4dor&3",
        "Hunter2Hunter2",
        "q8Rz2LmP0vXa9KcW4bNt7YeJ1sHd6FgU",
    ])
    func hides(_ text: String) {
        #expect(DeskSecretCheck.looksSecret(text), "\(text)")
    }

    @Test(arguments: [
        "Let's meet at 10 on Thursday",
        "https://useairlock.app/download?ref=widget&utm_source=desk",
        "/Users/someone/Documents/Projects/airlock/Sources/AirlockCore",
        "someone@example.com",
        "3dace4e0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6",
        "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
        "user_id2",
        "v1.2.3",
        "camelCaseName",
        "hello",
        "swift build -c release",
        "Calle Mayor 14, 2º B, 28013 Madrid",
        "",
    ])
    func shows(_ text: String) {
        #expect(!DeskSecretCheck.looksSecret(text), "\(text)")
    }
}
