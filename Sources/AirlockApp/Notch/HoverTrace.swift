import AppKit
import Foundation
import AirlockCore

/// Every hover edge and every presentation decision, appended to a file.
///
/// Hover bugs in this app all look the same from outside — "it did not open" or
/// "it did not close" — and they have three quite different causes: an event
/// that never arrived, an event the arbiter declined to act on, and a hold that
/// outlived what set it. Nothing on screen tells the three apart, and the
/// packaged app has no stderr to read (it is launched with `open`, and it is an
/// accessory app that screenshot tooling cannot even see).
///
/// Off unless asked for, by either route, because it writes on every pointer
/// crossing:
///
///     defaults write com.airlock.app HoverTrace -bool YES     # survives `open`
///     AIRLOCK_DEBUG=1                                          # for `swift run`
@MainActor
enum HoverTrace {
    /// Read every time, not cached in a `let`. A switch you cannot turn OFF
    /// without relaunching the app is not a switch — and the app being relaunched
    /// is exactly what a live investigation cannot afford.
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["AIRLOCK_DEBUG"] != nil
        || UserDefaults.standard.bool(forKey: "HoverTrace") }

    private static let url: URL? = {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let directory = support.appendingPathComponent("Airlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hover.log")
    }()

    private static let started = Date()

    /// `@autoclosure` because `apply` runs on every state change in the app and
    /// the interpolation is the expensive half. Switched off, this costs a Bool.
    static func note(_ line: @autoclosure () -> String) {
        // The gate first: `url` makes the folder the first time it is read.
        guard OwnerLogs.areOpen, isEnabled, let url else { return }
        let line = line()
        let stamp = String(format: "%7.2f", Date().timeIntervalSince(started))
        let data = Data("\(stamp)  \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // Owner-only: it records where the pointer is, which is nobody's
            // business but the owner's.
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        }
    }
}
