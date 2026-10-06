import Darwin
import Foundation

/// How Airlock rewrites an agent's own config file — `~/.claude/settings.json`,
/// `~/.codex/config.toml` — and nothing else of the user's. One place, because
/// the two used to carry identical copies of the same few lines and the same
/// mistakes, and because it now runs at every launch (`HookInstaller.upgrade`)
/// rather than only when somebody clicks Install.
///
/// What it promises about the file:
/// - **A link stays a link.** A dotfiles manager makes the config a symbolic
///   link into the user's own repository; the write goes through it to the real
///   file, which is where they expect their settings to change. The old way
///   replaced the path, found no file there to replace, failed, and left a
///   world-readable copy of the settings beside the link on every attempt.
/// - **Atomic.** The new contents go into a temp file beside the real file,
///   owner-only from the moment it exists, which is then swapped into place:
///   the agent never reads half a file. The temp file never outlives a failure.
/// - **Everything but the contents is kept** — permissions above all.
/// - **One backup, taken once,** of what was there before Airlock first wrote
///   it: a copy of the contents, owner-only, beside the path the user knows.
enum ConfigFileWriter {
    static let backupExtension = "airlock.bak"

    /// Replace the contents of the file at `url` with `data`.
    ///
    /// On any failure the file is as it was and nothing new is left beside it —
    /// this runs at launch, and a launch that fails to write must not leave a
    /// file behind each time it tries.
    static func replace(_ url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let target = try realFile(for: url)
        let folder = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // Read before anything changes: the backup is of what was here.
        let original = try? Data(contentsOf: target)
        let originalPermissions = permissions(of: target)

        let temp = folder.appendingPathComponent("\(target.lastPathComponent).airlock-\(UUID().uuidString).tmp")
        try createPrivateFile(at: temp, containing: data)
        do {
            _ = try fileManager.replaceItemAt(target, withItemAt: temp)
        } catch {
            // `replaceItemAt` leaves its source behind when it fails.
            try? fileManager.removeItem(at: temp)
            throw error
        }
        // `replaceItemAt` carries the original's permissions over, which is the
        // promise — so it is checked rather than assumed.
        if let originalPermissions, permissions(of: target) != originalPermissions {
            chmod(target.path, originalPermissions)
        }
        if let original {
            backUpOnce(original, to: url.appendingPathExtension(backupExtension))
        }
    }

    /// The file a write to `url` has to land in: `url` itself, or the file at
    /// the end of it when it is a symbolic link or a chain of them. Replacing
    /// the link instead would swap it for a copy and quietly detach the
    /// agent's settings from wherever the user keeps them.
    ///
    /// A link to a file that does not exist yet is followed to where that file
    /// would be, so writing creates it and the link starts working.
    static func realFile(for url: URL) throws -> URL {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        // Nothing there yet, or a link to something that is not there yet.
        var current = url
        for _ in 0..<32 {
            guard isSymbolicLink(current) else { return current }
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        throw POSIXError(.ELOOP)
    }

    /// A new file at `url` holding `data`, owner-only from the moment it
    /// exists — there is no instant at which it is readable by anyone else —
    /// whatever the umask. Never replaces anything already there, and never
    /// leaves half a file behind.
    static func createPrivateFile(at url: URL, containing data: Data) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = fchmod(fd, 0o600) == 0 ? 0 : errno
        if failure == 0 {
            failure = data.withUnsafeBytes { bytes -> Int32 in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += written
                }
                return fsync(fd) == 0 ? 0 : errno
            }
        }
        Darwin.close(fd)
        guard failure == 0 else {
            unlink(url.path)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// The file as it was before Airlock first wrote it — a copy of its
    /// contents, owner-only, made once and never refreshed. Taken only after a
    /// write has succeeded, so a failed one leaves nothing, and best effort: a
    /// backup that cannot be made does not undo a write that could.
    private static func backUpOnce(_ original: Data, to backup: URL) {
        // A link under this name is an older build's doing: it copied the
        // user's link rather than their file, so it points at the live file and
        // was never a backup of anything.
        if isSymbolicLink(backup) { try? FileManager.default.removeItem(at: backup) }
        guard !exists(backup) else { return }
        try? createPrivateFile(at: backup, containing: original)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// There, as whatever it is — a link counts, followed or not.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func permissions(of url: URL) -> mode_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_mode & 0o7777 : nil
    }
}
