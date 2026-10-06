import Foundation

/// What a repository looks like right now, in the few facts worth a glance.
///
/// The point of this in a notch is not to be a git client. It is that the app
/// already knows which directory each agent session is working in — nothing else
/// on the menu bar does — so it can answer "what has Claude actually done to my
/// checkout" without switching windows.
public struct GitStatus: Equatable, Sendable {
    /// nil on a detached HEAD, which is a state worth showing rather than
    /// papering over: an agent that has left you detached is something to know.
    public let branch: String?
    public let ahead: Int
    public let behind: Int
    /// Tracked files with any change at all, staged or not. One number, because
    /// the staged/unstaged split is a thing you open a terminal for.
    public let changed: Int
    public let untracked: Int
    /// Of `changed`, the files git could not merge and is waiting on. A rebase
    /// stopped on a conflict used to read "detached · 2 changed", which is the
    /// one moment a repository row most needs to say something else.
    public let conflicted: Int
    /// A rebase, merge, cherry-pick or revert that is under way. Not in git's
    /// status output: the model reads it from the repository's own folder
    /// (`GitOperation.inProgress(markers:)`).
    public var operation: GitOperation?
    /// True when the branch has no upstream — ahead/behind are then meaningless
    /// rather than zero, and a row claiming "0 ahead" of nothing is a small lie.
    public let hasUpstream: Bool

    public init(branch: String?, ahead: Int = 0, behind: Int = 0,
                changed: Int = 0, untracked: Int = 0, conflicted: Int = 0,
                operation: GitOperation? = nil, hasUpstream: Bool = false) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
        self.untracked = untracked
        self.conflicted = min(conflicted, changed)
        self.operation = operation
        self.hasUpstream = hasUpstream
    }

    public var isClean: Bool { changed == 0 && untracked == 0 }
    public var isDetached: Bool { branch == nil }

    /// One thing worth saying about the files.
    public enum Fact: Hashable, Sendable {
        case conflicts(Int), changed(Int), new(Int)

        public var text: String {
            switch self {
            case .conflicts(let count): count == 1 ? "1 conflict" : "\(count) conflicts"
            case .changed(let count): "\(count) changed"
            case .new(let count): "\(count) new"
            }
        }
    }

    /// What follows the branch, in the words both places that draw a
    /// repository use: the Agents tab's repository rows and a session's
    /// detail. They used to say the same thing two ways ("2 changed" beside a
    /// dot, "2 changed · 0 new" as a sentence, zero included).
    ///
    /// Conflicts first and on their own, and not counted again as changed.
    /// Empty when the checkout is clean.
    public var facts: [Fact] {
        var facts: [Fact] = []
        if conflicted > 0 { facts.append(.conflicts(conflicted)) }
        if changed - conflicted > 0 { facts.append(.changed(changed - conflicted)) }
        if untracked > 0 { facts.append(.new(untracked)) }
        return facts
    }

    /// The same facts as one line, for a place with no room for dots.
    public var factsLine: String {
        isClean ? "clean" : facts.map(\.text).joined(separator: " · ")
    }

    /// What stands where the branch name goes: the operation under way, since
    /// git detaches HEAD for a rebase and "No branch" alone reads as an
    /// accident. "detached" was git's word for no branch, not a person's.
    public var headLabel: String {
        if let operation { return operation.label }
        return branch ?? "No branch"
    }
}

/// Something git has started and not finished, which leaves the checkout in
/// a state that needs the person before an agent goes on.
public enum GitOperation: Equatable, Sendable {
    case rebase, merge, cherryPick, revert

    public var label: String {
        switch self {
        case .rebase: "rebasing"
        case .merge: "merging"
        case .cherryPick: "cherry-picking"
        case .revert: "reverting"
        }
    }

    /// The files and folders, in the repository's git folder, whose presence
    /// says which. Checked by the model, which knows where that folder is.
    public static let markers = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]

    /// From the markers that exist. A rebase wins: it replays commits by
    /// cherry-picking them, so a stopped rebase can carry CHERRY_PICK_HEAD too,
    /// and "rebasing" is what the person started.
    public static func inProgress(markers present: Set<String>) -> GitOperation? {
        if present.contains("rebase-merge") || present.contains("rebase-apply") { return .rebase }
        if present.contains("MERGE_HEAD") { return .merge }
        if present.contains("CHERRY_PICK_HEAD") { return .cherryPick }
        if present.contains("REVERT_HEAD") { return .revert }
        return nil
    }
}

/// Reads `git status --porcelain=v2 --branch`.
///
/// **v2 and not v1.** The older format cannot express ahead/behind at all, and
/// its rename encoding is ambiguous — the v2 header lines carry the branch and
/// tracking counts as data rather than as something to scrape from prose that
/// changes with locale.
///
/// Parsing rather than trusting: git's output is stable, but a repository can be
/// mid-rebase, detached, freshly initialised with no commits, or have no
/// upstream, and each of those omits a header line another might rely on.
public enum GitStatusParser {
    public static func parse(_ output: String) -> GitStatus {
        var branch: String?
        var ahead = 0
        var behind = 0
        var changed = 0
        var untracked = 0
        var conflicted = 0
        var hasUpstream = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                // git spells a detached HEAD exactly this way.
                branch = name == "(detached)" ? nil : name
            } else if line.hasPrefix("# branch.upstream ") {
                hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                let counts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for count in counts {
                    let magnitude = Int(count.dropFirst()) ?? 0
                    if count.hasPrefix("+") { ahead = magnitude }
                    if count.hasPrefix("-") { behind = magnitude }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                // Ordinary change, rename/copy, and unmerged respectively. All
                // three are "this tracked file is not what HEAD says".
                changed += 1
                if line.hasPrefix("u ") { conflicted += 1 }
            } else if line.hasPrefix("? ") {
                untracked += 1
            }
            // "! " is ignored-file output, which only appears with
            // --ignored and is never interesting here.
        }

        return GitStatus(branch: branch, ahead: ahead, behind: behind,
                         changed: changed, untracked: untracked, conflicted: conflicted,
                         hasUpstream: hasUpstream)
    }
}

/// Where a checkout keeps its git folder, without running git.
///
/// Usually `.git` itself. In a linked worktree (`git worktree add`), `.git` is
/// a one-line file pointing at the real folder, and that folder is the one
/// holding the worktree's own rebase and merge markers.
public enum GitDirectory {
    /// The folder a `.git` FILE points at, or nil when it says nothing
    /// usable. A relative path is relative to the checkout, as git writes it.
    public static func target(ofDotGitFile contents: String, root: URL) -> URL? {
        guard let line = contents.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path).standardizedFileURL
    }
}
