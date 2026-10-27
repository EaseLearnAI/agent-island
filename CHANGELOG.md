# Changelog

Versions follow [Semantic Versioning](https://semver.org). The single source of the version is the VERSION file;
the build number is the commit count and the commit hash is embedded too, so About / --version / --check always tell
exactly which copy is running (e.g. 2.1.0 (build 2, a1b2c3d)).

## 2.1.0 — 2026-10-27

### Added
- New agents: **DeepSeek Harness** (dsh, incl. zstd-compressed session logs), **Gemini CLI**, **Qwen Code**, **OpenCode**.
- Agent icons everywhere (session rows, compact island, cards, menus, onboarding) with one resolution chain:
  your override → the agent's installed app → icon downloaded on request from the project's official GitHub → monogram.
  Menu: "下载缺失的助手图标"; CLI: --icons, --fetch-icons. No third-party logo is bundled.
- Notch ownership: one Agent Island instance at a time (any copy or version); other notch apps are detected and
  Agent Island yields until you take the notch over. Taking over suspends the other app (its LaunchAgent is unloaded and
  parked, never deleted) and "恢复被停用的刘海程序" restores it. CLI: --conflicts, --takeover, --restore.
- --open to jump to a session from the command line; build number + commit in the version string.

### Fixed
- Kimi Code: question text when the request is journaled after the state change; approval shows the actual command.
- Kimi Code / ZCode: "running" leftovers from a crashed app no longer show up as stalled sessions.
- Click-to-jump warms up Electron accessibility trees ahead of the first click.

## 2.0.0 — 2026-10-27

- First open-source release: Claude Code, Codex, Kimi Code, ZCode, MiniMax Code.
