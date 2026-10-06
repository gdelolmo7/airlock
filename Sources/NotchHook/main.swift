import Foundation
import AirlockCore

// agentic-notch-hook — the tiny CLI agents invoke.
//
// Contract: read the agent's JSON on stdin, forward it to the app over the
// bridge socket, and — only for a permission gate — wait for a decision and
// echo the agent-specific directive to stdout. EVERY failure path exits 0
// without output, so a missing or slow app can never wedge the agent.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// One `ps` snapshot yields both enrichments: our controlling TTY (inherited
/// from the agent even though our stdio is piped) and the agent's PID, found
/// by walking our parent chain for a process the integration recognizes.
func processEnrichment(integration: (any AgentIntegration)?) -> (tty: String?, agentPID: Int32?) {
    guard let snapshot = ProcessSnapshot.capture() else { return (nil, nil) }
    let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let tty = snapshot.entry(selfPID)?.tty
    let agent = integration.flatMap { integration in
        snapshot.ancestor(of: selfPID) { integration.matchesProcess(command: $0.command) }
    }
    return (tty ?? agent?.tty, agent?.pid)
}

func detectTerminal(tty: String?) -> TerminalInfo {
    let env = ProcessInfo.processInfo.environment
    let app = env["TERM_PROGRAM"] ?? "terminal"
    return TerminalInfo(
        app: app,
        tty: tty ?? env["TTY"],
        sessionID: env["ITERM_SESSION_ID"] ?? env["TMUX_PANE"],
        windowTitle: nil
    )
}

// Every stdin and stdout call below is the throwing kind. The legacy
// `readDataToEndOfFile()` and `write(_:)` raise an Objective-C exception on an
// I/O error instead, which Swift cannot catch — no `catch` here would ever see
// it, and the hook would crash rather than fail open.

// Status-line bridge mode: cache rate limits, chain the user's original
// status line, print its output. Shares the binary so installs stay one file.
if CommandLine.arguments.contains("--statusline") {
    // Unreadable stdin is treated exactly as empty stdin: nothing to cache,
    // and the user's own status line still runs and prints.
    let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
    let output = StatusLineBridge.process(
        input: input,
        cacheURL: UsageSnapshot.defaultCacheURL(),
        chainCommandB64: argument("--chain-b64")
    )
    try? FileHandle.standardOutput.write(contentsOf: output)
    exit(0)
}

// Fail-open: any thrown error ends here quietly with a success exit code.
do {
    let source = argument("--source") ?? AgentKind.claudeCode.rawValue
    let eventName = argument("--event")
    // A read error lands in the `catch` below: exit 0, nothing sent, nothing
    // printed. No stdin at all is still an empty payload, as it always was.
    let payload = try FileHandle.standardInput.readToEnd() ?? Data()

    let integration = AgentRegistry.shared.integration(source: source)
    let wantsDirective = integration?.isBlocking(eventName: eventName) ?? false

    let env = ProcessInfo.processInfo.environment
    let cwd = env["PWD"] ?? FileManager.default.currentDirectoryPath
    let enrichment = processEnrichment(integration: integration)

    let hookPayload = HookPayload(
        source: source,
        eventName: eventName,
        wantsDirective: wantsDirective,
        cwd: cwd,
        terminal: detectTerminal(tty: enrichment.tty),
        agentPID: enrichment.agentPID,
        payload: payload,
        receivedAt: Date()
    )

    let directive = try UnixSocketClient.send(
        path: SocketPath.default(),
        envelopes: [.hello(protocolVersion: BridgeEnvelope.protocolVersion), .hookPayload(hookPayload)],
        awaitDirective: wantsDirective,
        // 24h for a permission gate; a short beat otherwise so a non-blocking
        // hook returns almost instantly.
        timeout: wantsDirective ? HookDirective.blockingWait : 2
    )

    if let directive, let output = integration?.directiveOutput(for: directive, eventName: eventName) {
        try FileHandle.standardOutput.write(contentsOf: output)
    }
    exit(0)
} catch {
    exit(0)
}
