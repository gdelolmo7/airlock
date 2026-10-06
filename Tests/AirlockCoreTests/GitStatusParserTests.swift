import XCTest
@testable import AirlockCore

final class GitStatusParserTests: XCTestCase {
    /// A clean checkout tracking a remote it is level with.
    private let clean = """
    # branch.oid a1b2c3d4
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +0 -0
    """

    func testCleanRepositoryOnABranch() {
        let status = GitStatusParser.parse(clean)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.changed, 0)
        XCTAssertEqual(status.untracked, 0)
        XCTAssertTrue(status.isClean)
        XCTAssertTrue(status.hasUpstream)
        XCTAssertFalse(status.isDetached)
    }

    func testAheadAndBehindAreReadFromTheHeader() {
        let status = GitStatusParser.parse("""
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -2
        """)
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 2)
    }

    /// Every kind of changed tracked file counts once: ordinary edits (1),
    /// renames and copies (2), and unmerged paths (u).
    func testEveryFlavourOfChangedFileIsCounted() {
        let status = GitStatusParser.parse("""
        # branch.head main
        1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift
        1 M. N... 100644 100644 100644 ccc ddd Sources/Model.swift
        2 R. N... 100644 100644 100644 eee fff R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 ggg hhh iii Conflicted.swift
        ? Untracked.swift
        ? another.txt
        """)
        XCTAssertEqual(status.changed, 4, "two edits, one rename, one unmerged")
        XCTAssertEqual(status.untracked, 2)
        XCTAssertFalse(status.isClean)
    }

    /// Ignored files only appear with --ignored and are never interesting —
    /// counting them would report a dirty tree for a repo with a .gitignore.
    func testIgnoredFilesAreNotCounted() {
        let status = GitStatusParser.parse("""
        # branch.head main
        ! .build/
        ! .DS_Store
        """)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(status.untracked, 0)
    }

    // MARK: - States that omit a header

    /// An agent that has left you detached is something to know, not something
    /// to paper over with a plausible-looking branch name.
    func testDetachedHeadHasNoBranch() {
        let status = GitStatusParser.parse("""
        # branch.oid a1b2c3d4
        # branch.head (detached)
        """)
        XCTAssertNil(status.branch)
        XCTAssertTrue(status.isDetached)
    }

    /// No upstream means no `# branch.ab` line at all. Ahead/behind are then
    /// meaningless rather than zero, and "0 ahead" of nothing is a small lie.
    func testABranchWithNoUpstreamSaysSoRatherThanClaimingZero() {
        let status = GitStatusParser.parse("""
        # branch.oid a1b2c3d4
        # branch.head feature/new-thing
        """)
        XCTAssertEqual(status.branch, "feature/new-thing")
        XCTAssertFalse(status.hasUpstream)
        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
    }

    /// A freshly initialised repository: git reports the oid as "(initial)".
    func testAnInitialRepositoryWithNoCommits() {
        let status = GitStatusParser.parse("""
        # branch.oid (initial)
        # branch.head main
        ? README.md
        """)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.untracked, 1)
        XCTAssertFalse(status.hasUpstream)
    }

    /// Captured verbatim from `git status --porcelain=v2 --branch` in this
    /// repository, rather than written from memory of the format — which is how
    /// a parser ends up confidently reading a shape git does not emit.
    ///
    /// It also pins something the format does: an untracked DIRECTORY collapses
    /// to one entry, so this reports two untracked paths, not every file below
    /// them. That matches what `git status` shows a person.
    func testAgainstRealGitOutput() {
        let status = GitStatusParser.parse("""
        # branch.oid d326631e866444977b8235694117e1487585219d
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        1 .M N... 100644 100644 100644 735bd71b51e8 735bd71b51e8 README.md
        ? Sources/AirlockCore/Git/
        ? Tests/AirlockCoreTests/GitStatusParserTests.swift
        ? scratch-probe.txt
        """)
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.hasUpstream)
        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
        XCTAssertEqual(status.changed, 1)
        XCTAssertEqual(status.untracked, 3)
        XCTAssertFalse(status.isClean)
    }

    // MARK: - Hostile input

    func testEmptyOutputIsNotACrash() {
        let status = GitStatusParser.parse("")
        XCTAssertNil(status.branch)
        XCTAssertTrue(status.isClean)
    }

    func testGarbageIsIgnoredRatherThanCounted() {
        let status = GitStatusParser.parse("""
        fatal: not a git repository (or any of the parent directories): .git
        """)
        XCTAssertTrue(status.isClean)
        XCTAssertNil(status.branch)
    }

    /// Branch names contain slashes and dots and are not otherwise sanitised.
    func testBranchNamesWithSlashesSurviveIntact() {
        let status = GitStatusParser.parse("# branch.head feature/JIRA-42/some.thing")
        XCTAssertEqual(status.branch, "feature/JIRA-42/some.thing")
    }

    /// A malformed ab line must not throw or produce a negative count.
    func testAMalformedAheadBehindLineDoesNotPoisonTheCounts() {
        let status = GitStatusParser.parse("""
        # branch.head main
        # branch.ab nonsense
        """)
        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
    }

    /// A path containing a newline is legal in git and arrives as separate
    /// lines. It must not be counted as an extra file, and must not be read as
    /// a header — the worst outcome would be a crafted filename changing the
    /// reported branch.
    func testAStrayLineIsNotMistakenForAnEntry() {
        let status = GitStatusParser.parse("""
        # branch.head main
        1 .M N... 100644 100644 100644 aaa bbb weird
        name.swift
        """)
        XCTAssertEqual(status.changed, 1)
        XCTAssertEqual(status.untracked, 0)
        XCTAssertEqual(status.branch, "main")
    }

    // MARK: - Mid-rebase and conflicts (W54)

    /// A rebase stopped on a conflict: git detaches HEAD and marks the file
    /// unmerged. The row has to say both, not "detached · 2 changed".
    func testAStoppedRebaseNamesTheConflictAndTheRebase() {
        var status = GitStatusParser.parse("""
        # branch.oid 534fbd1c2e
        # branch.head (detached)
        u UU N... 100644 100644 100644 100644 a1 b2 c3 Sources/App.swift
        1 M. N... 100644 100644 100644 d4 e5 docs/notes.md
        """)
        XCTAssertEqual(status.changed, 2, "an unmerged file is still a changed one")
        XCTAssertEqual(status.conflicted, 1)
        XCTAssertEqual(status.facts, [.conflicts(1), .changed(1)], "the conflict is not counted twice")
        XCTAssertEqual(status.factsLine, "1 conflict · 1 changed")
        XCTAssertEqual(status.headLabel, "No branch", "git's word for it is not the person's")
        status.operation = GitOperation.inProgress(markers: ["rebase-merge", "CHERRY_PICK_HEAD"])
        XCTAssertEqual(status.headLabel, "rebasing")
    }

    func testTheOperationIsReadFromItsMarker() {
        XCTAssertEqual(GitOperation.inProgress(markers: ["rebase-apply"]), .rebase)
        XCTAssertEqual(GitOperation.inProgress(markers: ["MERGE_HEAD"]), .merge)
        XCTAssertEqual(GitOperation.inProgress(markers: ["CHERRY_PICK_HEAD"]), .cherryPick)
        XCTAssertEqual(GitOperation.inProgress(markers: ["REVERT_HEAD"]), .revert)
        XCTAssertNil(GitOperation.inProgress(markers: []))
        XCTAssertNil(GitOperation.inProgress(markers: ["ORIG_HEAD", "FETCH_HEAD"]),
                     "left behind by finished commands, not a sign of one under way")
    }

    /// No zeroes: "0 changed · 3 new" was the session row's way of saying it.
    func testFactsLeaveOutWhatIsZero() {
        XCTAssertEqual(GitStatus(branch: "main", untracked: 3).factsLine, "3 new")
        XCTAssertEqual(GitStatus(branch: "main", changed: 2).factsLine, "2 changed")
        XCTAssertEqual(GitStatus(branch: "main").factsLine, "clean")
        XCTAssertEqual(GitStatus(branch: "main").facts, [])
        XCTAssertEqual(GitStatus(branch: nil, changed: 3, conflicted: 3).factsLine, "3 conflicts")
    }

    func testALinkedWorktreesGitFolderIsFollowed() {
        let root = URL(fileURLWithPath: "/Users/you/Code/app-b3")
        XCTAssertEqual(GitDirectory.target(ofDotGitFile: "gitdir: /Users/you/Code/app/.git/worktrees/app-b3\n",
                                           root: root)?.path,
                       "/Users/you/Code/app/.git/worktrees/app-b3")
        XCTAssertEqual(GitDirectory.target(ofDotGitFile: "gitdir: ../app/.git/worktrees/b3", root: root)?.path,
                       "/Users/you/Code/app/.git/worktrees/b3")
        XCTAssertNil(GitDirectory.target(ofDotGitFile: "", root: root))
        XCTAssertNil(GitDirectory.target(ofDotGitFile: "something else", root: root))
    }
}
