import Foundation
import AirlockCore

// agentic-notch-setup — installs/removes an agent's hook wiring.
//
//   agentic-notch-setup install   [--agent claude-code] [--hook-path PATH]
//   agentic-notch-setup status    [--agent claude-code]
//   agentic-notch-setup uninstall [--agent claude-code]

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func resolveSourceHook(explicit: String?) -> URL? {
    if let explicit { return URL(fileURLWithPath: explicit) }
    return HookBinaryStager.locateSourceHook(near: URL(fileURLWithPath: CommandLine.arguments[0]))
}

let command = CommandLine.arguments.dropFirst().first

// Policy setup needs no agent resolution.
if command == "init-policy" {
    let store = PolicyStore()
    do {
        if try store.writeGlobalTemplateIfMissing() {
            print("Wrote starter policy → \(store.globalFileURL.path)")
        } else {
            print("Policy already exists: \(store.globalFileURL.path)")
        }
    } catch {
        fail("Could not write policy: \(error)")
    }
    exit(0)
}

let source = argument("--agent") ?? AgentKind.claudeCode.rawValue
guard let integration = AgentRegistry.shared.integration(source: source) else {
    fail("Unknown agent '\(source)'. Known: \(AgentRegistry.shared.all.map(\.source).joined(separator: ", "))")
}
let installer = integration.installer

switch command {
case "install":
    guard let sourceHook = resolveSourceHook(explicit: argument("--hook-path")) else {
        fail("Could not find the agentic-notch-hook binary next to this tool. Pass --hook-path.")
    }
    do {
        let staged = try HookBinaryStager.stage(from: sourceHook)
        try installer.install(hookBinaryPath: staged.path)
        print("Installed \(integration.kind.displayName) hooks → \(installer.configPath)")
        print("Hook binary → \(staged.path)")
        if integration.kind == .claudeCode {
            try ClaudeStatusLineInstaller().install(bridgeBinaryPath: staged.path)
            print("Status-line bridge installed (existing status line chained, display unchanged)")
        }
    } catch {
        fail("Install failed: \(error)")
    }

case "status":
    switch installer.status() {
    case .installed: print("\(integration.kind.displayName): installed")
    case .notInstalled: print("\(integration.kind.displayName): not installed")
    case .conflict(let why): print("\(integration.kind.displayName): conflict — \(why)")
    }

case "uninstall":
    do {
        try installer.uninstall()
        if integration.kind == .claudeCode {
            try ClaudeStatusLineInstaller().uninstall()
        }
        print("Removed \(integration.kind.displayName) managed hooks from \(installer.configPath)")
    } catch {
        fail("Uninstall failed: \(error)")
    }

default:
    print("""
    agentic-notch-setup — wire a coding agent's hooks to the notch

    USAGE:
      agentic-notch-setup install     [--agent \(source)] [--hook-path PATH]
      agentic-notch-setup status      [--agent \(source)]
      agentic-notch-setup uninstall   [--agent \(source)]
      agentic-notch-setup init-policy   write a starter ~/.airlock/policy.yaml
    """)
}
