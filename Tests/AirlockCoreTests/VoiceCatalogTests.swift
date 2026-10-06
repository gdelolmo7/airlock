import XCTest
@testable import AirlockCore

/// The catalogue's invariants, and — more importantly — that a spoken action
/// cannot borrow an agent's permissions or escape the safety floor.
final class VoiceCatalogTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func voiceRequest(_ toolName: String, _ subject: String) -> PermissionRequest {
        PermissionRequest(id: "r", toolName: toolName, summary: "spoken",
                          target: subject, createdAt: epoch)
    }

    // MARK: - Registry hygiene

    func testEveryActionIsNamespacedAndUnique() {
        let names = VoiceActionCatalog.all.map { $0.toolName }
        XCTAssertEqual(Set(names).count, names.count, "duplicate tool name in the catalogue")
        for name in names {
            XCTAssertTrue(VoiceActionCatalog.isVoiceTool(name),
                          "\(name) is missing the Voice. prefix — an agent's allow rule could match it")
        }
    }

    /// Every line is in the prompt for every spoken word, and a long enumeration
    /// is the easiest thing for a small model to quote back instead of acting.
    func testCatalogueLinesStayInsideTheBudget() {
        for action in VoiceActionCatalog.all {
            XCTAssertLessThanOrEqual(action.summary.count,
                                     VoiceActionCatalog.maximumSummaryLength,
                                     "\(action.toolName) summary is too long for the prompt")
            XCTAssertFalse(action.parameters.isEmpty, "\(action.toolName) takes no arguments")
        }
    }

    func testPromptCatalogueListsExactlyWhatIsRegistered() {
        let text = VoiceActionCatalog.promptCatalogue()
        for action in VoiceActionCatalog.registered {
            XCTAssertTrue(text.contains(action.toolName), "\(action.toolName) missing from the prompt")
        }
        // The other half of the invariant, and the one with teeth: offering an
        // action the app cannot perform is a dead end where the model names it,
        // nothing happens, and from the outside the app ignored you.
        for action in VoiceActionCatalog.all
        where !VoiceActionCatalog.registered.contains(where: { $0.toolName == action.toolName }) {
            XCTAssertFalse(text.contains(action.toolName),
                           "\(action.toolName) is advertised but not registered")
        }
    }

    func testRegisteredIsASubsetOfEverything() {
        for action in VoiceActionCatalog.registered {
            XCTAssertNotNil(VoiceActionCatalog.action(named: action.toolName),
                            "\(action.toolName) is registered but not in `all`")
        }
    }

    /// An action outside the offering must not resolve from a reply, and must
    /// still resolve as a NAME — a rule left in `policy.yaml` from a build where
    /// it was offered has to keep reading as itself, floor included.
    func testAnActionOutsideTheOfferingStillResolvesAsAName() {
        let audioOnly: [any VoiceAction.Type] = [VoiceAudioOutputAction.self]
        XCTAssertNil(VoiceActionCatalog.resolve(name: "Voice.Agent", offering: audioOnly))
        XCTAssertNotNil(VoiceActionCatalog.action(named: "Voice.Agent"))
        XCTAssertNotNil(RiskAssessor.assess(voiceRequest("Voice.Agent", "airlock")))
        XCTAssertEqual(RuleGeneralizer.candidates(for: voiceRequest("Voice.Agent", "airlock"))[0].text,
                       "Voice.Agent(airlock)")
    }

    // MARK: - Name resolution

    func testActionNamesAreResolvedLeniently() {
        let context = VoiceContext(audioOutputs: [AudioOutputDevice(uid: "u", name: "AirPods Pro")])
        for spelling in ["Voice.AudioOutput", "audiooutput", "AUDIO_OUTPUT", " voice.audio output "] {
            XCTAssertNotNil(
                VoiceActionCatalog.propose(actionNamed: spelling,
                                           arguments: ["device": "airpods"], in: context),
                "failed to resolve \(spelling)")
        }
    }

    /// Never a guess at the closest action — the closest action to "clipboard"
    /// is one that sends an instruction to a coding agent.
    func testUnknownActionNameProposesNothing() {
        XCTAssertNil(VoiceActionCatalog.propose(actionNamed: "Voice.SendEmail",
                                                arguments: ["to": "a@b.c"], in: VoiceContext()))
        XCTAssertNil(VoiceActionCatalog.action(named: "Bash"))
    }

    // MARK: - Policy isolation (the one that must never regress)

    func testAnAgentAllowRuleNeverMatchesASpokenRequest() throws {
        let policy = try PolicyParser.parse("allow:\n  - Read\n  - Bash(*)\n  - Clipboard(*)")
        let verdict = PolicyEngine.evaluate(voiceRequest("Voice.Clipboard", "Figma"), policy: policy)
        XCTAssertEqual(verdict, .ask(risk: nil),
                       "an allow rule written for an agent authorised a spoken action")
    }

    func testASpokenAllowRuleNeverMatchesAnAgentRequest() throws {
        let policy = try PolicyParser.parse("allow:\n  - Voice.Clipboard(*)")
        let read = PermissionRequest(id: "r", toolName: "Read", summary: "Read",
                                     target: "/etc/passwd", createdAt: epoch)
        XCTAssertEqual(PolicyEngine.evaluate(read, policy: policy), .ask(risk: nil))
    }

    func testASpokenAllowRuleMatchesItsOwnSubject() throws {
        let policy = try PolicyParser.parse("allow:\n  - Voice.AudioOutput(AirPods Pro)")
        XCTAssertEqual(
            PolicyEngine.evaluate(voiceRequest("Voice.AudioOutput", "AirPods Pro"), policy: policy),
            .allow(rule: "Voice.AudioOutput(AirPods Pro)"))
        // A different device is a different rule.
        XCTAssertEqual(
            PolicyEngine.evaluate(voiceRequest("Voice.AudioOutput", "Kitchen TV"), policy: policy),
            .ask(risk: nil))
    }

    // MARK: - The floor

    func testTheFloorSurvivesAnExactAllowRule() throws {
        let policy = try PolicyParser.parse("allow:\n  - Voice.Agent(*)\n  - Voice.Agent(airlock)")
        let verdict = PolicyEngine.evaluate(voiceRequest("Voice.Agent", "airlock"), policy: policy)
        guard case .ask(let risk) = verdict else {
            return XCTFail("an allow rule auto-approved a spoken agent instruction: \(verdict)")
        }
        XCTAssertEqual(risk, VoiceAgentAction.riskFloorReason)
    }

    func testDenyStillBeatsTheFloor() throws {
        let policy = try PolicyParser.parse("deny:\n  - Voice.Agent(*)")
        XCTAssertEqual(PolicyEngine.evaluate(voiceRequest("Voice.Agent", "airlock"), policy: policy),
                       .deny(rule: "Voice.Agent(*)"))
    }

    /// Spoken subjects must not be run past the shell regexes: a clip copied
    /// from Terminal, or one whose text mentions sudo, is not a risky command.
    func testShellPatternsDoNotLeakIntoSpokenSubjects() {
        for subject in ["Terminal", "sudo rm -rf /", "git push --force"] {
            XCTAssertNil(RiskAssessor.assess(voiceRequest("Voice.Clipboard", subject)),
                         "shell risk pattern matched a spoken subject: \(subject)")
        }
    }

    // MARK: - Rule wording

    func testAlwaysWritesAnExactRuleAndDescribesItHonestly() {
        let request = voiceRequest("Voice.Clipboard", "Figma")
        let candidates = RuleGeneralizer.candidates(for: request)

        // A non-path subject yields no widening — `pathCandidates` guards on a
        // leading slash — so the exact rule is the only one, and `recommended`
        // must return it rather than inventing something broader.
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].text, "Voice.Clipboard(Figma)")
        XCTAssertEqual(RuleGeneralizer.recommended(for: request).text, "Voice.Clipboard(Figma)")

        // It used to say "Only this file" for every non-Bash tool.
        XCTAssertEqual(candidates[0].summary, VoiceClipboardAction.exactRuleSummary)
        XCTAssertNotEqual(candidates[0].summary, "Only this file")
    }

    func testEveryCandidateStillMatchesTheRequestItCameFrom() throws {
        // The generaliser's absolute invariant, re-asserted for spoken subjects.
        for (tool, subject) in [("Voice.Clipboard", "Figma"),
                                ("Voice.AudioOutput", "AirPods Pro"),
                                ("Voice.Agent", "new session")] {
            let request = voiceRequest(tool, subject)
            for candidate in RuleGeneralizer.candidates(for: request) {
                let rule = try PolicyRule(parsing: candidate.text)
                XCTAssertTrue(rule.matches(request),
                              "\(candidate.text) does not match the request it came from")
            }
        }
    }

    // MARK: - The seam

    func testProposalBecomesAPermissionRequest() {
        let proposal = ActionProposal(toolName: "Voice.AudioOutput", subject: "AirPods Pro",
                                      summary: "Send sound to AirPods Pro",
                                      effect: .selectAudioOutput(uid: "u2"))
        let request = proposal.request(id: "abc", at: epoch)
        XCTAssertEqual(request.id, "abc")
        XCTAssertEqual(request.toolName, "Voice.AudioOutput")
        XCTAssertEqual(request.target, "AirPods Pro")
        XCTAssertEqual(request.summary, "Send sound to AirPods Pro")
        // Never populated: a spoken phrase in `command` would be read by the
        // shell risk patterns, and by anything else that assumes a command.
        XCTAssertNil(request.command)
        XCTAssertNil(request.diff)
        XCTAssertNil(request.question)
    }
}
