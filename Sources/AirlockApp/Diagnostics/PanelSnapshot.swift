import AppKit
import SwiftUI
import AirlockCore

/// Renders the panel's cards to a PNG, so they can be looked at.
///
///     open output/package/Airlock.app --args --snapshot ~/Desktop/cards.png
///
/// **This exists because the alternative was describing pixels from a log.**
/// Airlock is `LSUIElement`, a background app with no Dock presence, so it does
/// not appear in the application list that screen-capture tooling resolves
/// names against — a filtered screenshot of it cannot be taken at all, and a
/// plain one needs a Screen Recording grant the caller may not have. The card
/// was written, shipped and reviewed without anyone seeing it. That is a bad way
/// to build a surface whose entire job is being read in four seconds.
///
/// **What it is not.** `ImageRenderer` draws the VIEW, not the composited
/// panel: no Liquid Glass behind it, no notch above it, no clipping from the
/// height budget. So it answers "is the wording right, is the hierarchy right,
/// does anything wrap badly" and it does not answer "does this fit". For the
/// second question there is no substitute for looking at the screen.
///
/// Argument-gated and inert otherwise, exactly like `--say` and
/// `--demo-answer`. The env-var form is deliberately absent: `open` goes through
/// LaunchServices, which passes arguments and drops the environment.
@MainActor
enum PanelSnapshot {
    /// True when the app should render and quit rather than run.
    static func requested(in arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard let flag = arguments.firstIndex(of: "--snapshot"),
              case let next = arguments.index(after: flag), next < arguments.endIndex
        else { return nil }
        return URL(fileURLWithPath: (arguments[next] as NSString).expandingTildeInPath)
    }

    /// Every state the card can be in, in one image.
    ///
    /// A contact sheet rather than a file each, because the states are only
    /// interesting NEXT to one another — whether the floored card reads as more
    /// serious than the ordinary one is the question, and it cannot be answered
    /// one file at a time.
    static func write(to url: URL, width: CGFloat) -> Bool {
        // DARK, explicitly, and this line has a story.
        //
        // Without it `textPrimary` comes out rgb(0.09, 0.10, 0.12) on a near-black
        // ground and the card's most important line is invisible. That is an
        // artefact of THIS renderer and not a picture of the app: `ImageRenderer`
        // resolves light whatever the system is set to, and — measured —
        // whatever `performAsCurrentDrawingAppearance` is wrapped around it, which
        // is why no such wrapper is here. The panel does not inherit that,
        // because it sets `\.colorScheme` from the chosen surface
        // (`NotchRootView`), and the environment beats the window.
        //
        // The sheet was still worth the alarm it caused: chasing it found a real
        // fault one layer down, where the glass ground took its light-or-dark
        // from System Settings while the palette took it from the surface
        // setting. See `NotchController.pinPanelAppearance`.
        let renderer = ImageRenderer(content: sheet(width: width)
            .environment(\.colorScheme, .dark))
        // Retina, because the thing under review is 10pt type and a hairline
        // border. At 1× the review would be of the downsampling.
        renderer.scale = 2
        let image = renderer.nsImage

        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return false
        }
    }

    // MARK: - The sheet

    private static func sheet(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(states, id: \.title) { state in
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    ActionCardView(pending: state.pending)
                        .environment(state.model)
                        .environment(NotchUIState())
                }
            }
        }
        .padding(20)
        .frame(width: width + 40)
        // The panel's own ground is Liquid Glass over whatever is behind it.
        // Flat near-black is the honest stand-in: it says "dark", which is what
        // the card's contrast is designed against, without pretending to be the
        // material.
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
    }

    struct State {
        let title: String
        let model: AssistantModel
        let pending: AssistantModel.Pending
    }

    static var states: [State] {
        [
            state("ordinary — a rule can be written",
                  question: "put the sound on the speakers",
                  proposal: audio,
                  outcome: .ask(risk: nil,
                                always: RuleGeneralizer.recommended(for: request(audio)))),
            state("floored — Always is withheld",
                  question: "tell claude to run the tests",
                  proposal: agent,
                  outcome: .ask(risk: VoiceAgentAction.riskFloorReason, always: nil)),
            state("refused by a deny rule",
                  question: "put the sound on the airpods",
                  proposal: audio,
                  outcome: .refused(rule: "Voice.AudioOutput(*)")),
            state("trial finished",
                  question: "put the sound on the speakers",
                  proposal: audio,
                  outcome: .blocked),
            state("long detail — the wrapping case",
                  question: "ask the agent to fix the failing test and then commit it",
                  proposal: longAgent,
                  outcome: .ask(risk: VoiceAgentAction.riskFloorReason, always: nil)),
        ]
    }

    private static func state(_ title: String, question: String,
                              proposal: ActionProposal,
                              outcome: VoiceActionOutcome,
                              provenance: AssistantModel.Provenance = .grammar) -> State {
        let model = AssistantModel()
        model.presentDemoAction(question: question, proposal: proposal, outcome: outcome,
                                provenance: provenance)
        return State(title: title, model: model,
                     pending: AssistantModel.Pending(proposal: proposal,
                                                     request: request(proposal),
                                                     outcome: outcome,
                                                     provenance: provenance))
    }

    private static func request(_ proposal: ActionProposal) -> PermissionRequest {
        proposal.request(id: "snapshot", at: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Fixtures
    //
    // Real proposals from the real actions, not hand-written strings: a sheet
    // that renders wording nobody ships would review the wrong thing.

    private static let audio = VoiceAudioOutputAction.propose(
        ["device": "speakers"],
        in: VoiceContext(audioOutputs: [
            AudioOutputDevice(uid: "u1", name: "MacBook Pro Speakers"),
        ]))!

    private static let agent = VoiceAgentAction.propose(
        ["prompt": "run the tests"], in: VoiceContext())!

    private static let longAgent = VoiceAgentAction.propose(
        ["prompt": "fix the failing test in VoiceGrammarTests and then commit it "
            + "with a message explaining why the interrogative list needed another word"],
        in: VoiceContext())!
}
