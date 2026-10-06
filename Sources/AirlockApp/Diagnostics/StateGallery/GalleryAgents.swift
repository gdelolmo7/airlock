import Foundation
import SwiftUI
import AirlockCore

/// The Agents rows (A) of the inventory — Developer mode.
///
/// **Every session comes out of the real reducer**, `SessionState.apply`,
/// driven by made-up events — and where a hook is what produces the state, by
/// a made-up hook payload through the agent's own decoder first (`Story.hook`).
/// The words on a card are the shipping words, and the gallery cannot show a
/// state the reducer no longer reaches.
///
/// **What the panel puts around the list is built from values too.** The
/// `AppModel` is a fresh one that is never started — no bridge, no restored
/// cache, no liveness polling, no save — so its gate log is empty and it offers
/// no rule; A30's offer is computed by `PolicySuggestions` from a made-up log.
/// The setup cards read `AgentsWidgetModel(previewing:)`, which asks no
/// installer anything, and the licence is `LicenseModel(previewing:)`.
@MainActor
enum GalleryAgents {
    static let area = "Agents"

    static var states: [GalleryState] {
        [
            .notYet("A1", area, "Agents tab with a count",
                    why: "The count is on the tab strip (NotchTopBar), which needs the guide, dictation, assistant and battery models; the guide's init starts a workspace observer. Waits for a top-bar seam."),
            .notYet("A2", area, "\"Clear all sessions\"",
                    why: "The button is on the tab strip (NotchTopBar) — same models as A1."),
            setup("A3", "Not set up", .noHooksInstalled),
            setup("A4", "Not set up, Claude detected", .noHooksInstalled, unwired: ["Claude Code"]),
            setup("A5", "Setting up failed", .noHooksInstalled, unwired: ["Claude Code"],
                  error: AgentsWidgetModel.connectFailure(CocoaError(.fileWriteNoPermission))),
            // Switched on with nothing connected: the connect card, not A7's.
            setup("A6", "Developer mode on, nothing connected", .chosen(true)),
            setup("A7", "No agents running", .hooksInstalled),
            // A conflict still counts as present (`AgentsPresence`), but not
            // as connected: the tab names the agent and its file. The
            // Settings side is the X rows'.
            setup("A8", "Settings file conflict — the island", .hooksInstalled,
                  connection: AgentsConnection([
                      .init(name: "Claude Code", status: .installed, settingsPath: "/Users/you/.claude/settings.json"),
                      .init(name: "Codex", status: .conflict("lines Airlock didn't write"),
                            settingsPath: "/Users/you/.codex/hooks.json"),
                  ])),
            GalleryState("A9", area, "Trial ended, no sessions") {
                // What `AgentsWidget.panelSection` returns unentitled and empty.
                LicenseBlockedView(onSubscribe: {}, surface: AgentsWidget.lockedSurface)
            },
            tab("A10", "Session: starting") { story in
                // Any first event that is not `sessionStarted` creates the row.
                story.send("s", .jumpTargetUpdated(JumpTarget(terminalApp: "iTerm.app")))
            },
            tab("A11", "Session: working") { story in
                story.start("s", .codex, "api-gateway", terminal: "tmux", ago: 4)
                story.send("s", .codex, .promptSubmitted(prompt: "add rate limiting to the **login** route"))
                story.send("s", .codex, .activity(summary: "Editing 3 files"))
            },
            tab("A12", "Session: working, no detail") { story in
                story.start("s", .claudeCode, "storefront", ago: 2)
                story.send("s", .statusChanged(.running))
            },
            tab("A13", "Session: unknown event") { story in
                story.start("s", .claudeCode, "storefront", ago: 12)
                story.hook("s", "UserPromptSubmit", ["prompt": "tidy up the checkout tests"])
                story.hook("s", "PreCompact", ["trigger": "auto"])
            },
            tab("A14", "Session: plan mode") { story in
                story.start("s", .claudeCode, "storefront", ago: 6)
                story.hook("s", "UserPromptSubmit", ["prompt": "plan how we'd add Apple Pay to checkout"])
                story.hook("s", "PreToolUse", ["tool_name": "Grep", "permission_mode": "plan",
                                               "tool_input": ["pattern": "paymentMethods", "path": "src"]])
            },
            tab("A15", "Session: your turn") { story in
                story.start("s", .claudeCode, "airlock", terminal: "ghostty", ago: 192)
                story.hook("s", "UserPromptSubmit", ["prompt": "make the sound card prettier"])
                story.hook("s", "Stop", ["last_assistant_message":
                    "Done — the device is named once, at the top right, and opens the list of outputs in place. Tests pass."])
            },
            waiting("A16", "Session: needs you (the panel a gate opened)") { story in
                story.start("s", .claudeCode, "storefront", ago: 27)
                story.hook("s", "UserPromptSubmit", ["prompt": "push the checkout branch"])
                story.bash("s", "git push origin feature/checkout")
                story.start("b", .codex, "api-gateway", terminal: "tmux", ago: 4)
                story.send("b", .codex, .activity(summary: "Editing 3 files"))
            },
            waiting("A17", "Codex \"Approve in terminal\" (the panel it opened)") { story in
                story.start("s", .codex, "api-gateway", terminal: "tmux", ago: 9)
                story.hook("s", .codex, "UserPromptSubmit", ["prompt": "add rate limiting to the login route"])
                story.hook("s", .codex, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "call-1",
                                                       "tool_input": ["command": "npm install express-rate-limit"]])
            },
            GalleryState("A18", area, "Session expanded details") {
                let story = Story { story in
                    story.start("s", .claudeCode, "airlock", terminal: "ghostty", ago: 192)
                    for (prompt, reply) in [("make the sound card prettier", "First pass done."),
                                            ("name the device once, top right", "Done — tests pass.")] {
                        story.hook("s", "UserPromptSubmit", ["prompt": prompt])
                        story.hook("s", "Stop", ["last_assistant_message": reply])
                    }
                }
                inPanel {
                    if let session = story.sessions.first {
                        SessionRowView(session: session, startsExpanded: true)
                    }
                }
            },
            GalleryState("A19", area, "Jump to terminal refused") {
                // The panel stays open, and says why at the top of the list.
                let story = Story { story in
                    story.start("s", .claudeCode, "storefront", ago: 12)
                    story.hook("s", "UserPromptSubmit", ["prompt": "tidy up the checkout tests"])
                    story.hook("s", "Stop", ["last_assistant_message": "Done — 14 tests, all passing."])
                }
                inPanel(model: refusedJump) { AgentSessionsList(sessions: story.sessions) }
            },
            tab("A20", "Permission card: risky command") { story in
                story.start("s", .claudeCode, "storefront", ago: 27)
                story.hook("s", "UserPromptSubmit", ["prompt": "ship the new checkout to production"])
                story.bash("s", "rm -rf ./dist && npm run deploy:prod")
            },
            tab("A21", "Permission card: plain") { story in
                story.start("s", .claudeCode, "storefront", ago: 11)
                story.hook("s", "UserPromptSubmit", ["prompt": "run the tests and fix what fails"])
                story.bash("s", "npm test -- --watch=false")
            },
            tab("A22", "Permission card: file edit") { story in
                story.start("s", .claudeCode, "storefront", ago: 11)
                story.hook("s", "UserPromptSubmit", ["prompt": "round the cart total to cents"])
                story.hook("s", "PreToolUse", [
                    "tool_name": "Edit", "tool_use_id": "call-edit",
                    "tool_input": ["file_path": "/Users/you/storefront/src/checkout/Cart.swift",
                                   "old_string": "let total = items.map(\\.price).reduce(0, +)",
                                   "new_string": "let total = items.map(\\.price).reduce(0, +)\n    .rounded(toPlaces: 2)\nlet tax = total * region.taxRate"],
                ])
            },
            tab("A23", "Permission queue (\"2 waiting\")") { story in
                story.start("s", .claudeCode, "storefront", ago: 14)
                story.hook("s", "UserPromptSubmit", ["prompt": "update the lockfile and rerun the build"])
                story.bash("s", "npm install", id: "call-1")
                story.bash("s", "npm run build", id: "call-2")
            },
            tab("A24", "Question timed out (the card has gone)") { story in
                // The `--demo` gate, then what `ask_timeout` sends: `.deferred`.
                story.start("s", .claudeCode, "storefront", ago: 27)
                story.hook("s", "UserPromptSubmit", ["prompt": "ship the new checkout to production"])
                story.bash("s", "rm -rf ./dist && npm run deploy:prod")
                story.resolve("s", .deferred)
            },
            tab("A25", "Permission card: trial ended", license: .trialExpired) { story in
                story.start("s", .claudeCode, "storefront", ago: 27)
                story.hook("s", "UserPromptSubmit", ["prompt": "run the tests and fix what fails"])
                story.bash("s", "npm test -- --watch=false")
            },
            tab("A26", "Question card (single / multiple choice)") { story in
                story.start("s", .claudeCode, "storefront", ago: 8)
                story.ask("s", [question("Which payment provider should checkout use?", header: "Payments",
                                         ["Stripe": "Cards, Apple Pay and Google Pay",
                                          "Adyen": "Cards and local methods", "PayPal": nil])])
                story.start("b", .claudeCode, "website", terminal: "ghostty", ago: 3)
                story.ask("b", [question("Which pages should get the new footer?", header: "Footer",
                                         ["Home": nil, "Pricing": nil, "Blog": "All 40 posts"], multiSelect: true)])
            },
            tab("A27", "Question with nothing to choose") { story in
                story.start("s", .claudeCode, "storefront", ago: 8)
                // Options that parse to nothing: `QuestionPrompt.parseAll`
                // keeps the question, and the card asks for words.
                story.ask("s", [["question": "What should the new plan be called?", "options": [] as [Any]]])
            },
            tab("A28", "Receipt: asked in the terminal instead") { story in
                story.start("s", .claudeCode, "storefront", ago: 8)
                story.ask("s", [question("Which payment provider should checkout use?", header: "Payments",
                                         ["Stripe": nil, "Adyen": nil])])
                story.resolve("s", .deferred)
            },
            tab("A29", "Receipt: agent exited before you answered") { story in
                story.start("s", .claudeCode, "storefront", ago: 8)
                story.ask("s", [question("Which payment provider should checkout use?", header: "Payments",
                                         ["Stripe": nil, "Adyen": nil])])
                story.hook("s", "SessionEnd")
            },
            GalleryState("A30", area, "Rule offer (\"You've allowed this two times\")") {
                let story = Story { story in
                    story.start("s", .claudeCode, "storefront", ago: 40)
                    story.hook("s", "UserPromptSubmit", ["prompt": "run the tests and fix what fails"])
                    story.hook("s", "Stop", ["last_assistant_message": "All 212 tests pass."])
                }
                inPanel {
                    // Where the list puts it: under the sessions.
                    VStack(alignment: .leading, spacing: 8) {
                        AgentSessionsList(sessions: story.sessions)
                        if let suggestion = ruleOffer {
                            RuleSuggestionCard(suggestion: suggestion, onAccept: { _, _ in }, onDecline: {})
                        }
                    }
                }
            },
            tab("A31", "Finished sessions") { story in
                story.start("s", .claudeCode, "airlock", terminal: "ghostty", ago: 30)
                story.hook("s", "UserPromptSubmit", ["prompt": "make the sound card prettier"])
                story.hook("s", "Stop", ["last_assistant_message": "Done — tests pass."])
                for (id, project, title, agent) in [("d", "website", "Fix the pricing table", AgentKind.claudeCode),
                                                    ("e", "worker", nil, .codex),
                                                    ("f", "storefront", "Round the cart total", .claudeCode)] {
                    story.start(id, agent, project, ago: 50)
                    if let title { story.send(id, agent, ago: 50, .titleChanged(title: title)) }
                    story.send(id, agent, ago: 5, .sessionEnded)
                }
            },
            tab("A32", "More sessions than fit") { story in
                for (n, project) in ["storefront", "api-gateway", "website", "worker", "airlock"].enumerated() {
                    let id = "live-\(n)"
                    story.start(id, .claudeCode, project, ago: Double(10 + 7 * n))
                    story.hook(id, "UserPromptSubmit", ["prompt": "tidy up \(project)"])
                }
                for (n, project) in ["docs", "infra", "mobile", "design"].enumerated() {
                    let id = "done-\(n)"
                    story.start(id, .claudeCode, project, ago: 90)
                    story.send(id, ago: Double(20 + n), .sessionEnded)
                }
            },
            // The figures themselves, frozen and dated, are I15's picture.
            setup("A33", "Usage taken over by another tool", .hooksInstalled, usageStopped: true),
            GalleryState("A34", area, "Quick prompt fails — the words stay, and why") {
                inPanel(model: unopenedTerminal) {
                    VStack(alignment: .leading, spacing: 8) {
                        AgentsEmptyState(connection: AgentsConnection(connected: [AgentKind.claudeCode.displayName]))
                        // The bar pads itself off the panel's edges; the
                        // gallery's panel ground already did.
                        QuickPromptBar(text: "add rate limiting to the login route").padding(.horizontal, -14)
                    }
                }
            },
        ]
    }

    // MARK: - Drawing

    /// Never started: no bridge, no restored sessions, no liveness, no save.
    /// Its gate log is empty, so the lists below offer no rule of their own.
    private static let model = AppModel()

    /// Two more like it, each holding the one terminal failure its row is
    /// about, so the rest of the gallery never shows it.
    private static let refusedJump = troubled(.notAllowed(app: "iTerm"))
    private static let unopenedTerminal = troubled(.didNotOpen(app: "Terminal"))

    private static func troubled(_ trouble: TerminalTrouble) -> AppModel {
        let model = AppModel()
        model.terminalTrouble = trouble
        return model
    }

    /// What the panel puts around the agents section.
    private static func inPanel<Content: View>(
        _ entitlement: Entitlement = .trialing(daysRemaining: 20),
        agents: AgentsWidgetModel = AgentsWidgetModel(previewing: .hooksInstalled),
        model: AppModel = model,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .environment(model)
            .environment(agents)
            .environment(RepositoryWidgetModel())
            .environment(NotchUIState())
            .environment(LicenseModel(previewing: entitlement))
    }

    /// The Agents tab's section, as `AgentSessionsSectionView` decides it with
    /// no sessions: the setup card or the empty one.
    private static func setup(_ id: String, _ name: String, _ basis: AgentsPresence.Basis,
                              unwired: [String] = [], error: String? = nil,
                              connection: AgentsConnection? = nil, usageStopped: Bool = false) -> GalleryState {
        GalleryState(id, area, name) {
            inPanel(agents: AgentsWidgetModel(previewing: basis, unwiredAgentNames: unwired, installError: error,
                                              connection: connection, usageStopped: usageStopped)) {
                AgentSessionsSectionView()
            }
        }
    }

    /// The whole tab: the list as the panel draws it.
    private static func tab(_ id: String, _ name: String, license: Entitlement = .trialing(daysRemaining: 20),
                            _ script: @escaping @MainActor (inout Story) -> Void) -> GalleryState {
        GalleryState(id, area, name) {
            let story = Story(script)
            inPanel(license) { AgentSessionsList(sessions: story.sessions) }
        }
    }

    /// The panel an agent opened to ask: only what is waiting, each without
    /// its preview lines, then the way back to the whole tab.
    private static func waiting(_ id: String, _ name: String,
                                _ script: @escaping @MainActor (inout Story) -> Void) -> GalleryState {
        GalleryState(id, area, name) {
            let story = Story(script)
            inPanel {
                VStack(alignment: .leading, spacing: 8) {
                    AgentSessionsList(sessions: story.sessions)
                    ShowAllAgentsLink {}
                }
                .environment(\.showsOnlyWaitingSessions, true)
            }
        }
    }

    /// Two "Allow once" of the same command — what `PolicySuggestions` needs
    /// before it offers anything.
    private static var ruleOffer: PolicySuggestion? {
        let request = PermissionRequest(id: "r", toolName: "Bash", summary: "Run shell command",
                                        command: "npm test -- --watch=false",
                                        target: "npm test -- --watch=false", createdAt: Date())
        var log = GateLog()
        for minutes in [42.0, 9] {
            log.append(GateRecord(request: request, outcome: .allowedOnce,
                                  decidedAt: Date().addingTimeInterval(-minutes * 60)))
        }
        return PolicySuggestions.from(log, policy: Policy()).first
    }

    /// One `AskUserQuestion` question, as Claude writes it.
    private static func question(_ text: String, header: String, _ options: KeyValuePairs<String, String?>,
                                 multiSelect: Bool = false) -> [String: Any] {
        ["question": text, "header": header, "multiSelect": multiSelect,
         "options": options.map { label, detail -> [String: Any] in
             detail.map { ["label": label, "description": $0] } ?? ["label": label]
         }]
    }
}

