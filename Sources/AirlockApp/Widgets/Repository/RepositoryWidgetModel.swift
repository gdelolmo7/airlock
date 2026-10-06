import AirlockCore
import Foundation
import Observation

/// Git status for the repositories agents are actually working in.
///
/// The app knows each session's working directory — nothing else on the menu bar
/// does — so it can answer "what has the agent done to my checkout" without
/// switching windows. That is the whole reason this exists; a generic git widget
/// would have to ask which repo, and the answer is already known.
///
/// A subprocess, not a library. `git` is the only thing that agrees with `git`,
/// and the alternative is vendoring a parser that drifts.
@MainActor
@Observable
final class RepositoryWidgetModel {
    /// One row per distinct repository, in the order sessions supplied them.
    private(set) var repositories: [Repository] = []

    struct Repository: Identifiable, Equatable {
        /// The repository root, which is also the id — two sessions in the same
        /// checkout are one row, not two.
        let root: URL
        let status: GitStatus
        var id: URL { root }
        var name: String { root.lastPathComponent }
    }

    init() {}

    /// For the state gallery only: these rows and nothing else. No `git` is
    /// run and nothing is watched; `update(workingDirectories:)` is never
    /// called on it.
    init(previewing repositories: [Repository]) {
        self.repositories = repositories
    }

    /// The checkout a session is working in, matched by path.
    ///
    /// **Folds the orphan repository rows into the sessions that own them.** A
    /// branch listed on its own was a second visual language for a fact about
    /// the first — you read "fix/reducer-v2" in one place and "Billing
    /// page review" in another and had to join them yourself.
    ///
    /// Prefix matching rather than `repositoryRoot(of:)`, which is async and
    /// touches the filesystem: the roots are already resolved and a session's
    /// cwd is a path inside one of them. Longest root wins, so a checkout nested
    /// inside another resolves to the inner one.
    func repository(for cwd: String?) -> Repository? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return repositories
            .filter { cwd == $0.root.path || cwd.hasPrefix($0.root.path + "/") }
            .max { $0.root.path.count < $1.root.path.count }
    }

    var isEnabled: Bool = WidgetToggle.stored("widget.repository.enabled", default: true) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            if !isEnabled { repositories = [] }
        }
    }

    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.repository.enabled", defaultValue: true)
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Roots we have already resolved from a working directory, so the
    /// rev-parse only happens once per session rather than on every refresh.
    @ObservationIgnored private var rootsByDirectory: [String: URL?] = [:]

    var onChange: (() -> Void)?

    /// Called with every live session's working directory. Debounced, because
    /// session state changes far more often than a checkout does.
    func update(workingDirectories: [String]) {
        guard isEnabled else { return }
        refreshTask?.cancel()
        let directories = Array(Set(workingDirectories)).sorted()
        guard !directories.isEmpty else {
            if !repositories.isEmpty { repositories = []; onChange?() }
            return
        }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reload(directories)
        }
    }

    private func reload(_ directories: [String]) async {
        var seen: [URL] = []
        var found: [Repository] = []

        for directory in directories {
            let root: URL?
            if let cached = rootsByDirectory[directory] {
                root = cached
            } else {
                root = await Git.repositoryRoot(of: directory)
                rootsByDirectory[directory] = root
            }
            // Not every agent runs in a checkout — a session in ~/Documents is
            // perfectly normal and simply has no row.
            guard let root, !seen.contains(root) else { continue }
            seen.append(root)
            guard let status = await Git.status(at: root) else { continue }
            found.append(Repository(root: root, status: status))
        }

        guard found != repositories else { return }
        repositories = found
        onChange?()
    }
}

/// The two git calls this needs, as subprocesses.
///
/// Deliberately not `AppleScriptClient`-style in-process: git is a program, and
/// running it is the only way to get an answer that matches what the user sees
/// in their own terminal.
private enum Git {
    static func repositoryRoot(of directory: String) async -> URL? {
        guard let output = await run(["rev-parse", "--show-toplevel"], in: directory),
              !output.isEmpty else { return nil }
        return URL(fileURLWithPath: output)
    }

    static func status(at root: URL) async -> GitStatus? {
        guard let output = await run(["status", "--porcelain=v2", "--branch"], in: root.path)
        else { return nil }
        var status = GitStatusParser.parse(output)
        status.operation = operation(at: root)
        return status
    }

    /// A rebase or merge under way, read from the markers git leaves in its
    /// folder rather than from a second subprocess: a few file checks, and
    /// this runs on every session change.
    private static func operation(at root: URL) -> GitOperation? {
        let files = FileManager.default
        let dotGit = root.appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: dotGit.path, isDirectory: &isFolder) else { return nil }
        let folder: URL
        if isFolder.boolValue {
            folder = dotGit
        } else {
            guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                  let target = GitDirectory.target(ofDotGitFile: contents, root: root) else { return nil }
            folder = target
        }
        let present = GitOperation.markers.filter {
            files.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return GitOperation.inProgress(markers: Set(present))
    }

    /// nil on any failure — not a repository, git missing, or a timeout. A
    /// widget that cannot read a repo shows nothing; it never guesses.
    private static func run(_ arguments: [String], in directory: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                // A repository on a stalled network mount can hang git forever,
                // and this runs off session activity — so the pipe is drained
                // before waiting, which is what stops a full pipe deadlocking
                // the child — and the wait itself carries a deadline. It did
                // not until this change: the comment claimed "never waited on
                // unbounded" above a bare `waitUntilExit`, and that mattered,
                // because this function is cited elsewhere as the shape to copy.
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                // Never prompt: a credential helper waiting on stdin would hang
                // a background process nobody can see to cancel.
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GIT_OPTIONAL_LOCKS"] = "0" // never take the index lock
                process.environment = environment

                do { try process.run() } catch {
                    return continuation.resume(returning: nil)
                }
                // Bounded now, which is what the comment above always claimed.
                // Terminating closes the pipe, so this releases the read too.
                let deadline = DispatchWorkItem { process.terminate() }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
                // `readToEnd()` throws where `readDataToEndOfFile()` raised an
                // Objective-C exception that Swift cannot catch, taking the
                // app down over a repository row. A read error is a failure
                // like any other here: nil, never a guess at a status.
                let data: Data?
                do {
                    data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                } catch {
                    data = nil
                }
                process.waitUntilExit()
                deadline.cancel()
                guard process.terminationStatus == 0, let data else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
