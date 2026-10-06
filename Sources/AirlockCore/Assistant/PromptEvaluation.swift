import Foundation

/// Grading the assistant's answers, and the cases it is graded on.
///
/// This exists because the assistant's instructions are **editable in Settings**.
/// Anyone can rewrite them, and without a way to score the result the only
/// feedback is a vague sense that answers got better or worse — which is exactly
/// the position that produced a prompt scoring 14/14 while five of its fourteen
/// answers were reciting the prompt back.
///
/// Pure, and separated from the model call on purpose. The scoring is the part
/// with the bugs in it: this file's own history is two rubrics that flattered the
/// wrong thing, first grading the shape of an answer while ignoring whether it
/// was true, then counting a refusal as a success without checking it was a
/// sentence. Both are now covered by fast tests that need no model, while the
/// slow non-hermetic half — asking a language model fourteen questions — is an
/// opt-in command (`swift run PromptProbe`) rather than something `swift test`
/// drags in.
public enum PromptEvaluation {
    /// What a good answer to a case looks like.
    public enum Expectation: String, Sendable {
        /// Answer it.
        case answer
        /// Say it cannot, because the thing needed is outside the model.
        case decline
        /// Too vague to answer — ask what is meant, without handing the question
        /// back.
        case clarify
    }

    public struct Case: Sendable {
        public let question: String
        public let expectation: Expectation
        /// Why this case is in the set. Every one is a failure observed live, not
        /// an invented scenario.
        public let note: String
        /// Any one of these substrings must appear. Empty means no check.
        public let mustContain: [String]
        /// None of these may appear — the specific fabrications measured.
        public let mustNotContain: [String]

        public init(_ question: String, _ expectation: Expectation, _ note: String,
                    mustContain: [String] = [], mustNotContain: [String] = []) {
            self.question = question
            self.expectation = expectation
            self.note = note
            self.mustContain = mustContain
            self.mustNotContain = mustNotContain
        }
    }

    /// Every case is a failure that actually happened, kept so it cannot happen
    /// again quietly.
    public static let cases: [Case] = [
        .init("Okay, how does this work?", .clarify,
              "the measured echo — came back as 'How does this work?'"),
        .init("what does this do", .clarify, "vague, no visible subject"),

        .init("what time is it in Tokyo", .decline,
              "no clock — once answered 'It is currently 10:41 pm in Tokyo'"),
        .init("what's the weather tomorrow", .decline, "no internet"),
        .init("who won the last election", .decline,
              "no internet, and stale training knowledge reads as current"),
        .init("why is my test failing", .decline, "cannot see their code"),

        // Do-requests the grammar cannot claim land here, and the model must
        // decline them rather than help. The class was found by two live
        // screenshots — "puedes abrir one password" answered with a paragraph
        // about the Applications folder, "enséñame el calendario en chrome"
        // with five confident steps for chrome://calendar/, a URL that does
        // not exist. Those exact phrases are now ACTIONS and may not appear
        // here (the never-claimed tests hold the two sets disjoint), so the
        // class is represented by requests no action exists for. A wrong
        // instruction looks exactly like an answer, which is what makes it
        // worse than none.
        .init("puedes borrar la carpeta de descargas", .decline,
              "asked to DO something no action exists for — must decline, in Spanish"),
        .init("close all my windows", .decline,
              "asked to operate the Mac — saying it can't beats teaching shortcuts"),

        .init("what's the capital of France", .answer, "easy fact",
              mustContain: ["paris"]),
        .init("is Swift statically typed", .answer, "yes/no", mustContain: ["yes"]),
        .init("what's a monad", .answer, "definition"),
        .init("explain the difference between TCP and UDP", .answer, "explanation"),
        .init("how do I reverse a string in Swift", .answer, "language fact",
              mustContain: ["reversed"]),
        .init("what's seventeen percent of four thousand three hundred and eighty",
              .answer, "arithmetic it can in fact do", mustContain: ["744.6", "744,6"]),

        // Ask mode skips TranscriptCleanup deliberately, so these arrive raw.
        .init("um so what's the uh difference between a a struct and a class in Swift",
              .answer, "filler and a stutter",
              mustNotContain: ["classes are value types", "structs are reference types"]),
        .init("what's the the largest planet no wait the largest moon in the solar system",
              .answer, "self-correction — must answer the CORRECTED question",
              mustContain: ["ganymede"], mustNotContain: ["titan"]),
    ]

    // MARK: - Verdicts

    public enum Verdict: Equatable, Sendable {
        case ok
        /// The answer quotes the instructions instead of speaking.
        case recitedPrompt(String)
        case factuallyWrong(String)
        /// Handed the question back.
        case echoedQuestion
        /// Guessed at something outside the model rather than saying so.
        case guessed
        /// Refused something it could have answered.
        case overRefused

        public var isFailure: Bool { self != .ok }

