import Foundation

/// A tool call in words a person reads, rather than the identifier a program
/// matches on.
///
/// The notch printed tool names as they arrived, and one screenshot of real
/// session cards held two of them: `Ran mcp__7adb9f71-433e-414a-a8a1-
/// f17b52e5037f__trelloWriteCard`, and `Auto-run (auto) · Allow
/// mcp__Claude_Browser__preview_list?` — a question, in a mode where nothing was
/// being asked. An MCP tool is named `mcp__<server>__<tool>`, and for a claude.ai
/// connector the server is a UUID: an id, not a name, and noise to anyone who has
/// not read the protocol. This is the one place that turns any of it into "Used
/// Trello: write card", so an activity line, a card headline and a passive line
/// cannot each invent their own wording.
///
/// **Presentation only.** `PermissionRequest.toolName` stays raw, because policy
/// rules match on it — a rule naming `mcp__…__trelloWriteCard` has to go on
/// meaning what it meant.
public enum ToolPhrase {
    /// Where the call is when the line is read. Three forms, because the same
    /// call is asked about, then watched, then reported.
    public enum Moment: Sendable, Equatable {
        /// Waiting on the user: a card headline. An instruction to approve —
        /// "Read notes.md", "Edit main.swift" — or, for a tool with no verb of
        /// ours to lead with, "Allow Trello: write card?".
        case asking
        /// About to run, or running, with nobody asked: "Reading notes.md".
        /// Never a question — the session has already decided.
        case running
        /// It ran: "Read notes.md", "Used Trello: write card".
        case finished
        /// It did NOT run, and will not: the subject of a line about a call
        /// that was refused. No tense, and never a question — "Auto-denied ·
        /// Running: rm -rf ./dist" said the blocked command was under way, and
        /// "Auto-denied · Allow Trello: write card?" asks about one that has
        /// already been answered.
        case refused
    }

    /// The whole line for one call.
    ///
    /// `input` is the tool's own input, used where it names a better noun than
    /// the tool does — the file, the site, the search — and never to print
    /// shell text: a command gets Claude's description of it, which it writes
    /// for every one.
    public static func phrase(tool: String, input: [String: Any]?, _ moment: Moment) -> String {
        builtIn(tool, input, moment) ?? named(tool, moment)
    }

    /// The tool itself: "Trello: write card", "Claude Browser: preview list",
    /// "create file" (a connector whose tool name does not say whose it is).
    ///
    /// Anything that is not an MCP tool comes back unchanged. Built-in names are
    /// already the names Claude Code shows people — Read, Bash, WebSearch — and
    /// they are what a rule is written with.
    public static func name(_ tool: String) -> String {
        MCPTool(tool)?.label ?? tool
    }

    public static func isMCP(_ tool: String) -> Bool {
        tool.hasPrefix(MCPTool.prefix)
    }

