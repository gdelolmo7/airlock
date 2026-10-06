import Foundation

/// A resolution for a pending permission gate. The first three are user
/// decisions; `deferred` is the timeout outcome — the notch stops holding the
/// gate and the agent's own prompt takes over.
public enum PermissionDecision: String, Codable, Sendable, Hashable {
    case allowOnce
    case deny
    case alwaysAllow
    case deferred
}

/// A pending permission gate raised by an agent (e.g. Claude Code `PreToolUse`).
///
/// The card shows the *actual* command or diff — approving with real context is
/// a core differentiator over tool-name-only prompts.
public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Exactly as the agent sent it. Policy rules match on this, so it is never
    /// reworded — see `ToolPhrase` for what a person is shown instead.
    public var toolName: String
    /// One-line human summary, e.g. "Run shell command" / "Edit src/app.ts".
    public var summary: String
    /// The same call as a line nobody has to answer — "Reading notes.md",
    /// "Using Trello: write card" — for when a policy rule settles the gate and
    /// the card's own "Allow …?" would be asking a question already decided.
    /// Nil on a request built without one; `summary` stands in.
    public var activity: String?
    /// The same call as the subject of a line about something that did NOT
    /// happen — "rm -rf ./dist", "Edit main.swift", "Trello: write card" — for
    /// a gate a rule denied. Nil on a request built without one; `command` and
    /// then `summary` stand in.
    ///
    /// Separate from `activity` because that one is a tense: "Auto-denied ·
    /// Running: rm -rf ./dist" told the user a blocked command was under way.
    public var refusal: String?
    /// The shell command, when the tool is a command runner.
    public var command: String?
    /// A unified diff, when the tool edits a file.
    public var diff: String?
    /// The policy-matchable subject: the command for Bash, the full file path
    /// for file tools. Policy matching falls back to `command` when absent.
    public var target: String?
    /// Set when the agent is ASKING rather than requesting permission
    /// (Claude's AskUserQuestion) — the card renders pickable options. When
    /// one ask carries several questions this is the first; `questions` has
    /// them all.
    public var question: QuestionPrompt?
    /// The questions after `question`.
    ///
    /// Apart from it rather than one list, so that everything asking "is this a
    /// question, and what does it say" goes on reading `question` unchanged —
    /// and so a request cached before multi-question asks existed still
    /// decodes.
    private var laterQuestions: [QuestionPrompt]?
    public var createdAt: Date

    /// Every question in the ask, in the order the agent wrote them.
    /// `AskUserQuestion` carries one to four, and is answered once for all.
    public var questions: [QuestionPrompt] {
        get { (question.map { [$0] } ?? []) + (laterQuestions ?? []) }
        set {
            question = newValue.first
            laterQuestions = newValue.count > 1 ? Array(newValue.dropFirst()) : nil
        }
    }

    /// The question the card was showing, by step — the one a receipt should
    /// name.
    ///
    /// **An ask can hold four questions and the card walks them one at a
    /// time.** A receipt built from `question` named the first of them however
    /// far in the user was, so dismissing on question three left an account of
    /// question one, which reads as an answer given to the wrong thing. Out of
    /// range, or no step at all, falls back to the first: it is the one the
    /// card opened on.
    public func question(at step: Int?) -> QuestionPrompt? {
        guard let step, step >= 0, step < questions.count else { return question }
        return questions[step]
    }

    /// The session row's line while this question's card is on screen under
    /// it. Nil for a permission, whose summary already reads as a line.
    ///
    /// Not the question. The card directly below says it in full, so the row
    /// could only say it again cut short — which read as "the question is cut
    /// off" — and, once the card had stepped on, as question one sitting over
    /// question two.
    public var waitingLine: String? {
        guard question != nil else { return nil }
        let count = questions.count
        return count > 1 ? "Waiting for your answer · \(count) questions" : "Waiting for your answer"
    }

    /// Whether "Always" belongs on this card.
    ///
    /// Not for a question: an answer is not a permission, and the rule it
    /// would save is named after the tool that asks. Not for a request the
    /// risk floor caught: `PolicyEngine` asks about those before it reads a
    /// single allow rule, so the rule would be written and never honoured — a
    /// button that looks like it worked and changes nothing.
    public var offersAlways: Bool {
        question == nil && RiskAssessor.assess(self) == nil
    }

    public init(
        id: String,
        toolName: String,
        summary: String,
        activity: String? = nil,
        refusal: String? = nil,
        command: String? = nil,
        diff: String? = nil,
        target: String? = nil,
        question: QuestionPrompt? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.activity = activity
        self.refusal = refusal
        self.command = command
        self.diff = diff
        self.target = target
        self.question = question
        self.createdAt = createdAt
    }
}
