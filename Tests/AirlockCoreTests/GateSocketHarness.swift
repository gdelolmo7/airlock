import AirlockTestSupport
import Foundation
import XCTest
@testable import AirlockCore

/// What the gate tests need to run over a real socket: a bridge on a throwaway
/// path and policy, hooks that wait for their replies the way real ones do, a
/// record of every event the bridge emits, and a replay of those events through
/// the reducer the app uses.
enum GateSocket {
    /// A bridge with its own socket, and a policy directory the test can write
    /// rules into — the global file, and `project` as a project root with its
    /// own `.airlock/policy.yaml` once something writes one.
    ///
    /// **A class, so that holding it is the whole of the cleanup.** Everything
    /// it makes, the socket included, lives in one `TestScratch` that goes when
    /// the test's `rig` does. The socket used to be written straight into
    /// `/tmp` and left there, fifteen per run.
    final class Rig {
        let bridge: BridgeServer
        let path: String
        let globalPolicy: URL
        let project: URL
        private let scratch: TestScratch

        init(bridge: BridgeServer, path: String, globalPolicy: URL, project: URL, scratch: TestScratch) {
            self.bridge = bridge
            self.path = path
            self.globalPolicy = globalPolicy
            self.project = project
            self.scratch = scratch
        }
    }

    static func rig(policyYAML: String = "", holdLimit: TimeInterval = BridgeServer.longestHold) throws -> Rig {
        let scratch = TestScratch("an-gates")
        let project = scratch.folder("project")
        let globalPolicy = scratch.file("policy.yaml")
        try policyYAML.write(to: globalPolicy, atomically: true, encoding: .utf8)
        let path = scratch.socket()
        let bridge = BridgeServer(registry: .shared, path: path,
                                  policy: PolicyEngine(store: PolicyStore(globalFileURL: globalPolicy)),
                                  holdLimit: holdLimit)
        return Rig(bridge: bridge, path: path, globalPolicy: globalPolicy, project: project, scratch: scratch)
    }

    /// A PreToolUse payload — or another event Claude waits on, such as
    /// PermissionRequest. `cwd` is the project whose policy applies, `mode` the
    /// session's `permission_mode`, left out when nil as some events leave it.
    static func payload(session: String = "q", tool: String, input: String, at date: Date = Date(),
                        cwd: String = "/tmp/proj", event: String = "PreToolUse",
                        mode: String? = nil) -> HookPayload {
        let modeField = mode.map { #""permission_mode":"\#($0)","# } ?? ""
        let json = Data("""
        {"session_id":"\(session)","hook_event_name":"\(event)","cwd":"\(cwd)",\(modeField)\
        "tool_name":"\(tool)","tool_input":\(input)}
        """.utf8)
        return HookPayload(source: "claude-code", eventName: event, wantsDirective: true,
                           cwd: cwd, terminal: nil, payload: json, receivedAt: date)
    }

    /// A hook that waits for its reply, as a real one does. Nil if none came.
    static func hook(_ payload: HookPayload, path: String, timeout: TimeInterval = 6) -> Task<HookDirective?, Never> {
        Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: true, timeout: timeout)
        }
    }

    /// A hook that sends its gate and goes away without waiting for a reply.
    static func dyingHook(_ payload: HookPayload, path: String) async {
        _ = await Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: false, timeout: 2)
        }.value
    }

    /// Every event the bridge emits, as it emits them. An actor rather than a
    /// lock: nothing in this package takes `@unchecked Sendable` without an OS
    /// boundary to answer for, and a test is not one.
    actor Recorder {
        private(set) var all: [AgentEvent] = []
        func append(_ event: AgentEvent) { all.append(event) }
        func requests() -> [PermissionRequest] {
            all.compactMap { if case let .permissionRequested(request) = $0.kind { return request }; return nil }
        }
        func resolutions() -> [String] {
            all.compactMap { if case let .permissionResolved(id, _) = $0.kind { return id }; return nil }
        }
    }

    static func record(_ bridge: BridgeServer) -> (Recorder, Task<Void, Never>) {
        let recorder = Recorder()
        let task = Task {
            for await event in bridge.events { await recorder.append(event) }
        }
        return (recorder, task)
    }

    static func waitFor(_ condition: @escaping @Sendable () async -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func replay(_ events: [AgentEvent]) -> SessionState {
        var state = SessionState()
        for event in events { state.apply(event) }
        return state
    }
}
