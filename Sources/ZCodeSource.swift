// ZCode desktop: ~/.zcode
//   v2/tasks-index.sqlite   tasks(task_id, title, task_status running|completed|error, workspace_path, updated_at, ...)
//   cli/db/db.sqlite        message parts; a running AskUserQuestion / ExitPlanMode tool part = waiting for the user
import AppKit
import Foundation
import SwiftUI

struct ZCodeSource: AgentSource {
    let info = AgentInfo(id: "zcode", name: "ZCode", short: "ZCode",
                         color: Color(red: 0.62, green: 0.49, blue: 1.0),
                         bundleIDs: ["dev.zcode.app"], appNames: ["ZCode.app"], cli: false, monogram: "Z",
                         iconURLs: ["https://github.com/zai-org.png?size=256"])

    func tasksDB(_ home: String) -> String { home + "/.zcode/v2/tasks-index.sqlite" }
    func partsDB(_ home: String) -> String { home + "/.zcode/cli/db/db.sqlite" }

    func dataPaths(home: String) -> [String] { Files.exists(tasksDB(home)) ? [tasksDB(home)] : [] }

    /// A "running" task left behind by a crashed / quit app is not really running.
    var appRunning: Bool {
        if let o = ProcessInfo.processInfo.environment["AGENT_ISLAND_ZCODE_RUNNING"] { return o == "1" }
        return !AppLocator.running(info).isEmpty
    }

    static let sql = """
    SELECT task_id, title, task_status, workspace_path, updated_at, json_extract(meta_json, '$.lastError')
    FROM tasks
    WHERE deleted = 0 AND archived = 0 AND cron_automation_id IS NULL AND task_id NOT LIKE 'sess_subagent%'
      AND task_status IS NOT NULL AND (task_status = 'running' OR updated_at >= ?1)
    ORDER BY updated_at DESC LIMIT 40
    """

    /// session id → question text, for sessions blocked on a question / plan approval tool
    func pendingQuestions(_ home: String, ids: [String], now: Int64) -> [String: String] {
        guard !ids.isEmpty, Files.exists(partsDB(home)) else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT session_id, json_extract(data, '$.tool'), json_extract(data, '$.state.input') FROM part
        WHERE session_id IN (\(marks)) AND json_extract(data, '$.type') = 'tool'
          AND json_extract(data, '$.tool') IN ('AskUserQuestion', 'ExitPlanMode', 'Question', 'ask_user')
          AND json_extract(data, '$.state.status') IN ('running', 'pending') AND time_updated >= ?
        ORDER BY time_updated DESC
        """
        guard let rows = try? SQLite.query(partsDB(home), sql, ids + [now - Timing.askMs]) else { return [:] }
        var out: [String: String] = [:]
        for r in rows {
            guard let sid = r[0], out[sid] == nil else { continue }
            if r[1] == "ExitPlanMode" { out[sid] = "计划写好了，等你确认"; continue }
            let input = r[2].flatMap(Files.json)
            out[sid] = findString(input, keys: ["question", "header"]).map { Clean.text($0, 80) } ?? "有个问题需要你确认"
        }
        return out
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        let db = tasksDB(home)
        guard Files.exists(db) else { return [] }
        let rows = try SQLite.query(db, Self.sql, [now - Timing.recentMs])
        let alive = appRunning
        let runningIDs = rows.filter { $0[2] == "running" }.compactMap { $0[0] }
        let asks = alive ? pendingQuestions(home, ids: runningIDs, now: now) : [:]
        var out: [LiveSession] = []
        for r in rows {
            let sid = r[0] ?? ""
            let updated = Int64(r[4] ?? "") ?? 0
            let state: String
            switch r[2] {
            case "running":
                if let _ = asks[sid] { state = "waiting" }
                // ZCode leaves "running" behind when a task dies with the app; half a day of silence = gone
                else if alive && now - updated <= Timing.abandonMs { state = SessionState.running(updated, now: now) }
                else { state = "stopped" }
            case "error": state = "failed"
            case "completed": state = "done"
            default: state = "stopped"
            }
            guard SessionState.visible(state, updated: updated, now: now) else { continue }
            out.append(LiveSession(agent: info.id, sid: sid, title: r[1], state: state, updatedAt: updated,
                                   question: asks[sid], ws: r[3]))
        }
        return out
    }
}
