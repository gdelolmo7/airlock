import SwiftUI
import AirlockCore

/// Questions about past calls, answered in the notch (K23 on): the answer
/// card with the moments it came from under it.
///
/// Each row is the shipping `AssistantView` over a model put into one state
/// by `presentPreview`, so no search runs, no model is asked and no call is
/// read. The calls named are made up.
///
/// Days are made inside each row's draw, so "Yesterday" reads as yesterday
/// whenever the gallery is drawn.
@MainActor
enum GalleryCallAnswers {
    static let area = GalleryCallNotesPanel.area

    static var states: [GalleryState] {
        [
            GalleryState("K23", area, "Ask: an answer from your calls, three sources") {
                answer(question: "What did Marta say about the budget?",
                       answer: """
                           Marta said the launch budget is forty thousand, and about half of it \
                           goes on design. She asked you to keep the old pictures until after \
                           launch so it stays under that.
                           """,
                       sources: [
                           source("Weekly product sync", daysAgo: 1, at: 12, 0, said: 240),
                           source("Budget review", daysAgo: 2, at: 16, 30, said: 95),
                           source("Launch check-in with Ana", daysAgo: 6, at: 9, 30, said: 1_210),
                       ])
            },
            GalleryState("K24", area, "Ask: looking through your calls") {
                answer(question: "¿Qué quedamos ayer en la llamada con Pablo?", isStreaming: true)
            },
            GalleryState("K25", area, "Ask: the answer still coming in") {
                answer(question: "When is the launch, from Tuesday's meeting?",
                       answer: "The launch stays on the twentieth, as long as the pricing page",
                       isStreaming: true)
            },
            GalleryState("K26", area, "Ask: nothing about it in your calls") {
                answer(question: "What did we decide about the hiring plan on the call?",
                       answer: CallAnswer.miss(.nothingFound, language: "English"))
            },
            GalleryState("K27", area, "Ask: a long answer, a long call name") {
                answer(question: "Recap what we agreed with the agency last week",
                       answer: """
                           You agreed the agency delivers the new pictures by the fifteenth, with \
                           one round of changes included and a second one billed by the day. \
                           Lucía owns the brief and sends it on Monday; Marc checks the invoices \
                           before anything is paid. The launch date itself was not moved, and the \
                           support inbox still has no owner, which you said you would raise at the \
                           next weekly sync.
                           """,
                       sources: [
                           source("Agency kickoff with the studio: the pictures, the copy, the pricing page and the whole launch timeline",
                                  daysAgo: 8, at: 15, 0, said: 1_830),
                           source("Weekly product sync", daysAgo: 7, at: 12, 0, said: 2_410),
                       ])
            },
        ]
    }

    // MARK: - Drawing

    private static func answer(question: String, answer: String = "", isStreaming: Bool = false,
                               sources: [CallSource] = []) -> some View {
        let model = AssistantModel()
        model.presentPreview(question: question, answer: answer, isStreaming: isStreaming,
                             fromCalls: true, sources: sources)
        return AssistantView()
            .environment(model)
            .environment(NotchUIState())
    }

    /// A call that started `daysAgo` at `hour`:`minute`, cited `said`
    /// seconds in.
    private static func source(_ title: String, daysAgo: Int, at hour: Int, _ minute: Int,
                               said: TimeInterval) -> CallSource {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) ?? Date()
        let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        return CallSource(folder: title, title: title, startedAt: start, time: said)
    }
}
