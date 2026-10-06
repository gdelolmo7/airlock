import SwiftUI
import AirlockCore

/// The assistant's rows (V) of the inventory: an answer, the route ladder,
/// the failures, the typed bar and the cards a sentence turns into.
///
/// Every answer row is a real `AssistantModel` put into one state by
/// `presentPreview` — no stream, no model, no Escape monitor — and drawn by
/// `AssistantView`, the view that ships. The cards are `PanelSnapshot`'s, so
/// the gallery and the snapshot cannot show two different versions of one card.
///
/// The two failure sentences are the model's own statics, so a wording change
/// reaches V5/V5a without copying.
@MainActor
enum GalleryAssistant {
    static let area = "Assistant"

    static var states: [GalleryState] {
        [
            GalleryState("V1", area, "Thinking (answer not started)") {
                answer(question: "how do I undo my last git commit", isStreaming: true)
            },
            GalleryState("V2", area, "Answer") {
                answer(question: "what's the difference between merge and rebase",
                       answer: rebaseAnswer)
            },
            GalleryState("V3", area, "Route ladder (terminal or answer)") {
                answer(question: workPhrase, routes: PromptRouting.candidates(for: workPhrase))
            },
            GalleryState("V4", area, "No model: Apple Intelligence off") {
                answer(question: "what time is it in Tokyo",
                       failure: ModelAvailability.needsAppleIntelligence.message(feature: "answering"),
                       availability: .needsAppleIntelligence)
            },
            GalleryState("V5", area, "Model failed mid-answer") {
                answer(question: "summarise this week's commits",
                       failure: AssistantModel.couldNotAnswer)
            },
            GalleryState("V5a", area, "Model only repeated the question") {
                answer(question: "what's a good name for a cat",
                       failure: AssistantModel.hadNoAnswer)
            },
            GalleryState("V6", area, "Typed bar, empty") {
                typedBar(text: "", guideKeys: false)
            },
            GalleryState("V6a", area, "Typed bar, text in, guide on (two keys)") {
                typedBar(text: "open the calendar settings", guideKeys: true)
            },
            GalleryState("V7", area, "Typed bar locked under a card") {
                VStack(spacing: 8) {
                    GalleryIsland.topBar(usage: nil, arrange: false) {
                        AirlockMark()
                        GalleryIsland.glyph("chevron.up")
                    }
                    card("ordinary — a rule can be written")
                    CommandField(text: .constant(""), isBlocked: true, guideKeys: false, onSubmit: {})
                }
            },
            GalleryState("V8", area, "Action refused by a deny rule") {
                card("refused by a deny rule")
            },
            GalleryState("V8a", area, "Action refused: trial finished") {
                card("trial finished")
            },
            GalleryState("V9", area, "Action card (Do it / No / Always)") {
                card("ordinary — a rule can be written")
            },
        ]
    }

    // MARK: - Answers

    /// A phrase that reads as work, so the ladder puts the terminal on top.
    private static let workPhrase = "fix the flaky snapshot tests"

    private static let rebaseAnswer = """
        Merge keeps both histories and adds a commit joining them, so nothing is \
        rewritten. Rebase replays your commits on top of the other branch, which \
        gives a straight line but rewrites them — fine on your own branch, risky \
        on one somebody else has pulled.
        """

    /// `AssistantView` over a model holding exactly one state. Its dictation
    /// environment is read only by "Turn asking off"'s action, which a picture
    /// never takes, so it is left out rather than built — `DictationModel`
    /// owns a microphone.
    private static func answer(question: String, answer: String = "", isStreaming: Bool = false,
                               failure: String? = nil, routes: [PromptRouting.Route] = [],
                               availability: ModelAvailability = .ready) -> some View {
        let model = AssistantModel()
        model.presentPreview(question: question, answer: answer, isStreaming: isStreaming,
                             failure: failure, routes: routes, availability: availability)
        return AssistantView()
            .environment(model)
            .environment(NotchUIState())
    }

    // MARK: - Typed bar

    /// The band with the typing badge over the field, as the panel stacks them.
    /// The field is the AppKit-backed one: a hosting view draws it, where
    /// `ImageRenderer` could not.
    private static func typedBar(text: String, guideKeys: Bool) -> some View {
        VStack(spacing: 8) {
            GalleryIsland.topBar(usage: nil, arrange: false) {
                AirlockMark()
                GalleryIsland.glyph("chevron.up")
            }
            CommandField(text: .constant(text), isBlocked: false, guideKeys: guideKeys, onSubmit: {})
        }
    }

    // MARK: - Cards

    /// One of `PanelSnapshot`'s cards, by title, drawn as the snapshot draws it.
    @ViewBuilder
    private static func card(_ title: String) -> some View {
        if let state = PanelSnapshot.states.first(where: { $0.title == title }) {
            ActionCardView(pending: state.pending)
                .environment(state.model)
                .environment(NotchUIState())
        } else {
            Text("No PanelSnapshot state named “\(title)”")
                .foregroundStyle(.red)
        }
    }
}
