import Foundation

/// Persists clipboard history beside the session cache.
///
/// `~/Library/Application Support/Airlock/clipboard.json`, 0600, with image
/// bytes in a sibling `clipboard-images/` directory. The permissions are not
/// decoration: whatever you have copied today is at least as sensitive as the
/// commands in `sessions.json`. `AIRLOCK_STATE_HOME` overrides the
/// directory, for tests.
public struct ClipboardStore: Sendable {
    public let fileURL: URL
    public let imagesURL: URL

    public init(fileURL: URL = ClipboardStore.defaultFileURL()) {
        self.fileURL = fileURL
        imagesURL = fileURL.deletingLastPathComponent().appendingPathComponent("clipboard-images")
    }

    /// The directory Settings shows, tilde-abbreviated.
    ///
    /// Derived rather than written out again: the copy in Settings still said
    /// `AgenticNotch` long after the rename, because a hardcoded path has
    /// nothing keeping it honest. Both file names below hang off this.
    public var displayDirectory: String {
        (fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// `clipboard.json` and `clipboard-images` — named so the privacy section
    /// can say which two things it means without repeating either string.
    public var displayFileName: String { fileURL.lastPathComponent }
    public var displayImagesName: String { imagesURL.lastPathComponent }

    public static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIRLOCK_STATE_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("clipboard.json")
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Airlock/clipboard.json")
    }

    /// Empty on missing or corrupt, never fatal — a cache, not a source of
    /// truth. Rows whose image file has gone are dropped here rather than
    /// rendering as blanks nobody can explain.
    public func load() -> ClipboardHistory {
        guard let data = try? Data(contentsOf: fileURL) else { return ClipboardHistory() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let history = try decoder.decode(ClipboardHistory.self, from: data)
            return ClipboardHistory(items: history.items.filter { item in
                guard let file = item.imageFile else { return true }
                return FileManager.default.fileExists(atPath: imagesURL.appendingPathComponent(file).path)
            })
        } catch {
            Log.widgets.error(
                "ignoring corrupt clipboard cache at \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return ClipboardHistory()
        }
    }

    public func save(_ history: ClipboardHistory) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(history)

        try makeDirectories()
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: fileURL.path)
    }

    // MARK: - Images

    public func imageURL(for file: String) -> URL {
        imagesURL.appendingPathComponent(file)
    }

    /// Returns the file name to store on the item.
    public func writeImage(_ data: Data, extension ext: String = "png") throws -> String {
        try makeDirectories()
        let name = "\(UUID().uuidString).\(ext)"
        let url = imagesURL.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return name
    }

    /// Byte size of every stored image, by file name.
    public func imageSizes() -> [String: Int] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: imagesURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(into: [:]) { result, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            result[url.lastPathComponent] = size
        }
    }

    public func deleteImage(_ file: String) {
        try? FileManager.default.removeItem(at: imageURL(for: file))
    }

    /// Sweeps files no row points at any more.
    ///
    /// Called after every mutation that can drop rows — trimming to capacity,
    /// deleting, clearing. Without it the history obeys its cap while the
    /// directory behind it grows without bound, which is the kind of leak that
    /// only shows up as a full disk months later.
    @discardableResult
    public func pruneOrphanedImages(keeping referenced: Set<String>) -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: imagesURL, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for url in contents where !referenced.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    /// Used by "clear everything" — a history the user has explicitly wiped must
    /// not leave the pictures behind.
    public func deleteAllImages() {
        try? FileManager.default.removeItem(at: imagesURL)
    }

    private func makeDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: imagesURL, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    }
}
