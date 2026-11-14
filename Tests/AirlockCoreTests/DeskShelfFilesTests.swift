import Foundation
import Testing
@testable import AirlockCore

@Suite struct DeskShelfFilesTests {
    func file(_ name: String, _ minutesAgo: Double, size: Int64 = 100, folder: Bool = false,
              thumb: String? = nil) -> DeskShelfFiles.File {
        .init(name: name, size: size, modified: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
              isFolder: folder, thumb: thumb)
    }

    @Test func newestFirstUpToTheLimitCountingEveryFile() {
        let files = (0..<10).map { file("f\($0).pdf", Double($0), size: 10) }
        let shelf = DeskShelfFiles.make(files.shuffled(), isOn: true, surface: .darkGlass)
        #expect(shelf.files.map(\.name) == (0..<8).map { "f\($0).pdf" })
        #expect(shelf.count == 10)
        #expect(shelf.totalSize == 100)
        #expect(shelf.isOn && shelf.surface == .darkGlass)
    }

    @Test func offCarriesNoFiles() {
        let shelf = DeskShelfFiles.make([file("a.pdf", 1)], isOn: false, surface: nil)
        #expect(shelf.files.isEmpty && shelf.count == 0 && shelf.totalSize == 0 && !shelf.isOn)
    }

    @Test func fileLinkTakesAPlainNameOnly() throws {
        let url = try #require(file("Invoice March.pdf", 1).openURL)
        #expect(DeskShelfFiles.fileName(from: url) == "Invoice March.pdf")
        #expect(!DeskShelfFiles.isOpenURL(url))
        for bad in ["../x", ".hidden", "a/b", "", "a:b", ".", ".."] {
            let link = try #require(file(bad, 1).openURL)
            #expect(DeskShelfFiles.fileName(from: link) == nil, "\(bad)")
        }
        #expect(DeskShelfFiles.fileName(from: URL(string: "https://shelf?file=a")!) == nil)
    }

    @Test func bareLinkOpensTheShelf() {
        #expect(DeskShelfFiles.isOpenURL(DeskShelfFiles.openURL))
        #expect(!DeskShelfFiles.isOpenURL(URL(string: "airlock://join")!))
    }

    @Test func pictureNameChangesWithTheFile() {
        let a = file("a.png", 1), b = file("a.png", 2)
        #expect(a.thumbKey != b.thumbKey)
        #expect(a.thumbKey == file("a.png", 1).thumbKey)
        #expect(a.thumbKey.hasSuffix(".png"))
    }

    @Test func titleAndKind() {
        #expect(file("Beach day.jpg", 1).title == "Beach day")
        #expect(file("Beach day.jpg", 1).kind == "JPG")
        #expect(file("Project.notes", 1, folder: true).title == "Project.notes")
        #expect(file("Project.notes", 1, folder: true).kind == DeskShelfWords.folder)
        #expect(file("README", 1).kind == DeskShelfWords.file)
        #expect(file(".env", 1).title == ".env")
    }

    @Test func stalePicturesAreTheUnusedOnes() {
        let shelf = DeskShelfFiles(files: [file("a.png", 1, thumb: "1.png"), file("b", 2)])
        #expect(shelf.staleThumbs(among: ["1.png", "2.png", "1.png.icon"]) == ["2.png"])
    }

    @Test func snapshotRoundTrips() throws {
        let shelf = DeskShelfFiles.make([file("a.png", 1, thumb: "1.png")], isOn: true, surface: .lightGlass)
        let data = try DeskShelf.encoder().encode(shelf)
        #expect(try DeskShelf.decoder().decode(DeskShelfFiles.self, from: data) == shelf)
    }
}
