import Foundation

/// The folder agentic-notch owns on disk, and the two independent things inside
/// it. Pure and value-typed so the path rules are testable without touching a
/// filesystem.
///
/// Home root rather than `~/Documents` on purpose: Documents is TCC-protected,
/// and a tray that trips a permission prompt the first time you drag something
/// into it — then silently fails if denied — is a bad first contact with the
/// feature. Not Application Support either: no TCC gate, but it's hidden from
/// Finder, which makes it a poor drag-out target and a strange place to open a
/// terminal. `~/.airlock/` stays what it is, the hook machinery; this is
/// the visible counterpart.
///
/// `workspace` and `tray` are SIBLINGS. The tray is not an agents feature and
/// does not live inside the agent's working directory: clearing one can never
/// reach the other, and Claude writing files doesn't litter your shelf.
public struct WorkspaceLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Where the notch opens a terminal, instead of wherever Terminal happens
    /// to start.
    public var workspace: URL { root.appendingPathComponent("workspace", isDirectory: true) }
    /// The tray tab's folder. The folder IS the model — no database.
    public var tray: URL { root.appendingPathComponent("tray", isDirectory: true) }

    public static let environmentOverride = "AIRLOCK_WORKSPACE"

    /// `AIRLOCK_WORKSPACE` overrides the root — tests and demos only,
    /// matching `AIRLOCK_STATE_HOME` and `AIRLOCK_POLICY_HOME`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) -> WorkspaceLayout {
        if let override = environment[environmentOverride], !override.isEmpty {
            return WorkspaceLayout(root: URL(fileURLWithPath: override))
        }
        return WorkspaceLayout(root: homeDirectory.appendingPathComponent("Airlock", isDirectory: true))
    }

    /// Created on first use rather than at install: the DMG is drag-to-
    /// Applications with no installer hook, and this way it self-heals if the
    /// user deletes it.
    public func ensureExists(using fileManager: FileManager = .default) throws {
        for directory in [workspace, tray] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
    }

    /// A non-colliding name for an incoming file: "shot.png" beside an existing
    /// "shot.png" becomes "shot 2.png". Dropping the same file twice must not
    /// overwrite the first — the tray is a shelf, not a destination you
    /// deliberately save to.
    /// What to call pixels that arrived with no file behind them.
    ///
    /// `hint` is whatever the drag could be persuaded to say its name was — the
    /// last path component of a URL on the pasteboard, or an item provider's
    /// `suggestedName`. Its extension is dropped rather than kept: the bytes
    /// have already been normalised by the time this is asked, so a hint of
    /// "puppy.jpg" written out as PNG is "puppy.png" and never "puppy.jpg.png".
    ///
    /// Shared by both drop paths so a web image lands under the same name
    /// whether it crossed the cutout or the open panel. A hint that is empty,
    /// or is one of the path fragments a bare directory URL leaves behind,
    /// falls back rather than producing a file called "." or "/".
    public static func droppedImageName(hint: String?, extension ext: String) -> String {
        let base = hint.map { ($0 as NSString).deletingPathExtension } ?? ""
        guard !base.isEmpty, base != "/", base != "." else { return "Dropped image.\(ext)" }
        return "\(base).\(ext)"
    }

    public static func uniqueName(for desired: String, existing: Set<String>) -> String {
        guard existing.contains(desired) else { return desired }
        let name = (desired as NSString).deletingPathExtension
        let ext = (desired as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }
}
