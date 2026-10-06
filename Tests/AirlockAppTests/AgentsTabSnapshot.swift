import AirlockCore
import AppKit
import SwiftUI
import XCTest
@testable import AirlockApp

/// Opt-in picture of the Agents tab, for looking at rather than asserting:
///
///     AIRLOCK_AGENTS_PNG=$PWD/.build/agents.png taskpolicy -c background swift test --filter AgentsTabSnapshot
///
/// Draws the real list (`AgentSessionsList`) from sample sessions — first as
/// the panel a gate opened (only the waiting card, then "Show all agents"),
/// then whole: a gate, a running Codex, a finished turn, two retired sessions
/// — then the empty tab,
/// on a black ground at the default panel width.
@MainActor
final class AgentsTabSnapshot: XCTestCase {
    private static let sectionWidth: CGFloat = 640 - 2 * 10

    func testDrawAgents() throws {
        let destination = ProcessInfo.processInfo.environment["AIRLOCK_AGENTS_PNG"] ?? ""
        try XCTSkipIf(destination.isEmpty, "Set AIRLOCK_AGENTS_PNG to a .png path to draw the Agents tab.")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "airlock-agents-snapshot"))
        defaults.removePersistentDomain(forName: "airlock-agents-snapshot")
        let model = AppModel()
        let now = Date()

        let gate = AgentSession(
            id: "a", agent: .claudeCode, projectName: "storefront", cwd: "/Users/you/storefront",
            terminal: TerminalInfo(app: "iTerm.app", tty: "ttys002"), status: .needsAttention,
            lastSummary: "Running a shell command", lastPrompt: "ship the new checkout to production",
            startedAt: now.addingTimeInterval(-27 * 60), lastActivity: now,
            pendingPermission: PermissionRequest(id: "req-1", toolName: "Bash", summary: "Run shell command",
                                                 command: "rm -rf ./dist && npm run deploy:prod", createdAt: now),
            jumpTarget: JumpTarget(terminalApp: "iTerm.app"), turns: 6)
        let running = AgentSession(
            id: "b", agent: .codex, projectName: "api-gateway", cwd: "/Users/you/api",
            terminal: TerminalInfo(app: "tmux"), status: .running,
            lastSummary: "Editing 3 files", lastPrompt: "add rate limiting to the **login** route",
            startedAt: now.addingTimeInterval(-4 * 60), lastActivity: now,
            jumpTarget: JumpTarget(terminalApp: "tmux"), turns: 2)
        let idle = AgentSession(
            id: "c", agent: .claudeCode, projectName: "airlock", cwd: "/Users/you/airlock",
            terminal: TerminalInfo(app: "ghostty"), status: .idle,
            title: "Redesign the Sound card",
            lastPrompt: "make the sound card prettier",
            lastResponse: "Done — the device is named once, at the top right, and opens the list of outputs in place. Tests pass.",
            startedAt: now.addingTimeInterval(-(3 * 3600 + 12 * 60)), lastActivity: now,
            jumpTarget: JumpTarget(terminalApp: "ghostty"), turns: 14)
        let retired = [
            AgentSession(id: "d", agent: .claudeCode, projectName: "website", status: .done,
                         title: "Fix the pricing table", lastActivity: now),
            AgentSession(id: "e", agent: .codex, projectName: "worker", status: .done,
                         lastActivity: now),
        ]

        let sheet = VStack(alignment: .leading, spacing: 28) {
            // The panel a gate opened: only what is waiting, then the way back.
            VStack(alignment: .leading, spacing: 8) {
                AgentSessionsList(sessions: [gate, running, idle] + retired)
                ShowAllAgentsLink {}
            }
            .environment(\.showsOnlyWaitingSessions, true)
            AgentSessionsList(sessions: [gate, running, idle] + retired)
            VStack(alignment: .leading, spacing: 8) {
                AgentSessionsList(sessions: [running, idle])
                QuickPromptBar(drawsAsLabel: true).padding(.horizontal, -12)
            }
            AgentsEmptyCard(line: AgentsConnection(connected: ["Claude Code"]).emptyLine, onStart: {})
        }
        .environment(model)
        .environment(RepositoryWidgetModel())
        .environment(NotchUIState())
        .environment(LicenseModel(defaults: defaults))
        .padding(16)
        .frame(width: Self.sectionWidth + 32)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: destination))
    }
}
