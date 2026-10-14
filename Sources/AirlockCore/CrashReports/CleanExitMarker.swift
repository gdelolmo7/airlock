import Foundation

/// Whether the last run of the app ended the way a run should.
///
/// A file is written when the app starts and removed when it quits normally
/// (Quit in the menu, a logout, an update relaunching it). Found still there
/// at the next start, the last run ended some other way: a crash, a hang the
/// person force-quit, a power cut. That is the moment to ask whether crash
/// reports may be sent (`CrashReportPolicy.asksAfterUnexpectedQuit`).
///
/// It cannot tell a crash from a force quit, and does not try: either one is
/// a run that went wrong, and the question is asked once at most.
///
/// Nothing reads the file's contents. It holds the process number, for a
/// person who finds it and wonders.
public struct CleanExitMarker: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The app's own, next to its other files.
    public static var standard: CleanExitMarker {
        CleanExitMarker(url: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/running"))
    }

    /// Marks this run as started.
    /// - Returns: whether the previous run never marked its end.
    @discardableResult
    public func beginRun() -> Bool {
        let manager = FileManager.default
        let previousRunStillOpen = manager.fileExists(atPath: url.path)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(getpid())\n".utf8).write(to: url, options: .atomic)
        return previousRunStillOpen
    }

    /// Marks this run as ended normally.
    public func endRun() {
        try? FileManager.default.removeItem(at: url)
    }
}
