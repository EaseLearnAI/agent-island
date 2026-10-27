# Agent Island

**A Dynamic-Island-style notch HUD for your AI coding agents on macOS.**
See at a glance which agent sessions are running, which one is waiting for your answer, and which just finished — for **Claude Code, Codex, Gemini CLI, DeepSeek Harness, Qwen Code, OpenCode, Kimi Code, ZCode and MiniMax Code**, all in one place.

[中文说明](README.zh-CN.md) · [Changelog](CHANGELOG.md)

- **Live status on the notch** — running / waiting for you / stalled / done / failed / stopped, refreshed every 2 s.
- **Pop-up cards** when a session finishes, needs your answer (with the question text) or fails — with sound, can be muted.
- **Hover to expand** the session list; every row carries the agent's own icon. Click a row to jump straight to that session in its app (or to the terminal window running a CLI agent).
- **Menu bar** — all sessions, per-agent on/off switches ("数据来源"), mute, launch at login, onboarding, uninstall.
- **Plays nice with other notch apps** — one instance at a time; yields to other notch apps until you take over, and can restore them.
- **Private by design** — only reads each agent's local state files, read-only. No network (except the optional icon download you trigger), no telemetry, no API keys.

> The UI is currently in Chinese. English localization is welcome as a contribution.

## Supported agents

| Agent | Reads (read-only) | waiting for you | Click to jump | Verified |
| - | - | - | - | - |
| **Kimi Code** (desktop) | ~/.kimi-code — session state + event journal | approvals, AskUserQuestion | sidebar row | ✅ real app, end to end |
| **ZCode** (desktop) | ~/.zcode — tasks-index.sqlite + cli/db | AskUserQuestion, plan approval | sidebar row | ✅ real app, end to end |
| **MiniMax Code** (desktop) | ~/.minimax*/v2/sqlite/runtime-state.sqlite | questionnaires | sidebar row | fixtures (+ v1 field use) |
| **Claude Code** (CLI / IDE) | ~/.claude/projects/*/*.jsonl | AskUserQuestion, ExitPlanMode ¹ | terminal / editor window | fixtures |
| **Codex** (CLI / IDE / desktop) | ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl | approval requests ² | terminal / editor / app | fixtures |
| **Gemini CLI** | ~/.gemini/tmp/<project>/chats/session-*.jsonl | tool approvals, ask_user | terminal window | fixtures |
| **DeepSeek Harness** (dsh: CLI / Web / desktop) | ~/.dsh/sessions/<project>/<session>/session.vN.jsonl[.zstd] ³ | approvals, ask_user_question | app / terminal | fixtures |
| **Qwen Code** | ~/.qwen/projects/<project>/chats/*.jsonl | ask_user_question | terminal window | fixtures |
| **OpenCode** | ~/.local/share/opencode/opencode*.db | question tool (legacy schema) | app / terminal | fixtures |

"Fixtures" means the adapter is tested against synthetic data built from the agent's own source code / documented format (see test/adapters.test.mjs). Reports from real-world use are very welcome.

¹ Claude Code does not write permission prompts to its transcript, so a session waiting on one shows as *running*.
² Depends on which events your Codex version persists in its rollout file.
³ dsh compresses logs with zstd (one frame per append). Agent Island decodes them with the zstd CLI if installed (brew install zstd) or Node ≥ 22.15, which dsh users already have; without either it falls back to file-activity only.

## Install

1. Download AgentIsland-x.y.z.dmg from [Releases](../../releases), open it and drag **Agent Island** into Applications.
2. Not notarized yet: on first open use **System Settings → Privacy & Security → Open Anyway** (or xattr -dr com.apple.quarantine /Applications/AgentIsland.app). See [docs/FIRST_OPEN.md](docs/FIRST_OPEN.md).
3. Follow the onboarding: environment check (detected agents) → Accessibility (only to click the session row / raise the terminal window) → launch at login.

Requirements: macOS 14+, Apple silicon or Intel.

## Notch ownership

Only one program can draw on the notch.

- **One instance** — whichever copy or version of Agent Island you launch, a file lock lets exactly one run; a second launch hands over to the running one and quits.
- **Other notch apps** (older islands, NotchNook, boring.notch, Alcove, …) are detected. Agent Island then **yields**: it stays in the menu bar (⏸) and draws nothing on the notch.
- **Take over** (menu, or --takeover): quits the other app; if a LaunchAgent keeps relaunching it, the agent is unloaded and its plist is parked in ~/Library/Application Support/AgentIsland/suspended — nothing is deleted.
- **Restore** (menu "恢复被停用的刘海程序", or --restore): puts the LaunchAgents back, reloads them and reopens the apps.

## Agent icons

Every surface uses one resolution chain: **your override** (~/Library/Application Support/AgentIsland/icons/<id>.png) → **the agent's installed app icon** → **an icon downloaded on request** from the project's official GitHub (menu "下载缺失的助手图标", or --fetch-icons) → **a monogram** in the agent's colour. No third-party logo is bundled in this repository or the app; all product names and logos belong to their owners, and Agent Island is not affiliated with or endorsed by any of them.

## Versioning

The VERSION file is the single source of the version ([SemVer](https://semver.org)); the build number is the commit count and the commit hash is embedded, so About, --version and --check always show exactly which copy is running, e.g. 2.1.0 (build 3, a1b2c3d). Each release is tagged vX.Y.Z with notes in [CHANGELOG.md](CHANGELOG.md).

## Build from source

    bash scripts/build.sh                          # universal binary + signing + DMG + zip → build/
    node --test test/adapters.test.mjs             # adapter tests on synthetic fixtures (never touch real data)

Command line (handy for debugging an adapter):

    B=build/AgentIsland.app/Contents/MacOS/AgentIsland
    $B --snapshot --agents kimi,zcode      # one snapshot as JSON, only the listed agents
    $B --snapshot --home /path/to/fixture  # read agent data from another "home" folder
    $B --check                             # version, detected agents, permissions, login item
    $B --open "<session title>"            # jump to a session exactly like a click on the island
    $B --icons [OUT_DIR] / --fetch-icons   # where icons come from / download missing ones
    $B --conflicts / --takeover / --restore

## How it works

Every agent is one AgentSource (Sources/*Source.swift) that maps the agent's local files to a common session model (state, title, project, question, updated time). Sources/Store.swift reads all enabled sources in parallel every 2 s; the island diffs consecutive snapshots to decide when to pop a card. Desktop apps offer no "open session" deeplink, so a click uses macOS Accessibility to press the sidebar row whose label equals the session title (Sources/Jump.swift); CLI sessions raise the terminal/editor window whose title contains the project folder name.

### Adding another agent

1. Create Sources/YourAgentSource.swift implementing AgentSource: an AgentInfo (id, name, colour, desktop bundle ids, official icon URL), dataPaths(home:) and sessions(home:now:).
2. Map the agent's state to running / waiting / stalled / done / failed / stopped with the shared helpers (SQLite.query read-only, Files.tailLines, SessionState.running…).
3. Register it in Agents.all (Sources/Agents.swift) and add fixtures to test/adapters.test.mjs.

Pull requests for Cursor, Windsurf, Copilot CLI, Aider, Amp, Factory Droid, etc. are welcome.

## License

[MIT](LICENSE)