/// Sessions told as the events that make them, through `SessionState.apply`.
///
/// Sequences are this story's own, counted up — the reducer drops anything
/// not newer than what it has seen, and a decoder stamps its events from the
/// clock, so its events are re-stamped in the order they are told.
@MainActor
private struct Story {
    private(set) var state = SessionState()
    private let now = Date()
    private var sequence: UInt64

    init(_ script: @MainActor (inout Story) -> Void) {
        sequence = UInt64(now.timeIntervalSince1970 * 1000) - 1_000_000
        script(&self)
    }

    var sessions: [AgentSession] { state.ordered }

    mutating func send(_ id: String, ago minutes: Double = 0, _ kind: AgentEvent.Kind) {
        send(id, .claudeCode, ago: minutes, kind)
    }

    mutating func send(_ id: String, _ agent: AgentKind, ago minutes: Double = 0,
                       _ kind: AgentEvent.Kind) {
        sequence += 1
        state.apply(AgentEvent(sessionID: id, agent: agent, sequence: sequence,
                               timestamp: now.addingTimeInterval(-minutes * 60), kind: kind))
    }

    mutating func hook(_ id: String, _ event: String, _ fields: [String: Any] = [:]) {
        hook(id, .claudeCode, event, fields)
    }

    /// A hook payload, decoded by the agent's own integration.
    mutating func hook(_ id: String, _ agent: AgentKind, _ event: String,
                       _ fields: [String: Any] = [:]) {
        var payload = fields
        payload["session_id"] = id
        payload["hook_event_name"] = event
        guard let integration = AgentRegistry.shared.integration(kind: agent),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let events = try? integration.decodeEvents(
                from: data, context: HookContext(source: integration.source, cwd: nil, terminal: nil,
                                                 receivedAt: now))
        else { return }
        for var event in events {
            sequence += 1
            event.sequence = sequence
            state.apply(event)
        }
    }

