import Foundation
import Testing
@testable import AirlockCore

@Suite struct DeskAgentsTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func session(_ id: String, _ status: SessionStatus, minutesAgo: Double = 1, title: String? = nil,
                 summary: String = "", project: String = "airlock",
                 gates: [PermissionRequest] = []) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, projectName: project, status: status, lastSummary: summary,
                     title: title, titleExplicit: title == nil ? nil : true,
                     lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                     pendingPermission: gates.first, queuedPermissions: Array(gates.dropFirst()))
    }

    func gate(_ id: String, command: String) -> PermissionRequest {
        PermissionRequest(id: id, toolName: "Bash", summary: command, command: command, createdAt: now)
    }

    func state(_ sessions: AgentSession...) -> SessionState {
        SessionState(sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }))
    }

    @Test func needsYouComesFirst() {
        let desk = DeskAgents.make(state(
            session("a", .running, minutesAgo: 1),
            session("b", .needsAttention, minutesAgo: 30, gates: [gate("g", command: "ls")]),
            session("c", .idle, minutesAgo: 2)
        ), isOn: true, surface: .darkGlass, now: now)
        #expect(desk.agents.map(\.id) == ["b", "a", "c"])
        #expect(desk.needingYou == 1 && desk.working == 1 && desk.surface == .darkGlass)
    }

    @Test func neverCarriesWhatWasAsked() throws {
        let command = "curl -X POST https://example.com/deploy --token q8Rz2LmP0vXa9KcW4bNt7YeJ1sHd6FgU"
        let desk = DeskAgents.make(state(
            session("b", .needsAttention, summary: command,
                    gates: [gate("g1", command: command), gate("g2", command: "rm -rf build")])
        ), isOn: true, surface: nil, now: now)
        let agent = try #require(desk.agents.first)
        #expect(agent.waiting == 2 && agent.needsYou && agent.since == nil)
        let json = String(decoding: try DeskShelf.encoder().encode(desk), as: UTF8.self)
        #expect(!json.contains("curl") && !json.contains("rm -rf") && !json.contains("q8Rz2"))
    }

    /// The desk has a budget of redraws: an agent at work must not change
    /// the snapshot at every tool call it makes.
    @Test func workChangesNothingUntilTheStateDoes() {
        let a = DeskAgents.agent(for: session("a", .running, minutesAgo: 1, summary: "Editing App.swift"))
        let b = DeskAgents.agent(for: session("a", .running, minutesAgo: 0, summary: "Reading Model.swift"))
        #expect(a == b)
        let resting = DeskAgents.agent(for: session("a", .idle, minutesAgo: 3))
        #expect(resting.since == now.addingTimeInterval(-180))
    }

    @Test func aTitleThatLooksSecretBecomesTheFolder() {
        let agent = DeskAgents.agent(for: session("a", .idle, title: "ghp_" + String(repeating: "a1B2c3D4e5", count: 4)))
        #expect(agent.title == "airlock" && agent.place == nil)
        let named = DeskAgents.agent(for: session("a", .idle, title: "Fix the login screen"))
        #expect(named.title == "Fix the login screen" && named.place == "airlock")
    }

    @Test func finishedSessionsLeaveAfterHalfAnHour() {
        let desk = DeskAgents.make(state(
            session("old", .done, minutesAgo: 45), session("new", .done, minutesAgo: 5)
        ), isOn: true, surface: nil, now: now)
        #expect(desk.agents.map(\.id) == ["new"])
    }

    @Test func offCarriesOnlyWhatNeedsAnAnswer() {
        let desk = DeskAgents.make(state(
            session("a", .running), session("b", .needsAttention, gates: [gate("g", command: "ls")])
        ), isOn: false, surface: nil, now: now)
        #expect(desk.agents.map(\.id) == ["b"] && !desk.isOn)
    }

    @Test func keepsToTheLimit() {
        let sessions = (0..<9).map { session("s\($0)", .running, minutesAgo: Double($0)) }
        let desk = DeskAgents.make(SessionState(sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })),
                                   isOn: true, surface: nil, now: now)
        #expect(desk.agents.count == DeskAgents.limit)
    }

    @Test func linksNameASessionOrNothing() {
        let agent = DeskAgents.agent(for: session("a b/c?d", .running))
        #expect(DeskAgents.sessionID(from: agent.openURL) == "a b/c?d")
        #expect(!DeskAgents.isOpenURL(agent.openURL))
        #expect(DeskAgents.isOpenURL(DeskAgents.openURL))
        #expect(DeskAgents.sessionID(from: URL(string: "https://agent?id=a")!) == nil)
        #expect(!DeskAgents.isOpenURL(URL(string: "airlock://clip")!))
    }

    @Test func snapshotRoundTrips() throws {
        let desk = DeskAgents.make(state(session("a", .running, summary: "Reading files")),
                                   isOn: true, surface: .lightGlass, now: now)
        let data = try DeskShelf.encoder().encode(desk)
        #expect(try DeskShelf.decoder().decode(DeskAgents.self, from: data) == desk)
    }
}
