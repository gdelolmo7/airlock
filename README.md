# Airlock

**Everything your Mac's notch should already do.** Clipboard history, a shelf to
park files, output switching without System Settings, meetings you can actually
join, on-device dictation — in the notch you already have.

And, for anyone who uses them, the part no other notch app does: it **drives**
your terminal coding agents rather than watching them. Live sessions, inline
approve/deny of permission prompts with a policy layer behind them, and
one-click jump-back to the exact terminal tab. That surface is optional and
defaults off when no agent hooks are installed — see `AgentsPresence`.

**Get it at [useairlock.app](https://useairlock.app)** — 14 days free with
nothing held back and no card, then €3.99/month or €35.99/year. Or
`brew install --cask gdelolmo7/tap/airlock`.

The source is here to read, learn from and build for yourself. It is
**source-available, not open source**: see [Code terms](#code-terms) before
doing anything with it beyond that.

## Requirements

- macOS 26+ on a Mac with a notch (MacBook Pro 2021+, Air 2022+). The notch is
  the product, and every Mac that has one runs 26 — so the hardware floor sets
  the software one. Liquid Glass is then unconditional rather than a variant
  half the users never see.
- Swift 6 / Xcode 26 (developed on Swift 6.3)

## Build & run

```bash
swift build
swift test

# Run the app with sample sessions so you can see the notch UI:
AIRLOCK_DEMO=1 swift run AirlockApp
```

A build of your own is the same app as the download, including its 14-day
trial: what you buy at useairlock.app is the subscription, not a different
program.

The status-bar menu has **Show / Hide Panel**, **Settings…** (⌘,), **Setup
Guide…** and **Quit Airlock**. Settings covers agent
hook install/uninstall (live status, conflict detection) and the policy file
(rule counts, parse problems surfaced loud, create/open/reveal) — everything
the CLI does, in-app.

### Wire up your agents

```bash
swift build
swift run NotchSetup install                    # Claude Code → ~/.claude/settings.json
swift run NotchSetup install --agent codex      # Codex → ~/.codex/config.toml (managed block)
swift run NotchSetup status  [--agent codex]
swift run NotchSetup uninstall [--agent codex]   # removes only our entries, preserves yours
```

Hooks **fail open**: if the app isn't running, your agent is unaffected.

| Agent | Events | Approvals |
|---|---|---|
| **Claude Code** | full hook set, schema-verified | inline Approve / Deny / Always + policy engine |
| **Codex** | SessionStart / UserPromptSubmit / Stop (hooks are observational per Codex docs) | surfaced as "approve in terminal" attention; no fake buttons |

Adding an agent = one `AgentIntegration` conformer + one registry line — both
existing integrations share the Claude-style payload decoder the ecosystem
converged on.

## The policy engine

The notch auto-handles the boring 90% and only interrupts you for the risky
10%.

```bash
swift run NotchSetup init-policy   # writes a commented starter policy
```

Rules live in `~/.airlock/policy.yaml` (global) merged with
`<project>/.airlock/policy.yaml` (per-project). Format:

```yaml
version: 1
ask_timeout: 300        # unanswered gates defer to the agent's own prompt

allow:
  - Read                # any use of a tool
  - Bash(git status)    # exact command
  - Bash(git diff *)    # glob on the command (file path for Edit/Write)

deny:
  - Bash(*rm -rf /*)
```

**Precedence is safety-first:** `deny` rules → the built-in **risk floor**
(`rm -rf`, `sudo`, force-push, pipe-to-shell, prod deploys, … always *ask*,
even when an allow rule matches) → `allow` rules → ask.

- Auto-denied agents are told **which rule** denied them and where the policy
  file lives, so they can explain instead of flailing.
- The **Always** button persists an exact allow rule (project policy when the
  session has a cwd, global otherwise) — textually, preserving your comments.
- A malformed policy file **fails loud** (parse errors name the line and land
  in the log), never silently as "no rules".

## Package it

```bash
zsh scripts/setup-dev-signing.sh    # once: a stable self-signed identity
zsh scripts/package-app.sh          # → output/package/Airlock.app + .dmg
```

macOS keys Accessibility, Input Monitoring and Automation grants to the signing
identity — ad-hoc builds get a new signature every rebuild and silently lose
those grants. One stable dev identity means you grant permissions once.
Launch the packaged app with `open`, not by running the binary, or macOS
credits its permission requests to your terminal and refuses them.

The bundle embeds the hook + setup CLIs next to the app executable and is
signed inside-out. `scripts/release.sh` is the notarized build the website
ships; it needs a Developer ID certificate and is there for reading.

## Architecture

One Swift package. The main targets:

| Target | Role |
|---|---|
| **AirlockCore** | UI-free library: domain model, the pure `SessionState` reducer, the NDJSON bridge protocol, the hardened Unix-socket transport, the agent registry, policy and licensing. |
| **AirlockApp** | SwiftUI + AppKit shell — the notch panel, widgets, Settings, `AppModel`, status item. |
| **NotchHook** (`airlock-hook`) | Tiny fail-open CLI agents invoke. Forwards stdin → bridge; echoes a directive only when blocking. |
| **NotchSetup** (`airlock-setup`) | Installer CLI that wires an agent's config to the hook binary. |

Data flow:

```
agent hook → airlock-hook (stdin) → Unix socket (NDJSON)
           → BridgeServer (actor) → SessionState.apply → notch UI
           → approve/deny → directive back to the waiting hook
```

- **Compiler-verified concurrency.** Swift 6 language mode everywhere;
  `BridgeServer` is an `actor` and domain state is never touched off-actor.
- **Protocol-driven agents and widgets.** One conformer + one registry line,
  never branches scattered across the app.
- **Pure, monotonic reducer.** `SessionState.apply` is the single source of
  truth and drops stale/duplicate events by a per-session `sequence` guard.
- **Hardened IPC.** Peer-credential check (same-uid only), `0600` socket, and a
  hard per-line framing cap.
- **Licensing without a database.** A stateless Cloudflare Worker swaps a Lemon
  Squeezy key for a signed Ed25519 token that carries its own dates, so the
  server being down invalidates nobody.

## Contributing

Issues and pull requests are welcome. Every contribution is made under the
contributor agreement in [CONTRIBUTING.md](CONTRIBUTING.md), because Airlock is
sold: it lets your change ship in the paid app.

## Code terms

Airlock's source is published under the
[PolyForm Strict License 1.0.0](LICENSE), with one addition. In plain words:

- **You may** read the code, and build and use it yourself for personal,
  noncommercial purposes.
- **You may also** change it for your own personal, noncommercial use, and to
  prepare a contribution to this repository (forking it on GitHub for that is
  fine). This is the additional permission at the end of [LICENSE](LICENSE).
- **You may not** share builds or changed copies, sell it, or use it for
  commercial purposes. Using Airlock at or for a business means a
  subscription from [useairlock.app](https://useairlock.app).

[LICENSE](LICENSE) is what counts; this list is a summary of it. Third-party
code keeps its own licence ([THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt)).

Airlock is a clean-room implementation: it contains no code from
open-vibe-island or any other GPL-licensed project.

Copyright (c) 2026 Guillermo del Olmo.