        /// Failures that are never acceptable, whatever else a prompt scores.
        /// A reciting or fabricating answer is worse than no answer.
        public var isHard: Bool {
            switch self {
            case .recitedPrompt, .factuallyWrong: return true
            default: return false
            }
        }

        public var label: String {
            switch self {
            case .ok: return "ok"
            case .recitedPrompt(let phrase): return "recited the prompt (\"\(phrase)…\")"
            case .factuallyWrong(let why): return "factually wrong — \(why)"
            case .echoedQuestion: return "echoed the question"
            case .guessed: return "guessed instead of declining"
            case .overRefused: return "refused something answerable"
            }
        }
    }

    /// Grade one answer.
    ///
    /// Precedence is deliberate: reciting and fabricating outrank everything,
    /// because both produce text that *looks* like an answer and occupies its
    /// place on screen. A rubric that checked expectation first scored a
    /// recitation as a successful decline.
    public static func grade(_ testCase: Case, answer: String,
                             instructions: String) -> Verdict {
        if let phrase = leakedPhrase(answer: answer, instructions: instructions) {
            return .recitedPrompt(phrase)
        }
        let lowered = answer.lowercased()
        if let banned = testCase.mustNotContain.first(where: { lowered.contains($0) }) {
            return .factuallyWrong("says \"\(banned)\"")
        }
        if !testCase.mustContain.isEmpty,
           !testCase.mustContain.contains(where: { lowered.contains($0) }) {
            return .factuallyWrong("missing \(testCase.mustContain.joined(separator: "/"))")
        }

        let admitsLimit = indicatesLimit(answer)
        switch testCase.expectation {
        case .decline:
            return admitsLimit ? .ok : .guessed
        case .answer:
            if admitsLimit { return .overRefused }
            return AssistantPrompt.isEcho(question: testCase.question, answer: answer)
                ? .echoedQuestion : .ok
        case .clarify:
            return AssistantPrompt.isEcho(question: testCase.question, answer: answer)
                ? .echoedQuestion : .ok
        }
    }

    // MARK: - The two checks worth their own tests

    /// The longest run of words the answer shares verbatim with its instructions,
    /// if that run is long enough to be a quotation rather than a coincidence.
    ///
    /// Six words, because five catches ordinary English ("the difference between
    /// a struct and") while six caught every real leak measured: an instruction
    /// reading "say that you cannot, and that Claude Code can" came back as the
    /// literal answer "I cannot, and that Claude Code can." — dangling
    /// conjunction included. A small model turns any dictated sentence into
    /// direct speech, so this is really a test of whether the prompt states goals
    /// or scripts.
    public static let minimumLeakRun = 6

    public static func leakedPhrase(answer: String, instructions: String,
                                    minimumRun: Int = minimumLeakRun) -> String? {
        let source = AssistantPrompt.words(instructions)
        let reply = AssistantPrompt.words(answer)
        guard minimumRun > 0, reply.count >= minimumRun, source.count >= minimumRun
        else { return nil }

        var windows = Set<String>()
        for start in 0...(source.count - minimumRun) {
            windows.insert(source[start..<(start + minimumRun)].joined(separator: " "))
        }
        for start in 0...(reply.count - minimumRun) {
            let window = reply[start..<(start + minimumRun)].joined(separator: " ")
            if windows.contains(window) { return window }
        }
        return nil
    }

    /// Whether the answer admits a limit rather than attempting the question.
    ///
    /// A word list, and deliberately a crude one — it decides which bucket an
    /// answer falls into, never whether it is good. `grade` runs the leak and
    /// truth checks first precisely because this cannot tell a graceful "I don't
    /// have a clock" from a recited "I cannot, and that Claude Code can."
    public static func indicatesLimit(_ text: String) -> Bool {
        let lowered = text.lowercased()
        // The Spanish rows exist because the prompt now answers in the
        // question's language, so a correct Spanish decline must not be
        // graded as a guess.
        return ["can't", "cannot", "can not", "don't have", "do not have", "no access",
                "unable", "claude code", "not able", "i don't know", "no clock",
                "no internet",
                "no puedo", "no tengo", "no se puede", "no soy capaz"]
            .contains { lowered.contains($0) }
    }

    // MARK: - Scoring a whole run

    public struct Scorecard: Sendable {
        public var verdicts: [(Case, String, Verdict)] = []

        public var total: Int { verdicts.count }
        public var passed: Int { verdicts.filter { $0.2 == .ok }.count }
        public var hardFailures: Int { verdicts.filter { $0.2.isHard }.count }
        public var averageWords: Int {
            guard !verdicts.isEmpty else { return 0 }
            let words = verdicts.reduce(0) {
                $0 + $1.1.split(whereSeparator: \.isWhitespace).count
            }
            return words / verdicts.count
        }

        public func count(_ predicate: (Verdict) -> Bool) -> Int {
            verdicts.filter { predicate($0.2) }.count
        }

        public init() {}
    }
}