    /// `SessionStart`, and the terminal it can be jumped back to.
    mutating func start(_ id: String, _ agent: AgentKind, _ project: String,
                        terminal: String = "iTerm.app", ago minutes: Double) {
        send(id, agent, ago: minutes, .sessionStarted(project: project, cwd: "/Users/you/\(project)",
                                                      terminal: TerminalInfo(app: terminal, tty: "ttys002")))
        send(id, agent, ago: minutes, .jumpTargetUpdated(JumpTarget(terminalApp: terminal, tty: "ttys002")))
    }

    /// Claude asking to run a command — a gate, since nothing here has a policy.
    mutating func bash(_ id: String, _ command: String, id call: String = "call-1") {
        hook(id, "PreToolUse", ["tool_name": "Bash", "tool_use_id": call, "tool_input": ["command": command]])
    }

    mutating func ask(_ id: String, _ questions: [[String: Any]]) {
        hook(id, "PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "call-ask",
                                "tool_input": ["questions": questions]])
    }

    /// The card's gate ends with `decision`, as the bridge reports it.
    mutating func resolve(_ id: String, _ decision: PermissionDecision) {
        guard let session = state.sessions[id], let request = session.pendingPermission else { return }
        send(id, session.agent, .permissionResolved(requestID: request.id, decision: decision))
    }
}
