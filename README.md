# Agent Island

**A Dynamic-Island-style notch HUD for your AI coding agents on macOS.**
See at a glance which agent sessions are running, which one is waiting for your answer, and which just finished — for **Claude Code, Codex, Kimi Code, ZCode and MiniMax Code**, all in one place.

[中文说明](README.zh-CN.md)

- **Live status on the notch** — running / waiting for you / stalled / done / failed / stopped, refreshed every 2 s.
- **Pop-up cards** when a session finishes, needs your answer (with the question text) or fails — with sound, can be muted.
- **Hover to expand** the session list; each row shows which agent it belongs to. Click a row to jump straight to that session in its app (or to the terminal window running a CLI agent).
- **Menu bar** — all sessions, per-agent on/off switches ("Data sources"), mute, launch at login, onboarding, uninstall.
- **Private by design** — only reads each agent's local state files, read-only. No network, no telemetry, no API keys.
- Works on Macs **without a notch** too (hover the top-center of the screen or use the menu bar icon).

> The UI is currently in Chinese. English localization is welcome as a contribution.

## Supported agents

| Agent | Reads (read-only) | running | waiting for you | done / failed / stopped | Click to jump |
| - | - | - | - | - | - |
| **Kimi Code** (desktop) | ~/.kimi-code (session state + event journal) | ✅ | ✅ approval & question | ✅ | ✅ sidebar row |
| **ZCode** (desktop) | ~/.zcode/v2/tasks-index.sqlite + ~/.zcode/cli/db | ✅ | ✅ AskUserQuestion / plan approval | ✅ | ✅ sidebar row |
| **MiniMax Code** (desktop) | ~/.minimax*/v2/sqlite/runtime-state.sqlite | ✅ | ✅ questionnaires | ✅ | ✅ sidebar row |
| **Claude Code** (CLI / IDE) | ~/.claude/projects/*/*.jsonl | ✅ | ✅ AskUserQuestion / ExitPlanMode ¹ | ✅ | terminal / editor window |
| **Codex** (CLI / IDE / desktop) | ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl | ✅ | ✅ approval requests ² | ✅ | terminal / editor / app |

Verification status: Kimi Code and ZCode were tested end-to-end against the real desktop apps (live sessions, state transitions, click-to-jump). Claude Code and Codex adapters are covered by fixture tests built from their documented transcript formats — reports from real-world use are very welcome.

¹ Claude Code does not write permission prompts to its transcript, so a session waiting on a permission prompt shows as *running*.
² Depends on which events your Codex version persists in its rollout file; older versions fall back to tool-call pairing.

## Install

1. Download AgentIsland-x.y.z.dmg from [Releases](../../releases), open it and drag **Agent Island** into Applications.
2. The app is not notarized yet. On first open macOS will block it: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** (or run xattr -dr com.apple.quarantine /Applications/AgentIsland.app).
3. Follow the onboarding: environment check (which agents were detected) → Accessibility permission (only used to click the session row / raise the terminal window) → launch at login.

Requirements: macOS 14+, Apple silicon or Intel.

## Build from source

    bash scripts/build.sh                          # universal binary + ad-hoc/dev signing + DMG + zip → build/
    node --test test/adapters.test.mjs             # adapter tests on synthetic fixtures (never touch real data)

With a Developer ID certificate: NOTARY_PROFILE=<keychain profile> bash scripts/build.sh signs with hardened runtime and notarizes.

Command line (handy for debugging an adapter):

    B=build/AgentIsland.app/Contents/MacOS/AgentIsland
    $B --snapshot --agents kimi,zcode      # one snapshot as JSON, only the listed agents
    $B --snapshot --home /path/to/fixture  # read agent data from another "home" folder
    $B --check                             # detected agents, permissions, login item
    $B --open "<session title>"            # jump to a session exactly like a click on the island
    $B --preview list --seconds 10         # render a UI state with sample data

## How it works

Every agent is one AgentSource (Sources/*Source.swift) that maps the agent's local files to a common session model (state, title, project, question, updated time). Sources/Store.swift reads all enabled sources in parallel every 2 s; the island diffs consecutive snapshots to decide when to pop a card.

Desktop apps don't offer a "open session" deeplink, so clicking a session uses macOS Accessibility to find the sidebar row whose label equals the session title and presses it (Sources/Jump.swift). CLI sessions raise the terminal/editor window whose title contains the project folder name.

### Adding another agent

1. Create Sources/YourAgentSource.swift implementing AgentSource: an AgentInfo (id, name, colour, desktop bundle ids), dataPaths(home:) and sessions(home:now:).
2. Map the agent's state to running / waiting / stalled / done / failed / stopped. Use the shared helpers: SQLite.query (read-only), Files.tailLines, SessionState.running(...).
3. Register it in Agents.all (Sources/Agents.swift) and add a fixture test in test/adapters.test.mjs.

Pull requests for Cursor, Windsurf, Gemini CLI, Aider, OpenCode, etc. are welcome.

## Privacy

Agent Island never writes to any agent's files, never sends data anywhere and has no analytics. SQLite databases are opened read-only and closed right after each query; JSONL transcripts are tail-read.

## License

[MIT](LICENSE)