    /// Free text with any MCP tool name in it replaced by `name(_:)`.
    ///
    /// For text Airlock did not write — a hook's notification message — which
    /// can quote a tool the way the agent knows it. Everything else is left
    /// exactly as it was.
    public static func humanizingToolNames(in text: String) -> String {
        guard text.contains(MCPTool.prefix) else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: MCPTool.prefix) {
            result += rest[..<start.lowerBound]
            // What Claude Code allows in a server or tool name, and nothing
            // else — so trailing punctuation stays behind.
            let end = rest[start.lowerBound...].firstIndex { !isNameCharacter($0) } ?? rest.endIndex
            result += name(String(rest[start.lowerBound..<end]))
            rest = rest[end...]
        }
        return result + rest
    }

    // MARK: - Built-in tools

    private static let read = Verb("read", "reading", "read")
    private static let write = Verb("write", "writing", "wrote")
    private static let edit = Verb("edit", "editing", "edited")
    private static let search = Verb("search", "searching", "searched")
    private static let list = Verb("list", "listing", "listed")
    private static let lookFor = Verb("look for", "looking for", "looked for")
    private static let lookUp = Verb("look up", "looking up", "looked up")
    private static let update = Verb("update", "updating", "updated")
    private static let check = Verb("check", "checking", "checked")
    private static let use = Verb("use", "using", "used")
    private static let run = Verb("run", "running", "ran")
    private static let stop = Verb("stop", "stopping", "stopped")
    private static let switchTo = Verb("switch", "switching", "switched")

    /// Claude Code's own tools. Nil for anything else, which `named` handles.
    private static func builtIn(_ tool: String, _ input: [String: Any]?, _ moment: Moment) -> String? {
        /// A string input, whitespace collapsed, or nil when empty.
        func text(_ key: String) -> String? {
            guard let value = input?[key] as? String else { return nil }
            let flat = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return flat.isEmpty ? nil : flat
        }
        func file(_ key: String) -> String? {
            text(key).map { URL(fileURLWithPath: $0).lastPathComponent }
        }

        switch tool {
        case "Bash":
            // Claude writes a natural-language description for every command —
            // show that, never the raw shell text. The fallbacks are the
            // wording these lines had before this type existed.
            if let description = text("description") { return description }
            let command = text("command").map { String($0.prefix(40)) }
            switch moment {
            case .asking: return "Run shell command"
            case .running: return command.map { "Running: \($0)" } ?? "Running a command"
            case .finished: return command.map { "Ran: \($0)" } ?? "Ran command"
            // The command itself, because with no description of Claude's
            // there is nothing else that says WHICH one was refused.
            case .refused: return command ?? "a shell command"
            }
        case "Read":
            return read.line(moment, file("file_path") ?? "a file")
        case "NotebookRead":
            return read.line(moment, file("notebook_path") ?? "a notebook")
        case "Write":
            // Asked as "Edit", like the two below: the card has always said so,
            // and it is the same approval.
            return (moment == .asking ? edit : write).line(moment, file("file_path") ?? "file")
        case "Edit", "MultiEdit":
            return edit.line(moment, file("file_path") ?? "file")
        case "NotebookEdit":
            return edit.line(moment, file("notebook_path") ?? "a notebook")
        case "Glob":
            // The pattern is a glob — `**/*.swift` — which is exactly the kind
            // of text this exists to keep off the notch.
            return lookFor.line(moment, "files")
        case "Grep":
            return search.line(moment, text("pattern").flatMap(plainSearch).map { "files for \($0)" } ?? "files")
        case "LS":
            return list.line(moment, file("path") ?? "a folder")
        case "WebFetch":
            return read.line(moment, text("url").flatMap(site) ?? "a web page")
        case "WebSearch":
            return search.line(moment, text("query").map { "the web for \(quoted($0))" } ?? "the web")
        case "Task", "Agent":
            let head: String
            switch moment {
            case .asking: head = "Start a helper"
            case .running: head = "Starting a helper"
            case .finished: head = "Helper finished"
            case .refused: head = "starting a helper"
            }
            return text("description").map { "\(head): \($0)" } ?? head
        case "TodoWrite":
            return update.line(moment, "the to-do list")
        case "TodoRead":
            return check.line(moment, "the to-do list")
        case "Skill":
            // `plugin:skill` → `skill`: the plugin is where it came from, not
            // what it is called.
            let skill = text("skill").map { $0.split(separator: ":").last.map(String.init) ?? $0 }
            return use.line(moment, skill.map { "the \($0) skill" } ?? "a skill")
        case "SlashCommand":
            let command = text("command").flatMap { $0.split(separator: " ").first.map(String.init) }
            return run.line(moment, command ?? "a command")
        case "ToolSearch":
            return lookUp.line(moment, "tools")
        case "ExitPlanMode":
            switch moment {
            case .asking: return "Approve the plan"
            case .running: return "Sharing the plan"
            case .finished: return "Shared the plan"
            case .refused: return "the plan"
            }
        case "EnterPlanMode":
            return switchTo.line(moment, "to planning")
        case "BashOutput", "TaskOutput":
            return check.line(moment, "a background task")
        case "KillShell", "KillBash", "TaskStop":
            return stop.line(moment, "a background task")
        case "AskUserQuestion":
            switch moment {
            case .asking: return "Answer a question"
            case .running: return "Asking you a question"
            case .finished: return "Asked you a question"
            case .refused: return "a question"
            }
        default:
            return nil
        }
    }

    /// A search pattern worth quoting, or nil when it is a regular expression
    /// — `\bfoo\(` means nothing read aloud, and "Searching files" is true.
    private static func plainSearch(_ pattern: String) -> String? {
        let metacharacters = Set(#"\^$*+?()[]{}|"#)
        guard pattern.count <= 40, !pattern.contains(where: metacharacters.contains) else { return nil }
        return quoted(pattern)
    }

    /// The site, not the address: `https://www.apple.com/mac/` → `apple.com`.
    private static func site(_ url: String) -> String? {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func quoted(_ text: String) -> String {
        "“\(text.count > 40 ? String(text.prefix(40)) + "…" : text)”"
    }

    // MARK: - Every other tool

    /// An MCP tool, or a built-in this file has no wording for yet.
    private static func named(_ tool: String, _ moment: Moment) -> String {
        let mcp = MCPTool(tool)
        let service = mcp?.service
        // `ListMcpResourcesTool` → list, MCP, resources.
        let base = tool.hasSuffix("Tool") && tool.count > 4 ? String(tool.dropLast(4)) : tool
        let action = mcp?.action ?? words(of: base, splittingCase: true)

        // With nobody to name, a call that opens with a verb reads best as that
        // verb: "Created file", where "Used create file" reads like a machine.
        // Only with an object, though — a bare "Updated" says less than the
        // tool's own name does.
        if service == nil, action.count > 1, let verb = Verb.common[action[0]] {
            return verb.line(moment, action.dropFirst().joined(separator: " "))
        }

        // A built-in this file has no wording for keeps its capital — it is the
        // tool's name, "Monitor", not a word in a sentence.
        let label = mcp.map { MCPTool.label(service: $0.service, action: $0.action, fallback: tool) }
            ?? capitalizedFirst(action.joined(separator: " "))
        switch moment {
        case .asking: return "Allow \(label)?"
        case .running: return "Using \(label)"
        case .finished: return "Used \(label)"
        // The tool, named and nothing more: what a refusal was about.
        case .refused: return label
        }
    }

    // MARK: - Words

    /// An identifier as words: `trelloWriteCard` → write, card after trello;
    /// `preview_list` → preview, list; `getURLInfo` → get, URL, info.
    /// Lowercased except acronyms, which a person reads as letters.
    ///
    /// `splittingCase` is off for server names, which are written for people
    /// already — `Claude_Code_iOS_Simulator` — and would lose "iOS" to it.
    static func words(of identifier: String, splittingCase: Bool) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(identifier)
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == " " || character == "." {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if splittingCase, character.isUppercase, !current.isEmpty {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                // lower→Upper starts a word ("trello|Write"), and so does the
                // last capital of a run that a lowercase letter follows
                // ("URL|Info").
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { splittingCase ? normalized($0) : acronym($0) ?? $0 }
    }

    private static func normalized(_ word: String) -> String {
        if let known = acronym(word) { return known }
        // All capitals and more than one letter: an acronym this list lacks.
        if word.count > 1, word == word.uppercased(), word.contains(where: \.isLetter) { return word }
        return word.lowercased()
    }

    private static func acronym(_ word: String) -> String? {
        acronyms[word.lowercased()]
    }

    private static let acronyms: [String: String] = [
        "ai": "AI", "api": "API", "csv": "CSV", "db": "DB", "html": "HTML", "id": "ID",
        "ids": "IDs", "ios": "iOS", "json": "JSON", "mcp": "MCP", "pdf": "PDF", "pr": "PR",
        "prs": "PRs", "sql": "SQL", "ui": "UI", "url": "URL", "urls": "URLs",
    ]

    static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || character == "-" || (character.isASCII && (character.isLetter || character.isNumber))
    }
}

// MARK: - MCP names

/// `mcp__<server>__<tool>`, taken apart.
private struct MCPTool {
    static let prefix = "mcp__"

    /// Whose tool it is, when that can be told: "Trello", "Claude Browser".
    let service: String?
    /// What it does, as words: write, card.
    let action: [String]

    var label: String { Self.label(service: service, action: action, fallback: "") }

    static func label(service: String?, action: [String], fallback: String) -> String {
        let doing = action.joined(separator: " ")
        guard let service else { return doing.isEmpty ? fallback : doing }
        return doing.isEmpty ? service : "\(service): \(doing)"
    }

    init?(_ tool: String) {
        guard tool.hasPrefix(Self.prefix) else { return nil }
        let rest = tool.dropFirst(Self.prefix.count)
        // The tool's own name may contain a double underscore; the server's is
        // taken to end at the first one.
        let server: Substring
        let name: Substring
        if let split = rest.range(of: "__") {
            (server, name) = (rest[..<split.lowerBound], rest[split.upperBound...])
        } else {
            (server, name) = ("", rest)
        }

        var action = ToolPhrase.words(of: String(name), splittingCase: true)
        var service = Self.service(from: String(server))

        if let service {
            // `mcp__trello__trelloWriteCard` would otherwise read "Trello:
            // trello write card".
            let serverWords = Set(ToolPhrase.words(of: service, splittingCase: false).map { $0.lowercased() })
            while action.count > 1, let first = action.first, serverWords.contains(first.lowercased()) {
                action.removeFirst()
            }
        } else if action.count > 1, Verb.common[action[0]] == nil, Verb.common[action[1]] != nil {
            // A claude.ai connector's server is a UUID, but its tools are often
            // named for the service: `trelloWriteCard` is Trello's "write card".
            // A word ahead of the verb is taken as that name — which is why a
            // tool that opens with a verb, `create_file`, is left alone.
            service = ToolPhrase.capitalizedFirst(action.removeFirst())
        }

        guard service != nil || !action.isEmpty else { return nil }
        self.service = service
        self.action = action
    }

    /// The server as a name, or nil when it is an id rather than one.
    private static func service(from server: String) -> String? {
        guard !server.isEmpty, UUID(uuidString: server) == nil else { return nil }
        var name = Substring(server)
        // `plugin_<plugin>_<server>`: the server half is what it is called.
        // Plugin names are kebab-case, so the first underscore ends one.
        if name.hasPrefix("plugin_") {
            name = name.dropFirst("plugin_".count)
            if let underscore = name.firstIndex(of: "_"), name.index(after: underscore) < name.endIndex {
                name = name[name.index(after: underscore)...]
            }
        }
        // A claude.ai connector, the way the CLI names one.
        if name.hasPrefix("claude_ai_") { name = name.dropFirst("claude_ai_".count) }

        let words = ToolPhrase.words(of: String(name), splittingCase: false)
        guard !words.isEmpty else { return nil }
        return ToolPhrase.capitalizedFirst(words.joined(separator: " "))
    }
}

// MARK: - Verbs

/// One verb in the three forms a line needs.
private struct Verb {
    let base: String
    let ongoing: String
    let past: String

    init(_ base: String, _ ongoing: String, _ past: String) {
        (self.base, self.ongoing, self.past) = (base, ongoing, past)
    }

    func line(_ moment: ToolPhrase.Moment, _ object: String) -> String {
        let head: String
        switch moment {
        // A refusal reads as the instruction that was refused — "Edit
        // main.swift" — which is the asking form without its question.
        case .asking, .refused: head = base
        case .running: head = ongoing
        case .finished: head = past
        }
        return ToolPhrase.capitalizedFirst(object.isEmpty ? head : "\(head) \(object)")
    }

    /// The verbs tool names open with. Also how a connector's tool gives away
    /// whose it is: a word ahead of one of these is the service's name.
    static let common: [String: Verb] = Dictionary(uniqueKeysWithValues: [
        Verb("add", "adding", "added"), Verb("analyze", "analyzing", "analyzed"),
        Verb("apply", "applying", "applied"), Verb("archive", "archiving", "archived"),
        Verb("build", "building", "built"), Verb("cancel", "cancelling", "cancelled"),
        Verb("check", "checking", "checked"), Verb("clear", "clearing", "cleared"),
        Verb("click", "clicking", "clicked"), Verb("close", "closing", "closed"),
        Verb("copy", "copying", "copied"), Verb("create", "creating", "created"),
        Verb("delete", "deleting", "deleted"), Verb("deploy", "deploying", "deployed"),
        Verb("download", "downloading", "downloaded"), Verb("edit", "editing", "edited"),
        Verb("enter", "entering", "entered"), Verb("execute", "executing", "executed"),
        Verb("exit", "exiting", "exited"), Verb("export", "exporting", "exported"),
        Verb("fetch", "fetching", "fetched"), Verb("find", "finding", "found"),
        Verb("generate", "generating", "generated"), Verb("get", "getting", "got"),
        Verb("import", "importing", "imported"), Verb("install", "installing", "installed"),
        Verb("list", "listing", "listed"), Verb("load", "loading", "loaded"),
        Verb("merge", "merging", "merged"), Verb("move", "moving", "moved"),
        Verb("navigate", "navigating", "navigated"), Verb("open", "opening", "opened"),
        Verb("post", "posting", "posted"), Verb("preview", "previewing", "previewed"),
        Verb("publish", "publishing", "published"), Verb("query", "querying", "queried"),
        Verb("read", "reading", "read"), Verb("remove", "removing", "removed"),
        Verb("rename", "renaming", "renamed"), Verb("reply", "replying", "replied"),
        Verb("resize", "resizing", "resized"), Verb("restore", "restoring", "restored"),
        Verb("run", "running", "ran"), Verb("save", "saving", "saved"),
        Verb("schedule", "scheduling", "scheduled"), Verb("search", "searching", "searched"),
        Verb("select", "selecting", "selected"), Verb("send", "sending", "sent"),
        Verb("set", "setting", "set"), Verb("share", "sharing", "shared"),
        Verb("show", "showing", "showed"), Verb("start", "starting", "started"),
        Verb("stop", "stopping", "stopped"), Verb("submit", "submitting", "submitted"),
        Verb("switch", "switching", "switched"), Verb("sync", "syncing", "synced"),
        Verb("take", "taking", "took"), Verb("type", "typing", "typed"),
        Verb("update", "updating", "updated"), Verb("upload", "uploading", "uploaded"),
        Verb("view", "viewing", "viewed"), Verb("write", "writing", "wrote"),
    ].map { ($0.base, $0) })
}
