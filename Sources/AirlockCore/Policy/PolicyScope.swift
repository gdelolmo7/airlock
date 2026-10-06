import Foundation

/// Which policy file the Rules pane is editing.
///
/// `PolicyStore.load` merges global and project, which is right for the engine
/// and useless for an editor: "where did this rule go" is the one question a
/// merged list cannot answer, and it is the question people ask after clicking
/// Always.
public enum PolicyScope: Equatable, Hashable, Sendable {
    case everywhere
    case project(root: String)

    public var projectRoot: String? {
        if case .project(let root) = self { return root }
        return nil
    }

    /// The segment's title. The last path component, so a monorepo package reads
    /// as "web" rather than as a path nobody can scan — which is also why the
    /// full path is drawn underneath it wherever this is shown.
    public var label: String {
        switch self {
        case .everywhere: return "Everywhere"
        case .project(let root): return URL(fileURLWithPath: root).lastPathComponent
        }
    }

    /// A directory path becomes a scope, or it does not.
    ///
    /// **The root is the agent's `cwd`, verbatim — never the git top level.**
    /// `BridgeServer` hands `payload.cwd` straight to the engine and
    /// `projectFileURL` is a plain join with no walk-up, so an agent started in
    /// `outrun-app/packages/web` is gated by `packages/web/.airlock/policy.yaml`.
    /// A pane that resolved the repository root would open, list and edit a file
    /// the gate never reads — a worse bug than the one it exists to fix.
    ///
    /// Refused: empty, relative, not an existing directory, and the global
    /// file's own folder — where a "project" scope would edit the global file
    /// under another name.
    public static func project(_ root: String, globalFile: URL) -> PolicyScope? {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard standardized.path != globalFile.deletingLastPathComponent().standardizedFileURL.path
        else { return nil }
        return .project(root: standardized.path)
    }

    /// Everything the switch may offer, in order, deduped.
    ///
    /// The SELECTED scope is always included, whatever else is live. Sessions
    /// are pruned within minutes while the settings window is built once and
    /// kept, so a list drawn from live sessions alone would shrink out from
    /// under the selection mid-edit — and the next rule added would land in the
    /// global file, which is precisely the "where did this rule go" failure the
    /// switch exists to prevent.
    public static func candidates(selected: PolicyScope,
                                  remembered: String?,
                                  sessions: [String],
                                  globalFile: URL) -> [PolicyScope] {
        var seen = Set<String>()
        var result: [PolicyScope] = []
        for root in [selected.projectRoot, remembered].compactMap({ $0 }) + sessions {
            guard let scope = project(root, globalFile: globalFile),
                  let key = scope.projectRoot, seen.insert(key).inserted else { continue }
            result.append(scope)
        }
        return result
    }
}

/// What the rules region shows, which is four things and not two.
///
/// `LoadResult.problems` is kept separate from "no rules" precisely so a broken
/// file cannot look like an empty one — and the pane is the only place that
/// promise gets kept. Under a project scope the difference is not cosmetic: a
/// file that fails to parse is IGNORED ENTIRELY, so the project's own deny rules
/// are not in force and only the built-in risk floor still holds.
public enum RulesListState: Equatable, Sendable {
    /// No file at this scope yet. Project files do not exist until asked for.
    case missing
    /// The file is there and did not parse. Nothing in it is in effect.
    case unreadable
    /// Parsed, and genuinely has no rules.
    case empty
    case listing

    public static func of(exists: Bool, parseFailed: Bool, isEmpty: Bool) -> RulesListState {
        if parseFailed { return .unreadable }
        if !exists { return .missing }
        return isEmpty ? .empty : .listing
    }
}
