// Aggregates every enabled agent source into one snapshot.
// Read-only: each source opens its files / databases read-only and closes them right away.
import Foundation

enum SessionStore {
    /// Agents whose local data exists on this Mac (enabled or not).
    static func detected(home: String = Agents.home) -> [AgentSource] {
        Agents.all.filter { !$0.dataPaths(home: home).isEmpty }
    }

    static func snapshot(home: String = Agents.home, now: Int64 = Timing.nowMs(), limit: Int = 16) -> LiveSnapshot {
        let sources = Agents.enabled.filter { !$0.dataPaths(home: home).isEmpty }
        guard !sources.isEmpty else {
            let anyData = !detected(home: home).isEmpty
            return LiveSnapshot(running: 0, waiting: 0, stalled: 0, sessions: [], agents: [], issues: [:],
                                error: anyData ? "支持的助手都被你在菜单「数据来源」里关掉了" :
                                    "没找到任何支持的 AI 编程助手数据（MiniMax Code / Claude Code / Codex / Kimi Code / ZCode）")
        }
        var all: [LiveSession] = []
        var issues: [String: String] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            let s = sources[i]
            do {
                let list = try s.sessions(home: home, now: now)
                lock.lock(); all += list; lock.unlock()
            } catch {
                lock.lock(); issues[s.info.id] = "\(error)"; lock.unlock()
            }
        }
        all.sort { (SessionState.rank[$0.state] ?? 9, -$0.updatedAt) < (SessionState.rank[$1.state] ?? 9, -$1.updatedAt) }
        let error = issues.count == sources.count ? issues.values.sorted().first : nil
        return LiveSnapshot(
            running: all.filter { $0.state == "running" }.count,
            waiting: all.filter { $0.state == "waiting" }.count,
            stalled: all.filter { $0.state == "stalled" }.count,
            sessions: Array(all.prefix(limit)),
            agents: sources.map(\.info.id),
            issues: issues,
            error: error)
    }
}
