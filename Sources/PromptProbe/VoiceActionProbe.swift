import Foundation
import AirlockCore
import AirlockGenerable

/// The pure half of the voice-action path, runnable by hand.
///
///     swift run PromptProbe actions --dry Voice.AudioOutput device="AirPods Pro"
///     swift run PromptProbe actions --dry Voice.Clipboard query=Figma
///     swift run PromptProbe actions --dry Voice.Agent prompt="run the tests"
///
/// `--dry` means **no model**: you supply the arguments the model would have
/// produced, and this prints everything that happens after — resolution against
/// a sample context, the `PermissionRequest`, the verdict from *your* real
/// policy files, and the exact rule an Always click would write.
///
/// It exists because Phase 1 of the voice-actions plan ships no UI and no model
/// adapter, and "the tests pass" is a weak thing to hand someone who wants to
/// see whether the wording on a card would read properly. Everything it prints
/// is the same code the app will call.
enum VoiceActionProbe {
    /// What the app will assemble from its live models.
    ///
    /// `ActionEvaluation.context` rather than a second fixture: a dry run and a
    /// scored run that disagree about which devices exist would send anyone
    /// debugging a case off after a difference that is not there.
    static let sampleContext = ActionEvaluation.context

    /// Returns the process exit code.
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.first == "--dry" else {
            guard arguments.isEmpty || arguments == ["--classifier"] else {
                printErr("""
                    usage: swift run PromptProbe actions               # score both configurations
                           swift run PromptProbe actions --classifier  # skip the dead one
                           swift run PromptProbe actions --dry …       # the pure path, no model
                    """)
                return 2
            }
            return await ActionScoring.run(classifierOnly: arguments == ["--classifier"])
        }
        let rest = Array(arguments.dropFirst())
        guard let name = rest.first else {
            printErr("name an action. Available:\n" + VoiceActionCatalog.promptCatalogue())
            return 2
        }

        var values: [String: String] = [:]
        for pair in rest.dropFirst() {
            guard let split = pair.firstIndex(of: "=") else {
                printErr("arguments are key=value — got '\(pair)'")
                return 2
            }
            values[String(pair[..<split])] = String(pair[pair.index(after: split)...])
        }

        print("\n═══ catalogue, as the model sees it")
        print(VoiceActionCatalog.promptCatalogue())

        print("\n═══ sample context")
        print("  audio    " + sampleContext.audioOutputs.map(\.name).joined(separator: ", "))
        for (index, clip) in sampleContext.clipboard.enumerated() {
            let source = clip.sourceAppName.map { " from \($0)" } ?? ""
            print("  clip \(index + 1)   “\(clip.preview)”\(source)")
        }
        print("  agents   " + (sampleContext.agentSessions.map(\.label).joined(separator: ", ")
                               .ifEmpty("(none running)")))

        print("\n═══ \(name) \(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

        guard let proposal = VoiceActionCatalog.propose(actionNamed: name, arguments: values,
                                                        in: sampleContext) else {
            // Not a failure of the probe. This is the designed answer to a
            // request that names nothing real, and seeing it is the point.
            print("  → nothing doable. No card would be shown.")
            return 0
        }

        print("  summary  \(proposal.summary)")
        if let detail = proposal.detail { print("  detail   \(detail)") }
        print("  subject  \(proposal.subject)")
        print("  effect   \(describe(proposal.effect))")

        let request = proposal.request(id: "probe", at: Date(timeIntervalSince1970: 0))
        let decision = PolicyEngine().plan(for: request, projectRoot: nil)
        print("\n  verdict  \(describe(decision.verdict))   (from your real policy files)")

        if case .allow = decision.verdict {
            print("           performed without a card.")
        } else {
            let candidate = RuleGeneralizer.recommended(for: request)
            let floored = RiskAssessor.assess(request) != nil
            print("  always   " + (floored
                ? "not offered — \(RiskAssessor.assess(request)?.reason ?? "risk floor")"
                : "\(candidate.text)   (\(candidate.summary))"))
        }
        return 0
    }

    private static func describe(_ effect: VoiceEffect) -> String {
        switch effect {
        case .copyClipboardItem(let id): return "copy clipboard entry \(id)"
        case .selectAudioOutput(let uid): return "select audio output \(uid)"
        case .sendPrompt(let sessionID, let text):
            return "send to \(sessionID ?? "a new session"): \(text)"
        case .runShortcut(let name): return "run shortcut \(name)"
        case .setVolume(let level): return "set volume to \(Int(level * 100))%"
        case .media(let command): return "media \(command.rawValue)"
        case .open(let target):
            switch target {
            case .app(let path): return "open app at \(path)"
            case .url(let url): return "open \(url)"
            }
        }
    }

    private static func describe(_ verdict: PolicyVerdict) -> String {
        switch verdict {
        case .allow(let rule): return "ALLOW by \(rule)"
        case .deny(let rule): return "DENY by \(rule)"
        case .ask(let risk): return "ASK" + (risk.map { " — \($0)" } ?? "")
        }
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
