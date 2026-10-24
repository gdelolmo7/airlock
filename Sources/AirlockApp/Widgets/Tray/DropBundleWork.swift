import AirlockCore
import Foundation

/// The drop box's zip: everything on the drag in one archive, the way
/// Finder's Compress makes it, so it opens with a double click on any Mac or
/// PC.
enum DropBundleWork {
    static func zip(_ inputs: [PictureInput], at destination: URL) throws {
        let manager = FileManager.default
        let urls = try inputs.map { try DropWork.url($0) }
        guard let first = urls.first else { throw DropWork.Failure.unreadable }
        if urls.count == 1 {
            try ditto(first, to: destination)
            return
        }
        // Several items: copied side by side into a folder named after the
        // zip, which is what opening it gives back.
        let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent(destination.deletingPathExtension().lastPathComponent)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        var taken: Set<String> = []
        for url in urls {
            var name = url.lastPathComponent
            var copy = 2
            while taken.contains(name.lowercased()) {
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                name = ext.isEmpty ? "\(stem) \(copy)" : "\(stem) \(copy).\(ext)"
                copy += 1
            }
            taken.insert(name.lowercased())
            do {
                try manager.copyItem(at: url, to: folder.appendingPathComponent(name))
            } catch {
                throw DropWork.Failure.unreadable
            }
        }
        try ditto(folder, to: destination)
    }

    /// `ditto` is what Finder's Compress runs: it keeps the Mac's extras in
    /// the hidden folder every unzipper knows to skip.
    private static func ditto(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw DropWork.Failure.unwritable }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DropWork.Failure.unwritable }
    }
}
