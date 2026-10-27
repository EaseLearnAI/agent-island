// MiniMax Code desktop: reads runtime-state.sqlite (local_runtime_sessions + questionnaire_requests).
import Foundation
import SwiftUI

struct MCodeSource: AgentSource {
    let info = AgentInfo(id: "mcode", name: "MiniMax Code", short: "MCode",
                         color: Color(red: 41 / 255, green: 182 / 255, blue: 254 / 255),
                         bundleIDs: ["com.minimax.agent.cn", "com.minimax.agent"], appNames: ["MiniMax Code.app"], cli: false,
                         monogram: "M", iconURLs: ["https://github.com/MiniMax-AI.png?size=256"])

    /// ~/.minimax and other ~/.minimax-* profiles; the most recently written database wins.
    func candidates(home: String) -> [String] {
        var list = [home + "/.minimax/v2/sqlite/runtime-state.sqlite", home + "/.minimax/sqlite/runtime-state.sqlite"]
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted() where n.hasPrefix(".minimax") && n != ".minimax" {
            list.append(home + "/\(n)/v2/sqlite/runtime-state.sqlite")
        }
        return list.filter(Files.exists)
    }

    func lastActive(_ p: String) -> Int64 { max(Files.mtimeMs(p), Files.mtimeMs(p + "-wal")) }

    func dataPaths(home: String) -> [String] {
        if let e = ProcessInfo.processInfo.environment["AGENT_ISLAND_MCODE_DB"], !e.isEmpty { return [e] }
        return candidates(home: home).sorted { lastActive($0) > lastActive($1) }
    }

    static let sql = """
    SELECT s.session_id, s.title, s.status, COALESCE(s.project_workspace_dir, s.workspace_dir),
      s.is_default_workspace, s.updated_at_ms,
      (SELECT q.request_json FROM questionnaire_requests q WHERE q.session_id = s.session_id AND q.status = 'pending'
         AND q.answered_at IS NULL AND q.dismissed_at IS NULL AND q.created_at >= ?1 ORDER BY q.created_at DESC LIMIT 1)
    FROM local_runtime_sessions s
    WHERE s.visibility <> 'hidden' AND s.session_kind NOT IN ('peek','cron','channel') AND s.parent_session_id IS NULL
      AND s.archived = 0
      AND (s.status = 'started' OR s.updated_at_ms >= ?2 OR s.session_id IN (
        SELECT session_id FROM questionnaire_requests WHERE status = 'pending' AND answered_at IS NULL
          AND dismissed_at IS NULL AND created_at >= ?1))
    ORDER BY s.updated_at_ms DESC LIMIT 40
    """

    func askText(_ json: String?) -> String? {
        guard let json, let obj = Files.json(json), let steps = obj["steps"] as? [[String: Any]],
              let q = steps.first?["question"] as? String else { return nil }
        let c = Clean.text(q, 80)
        return c.isEmpty ? nil : c
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        guard let db = dataPaths(home: home).first else { return [] }
        let rows = try SQLite.query(db, Self.sql, [now - Timing.askMs, now - Timing.recentMs])
        return rows.map { r in
            let status = r[2] ?? ""
            let ws = r[3]
            let isDefault = r[4] == "1"
            let updated = Int64(r[5] ?? "") ?? 0
            let ask = r[6]
            let state: String
            // same as the desktop sidebar: only "error" is a failure; aborted / interrupted are just stopped
            if ask != nil { state = "waiting" }
            else if status == "started" { state = SessionState.running(updated, now: now) }
            else if status == "error" { state = "failed" }
            else if status == "aborted" || status == "interrupted" { state = "stopped" }
            else { state = "done" }
            let wsUsable = !isDefault && !(ws ?? "").isEmpty
            return LiveSession(
                agent: info.id, sid: r[0] ?? "", title: r[1], state: state, updatedAt: updated,
                question: ask.flatMap(askText) ?? (ask != nil ? "有个问题需要你确认" : nil),
                ws: wsUsable ? ws : nil, projectFallback: "未选项目")
        }
    }
}
