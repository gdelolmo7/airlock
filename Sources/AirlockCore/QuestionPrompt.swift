import Foundation

/// A choice an agent offers when it asks the user something (Claude's
/// `AskUserQuestion` tool). Rendered as a numbered, one-click option.
public struct QuestionOption: Codable, Sendable, Hashable, Identifiable {
    public var label: String
    public var detail: String?
    public var id: String { label }

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }
}

/// A structured question with pickable answers — the difference between
/// "Claude is waiting for input" and actually answering from the notch.
public struct QuestionPrompt: Codable, Sendable, Hashable {
    public var question: String
    /// Short label the agent supplies ("Deploy target"), used as the eyebrow.
    public var header: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [QuestionOption], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// Parse Claude's `AskUserQuestion` tool input: every question, in the
    /// order the agent wrote them. One call carries one to four.
    ///
    /// **A question with no options is kept, as one answered in words.** It
    /// used to be dropped, and with nothing parsed the card fell back to a
    /// command's Approve / Deny / Always under "Claude has a question" — three
    /// buttons that answer nothing, and an Always that would have saved a rule
    /// named after the tool. The card draws it as the question and a field.
    ///
    /// This used to stop at the first, on the theory that a multi-question ask
    /// belonged in the terminal. It did not stay there: the card answered
    /// question one, the tool was answered once for all of them, and the agent
    /// heard nothing about the rest. `QuestionWalk` is what answers them now.
    public static func parseAll(toolInput: [String: Any]) -> [QuestionPrompt] {
        guard let questions = toolInput["questions"] as? [[String: Any]] else { return [] }
        return questions.compactMap { raw in
            guard let text = raw["question"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rawOptions = raw["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { option -> QuestionOption? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                let detail = (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return QuestionOption(label: label, detail: detail)
            }
            return QuestionPrompt(
                question: text,
                header: raw["header"] as? String,
                options: options,
                // Nothing to tick is not "pick any".
                multiSelect: !options.isEmpty && (raw["multiSelect"] as? Bool ?? false)
            )
        }
    }

    /// The first of `parseAll` — nil unless at least one question is present.
    public static func parse(toolInput: [String: Any]) -> QuestionPrompt? {
        parseAll(toolInput: toolInput).first
    }
}

/// One ask's questions, answered in order, and the single reply they add up to.
///
/// `AskUserQuestion` is answered once for every question it carries, so the
/// card steps through them and sends only when the last is answered. Going back
/// keeps what was already picked — fixing question one must not cost the
/// answer to question two.
///
/// Pure and in Core because the part that can be wrong is the bookkeeping, and
/// the view is the one place nobody can run a test against.
public struct QuestionWalk: Equatable, Sendable {
    public let questions: [QuestionPrompt]
    /// Which question is on screen.
    public private(set) var step = 0
    /// Answers so far, by position. Kept when stepping back.
    public private(set) var answers: [String?]

    public init(_ questions: [QuestionPrompt]) {
        self.questions = questions
        answers = Array(repeating: nil, count: questions.count)
    }

    public enum Outcome: Equatable, Sendable {
        /// On to the next question.
        case next
        /// That was the last. Send this, once, for the whole ask.
        case finished(reply: String)
    }

    public var current: QuestionPrompt? {
        questions.indices.contains(step) ? questions[step] : nil
    }

    /// What the question on screen was answered with, when it was answered
    /// before somebody stepped back to it.
    public var currentAnswer: String? {
        answers.indices.contains(step) ? answers[step] : nil
    }

    public var isLast: Bool { step >= questions.count - 1 }
    public var canGoBack: Bool { step > 0 }

    /// "2 of 3" — nil for one question, which has nothing to count.
    public var position: String? {
        questions.count > 1 ? "\(step + 1) of \(questions.count)" : nil
    }

    /// What the questions before this one were answered with, as one line —
    /// "Tap home: Open the panel first" — so that moving on visibly kept the
    /// answer. Nil on the first question. Labelled the way the reply labels
    /// them, so the line and what the agent reads cannot disagree.
    public var earlierAnswers: String? {
        let given = answers.prefix(step).enumerated().compactMap { index, answer -> String? in
            guard let answer else { return nil }
            let flat = answer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "\(Self.label(for: questions[index], among: questions)): \(flat)"
        }
        return given.isEmpty ? nil : given.joined(separator: " · ")
    }

    public mutating func answer(_ text: String) -> Outcome {
        guard questions.indices.contains(step) else { return .finished(reply: text) }
        answers[step] = text
        guard isLast else {
            step += 1
            return .next
        }
        return .finished(reply: Self.reply(to: questions, answers: answers.map { $0 ?? "" }))
    }

    public mutating func back() {
        if step > 0 { step -= 1 }
    }

    /// ONE answer for the whole ask, for the deny-with-reason path every answer
    /// has always taken — the agent reads it after "The user answered from
    /// Airlock: ".
    ///
    /// A single question is sent exactly as it always was: the bare answer.
    /// Every ask before this one got that shape, and one answer has nothing to
    /// be confused with.
    ///
    /// Several are sent as `"label"="answer"` pairs in the agent's own order,
    /// labelled by the question's header, which the agent wrote as the handle
    /// for it. Quoted, because an answer can hold anything — a multi-select is
    /// joined with commas, and the field takes whatever is typed into it — and
    /// an answer that ran into the next label would be read as part of it.
    public static func reply(to questions: [QuestionPrompt], answers: [String]) -> String {
        guard questions.count > 1 else { return answers.first ?? "" }
        return zip(questions, answers).map { question, answer in
            "\(quoted(label(for: question, among: questions)))=\(quoted(answer))"
        }.joined(separator: ", ")
    }

    /// The header, unless it is missing or another question in the same ask
    /// shares it — then the question itself, the only thing telling them apart.
    private static func label(for question: QuestionPrompt, among questions: [QuestionPrompt]) -> String {
        func trimmed(_ header: String?) -> String? {
            let text = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        guard let header = trimmed(question.header),
              questions.filter({ trimmed($0.header) == header }).count == 1 else {
            return question.question
        }
        return header
    }

    /// One line, with the two characters that would end the quote early
    /// escaped the way the agent reads them everywhere else.
    private static func quoted(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let escaped = flat
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
