// OpenCode: <XDG_DATA_HOME or ~/.local/share>/opencode/opencode*.db (SQLite)
//   current schema  session_v2(time_updated, time_idle, idle_outcome succeeded|failed|interrupted, time_archived, parent_id, title, directory)
//                   activity after the last idle mark = running; otherwise the idle outcome
//   legacy schema   session + message(data.time.completed / data.error) + part(tool "question" running = waiting)
import Foundation
import SwiftUI

struct OpenCodeSource: AgentSource {
    let info = AgentInfo(id: "opencode", name: "OpenCode", short: "OpenCode",
                         color: Color(red: 0.95, green: 0.6, blue: 0.2),
                         bundleIDs: ["ai.opencode"], appNames: ["OpenCode"], cli: true, monogram: "OC",
                         iconURLs: ["https://raw.githubusercontent.com/sst/opencode/dev/packages/app/public/apple-touch-icon-v3.png",
                                    "https://github.com/sst.png?size=256"])

    func dataDir(_ home: String) -> String {
        if home == NSHomeDirectory(), let x = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !x.isEmpty { return x + "/opencode" }
        return home + "/.local/share/opencode"
    }

    func dataPaths(home: String) -> [String] {
        let d = dataDir(home)
        return Files.list(d).filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.map { d + "/" + $0 }
            .sorted { max(Files.mtimeMs($0), Files.mtimeMs($0 + "-wal")) > max(Files.mtimeMs($1), Files.mtimeMs($1 + "-wal")) }
    }

    func hasTable(_ db: String, _ t: String) -> Bool {
        ((try? SQLite.query(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [t])) ?? []).count > 0
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        guard let db = dataPaths(home: home).first else { return [] }
        let since = now - Timing.stallMs
        var out: [LiveSession] = []
        if hasTable(db, "session_v2") {
            let rows = try SQLite.query(db, """
            SELECT id, title, directory, time_updated, time_idle, idle_outcome FROM session_v2
            WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= ?1 ORDER BY time_updated DESC LIMIT 40
            """, [since])
            for r in rows {
                let updated = Int64(r[3] ?? "") ?? 0
                let idle = Int64(r[4] ?? "")
                var state: String
                if idle == nil || updated > idle! {
                    state = SessionState.running(updated, now: now, idleMs: Timing.cliIdleMs)
                } else {
                    switch r[5] {
                    case "failed": state = "failed"
                    case "interrupted": state = "stopped"
                    default: state = "done"
                    }
                }
                let at = max(updated, idle ?? 0)
                guard SessionState.visible(state, updated: at, now: now) else { continue }
                out.append(LiveSession(agent: info.id, sid: r[0] ?? "", title: r[1], state: state, updatedAt: at,
                                       question: nil, ws: r[2], host: AppLocator.running(info).isEmpty ? "terminal" : "app"))
            }
            return out
        }
        // legacy schema
        let rows = try SQLite.query(db, """
        SELECT s.id, s.title, s.directory, s.time_updated,
          (SELECT m.data FROM message m WHERE m.session_id = s.id ORDER BY m.time_created DESC LIMIT 1),
          (SELECT json_extract(p.data, '$.state.input') FROM part p WHERE p.session_id = s.id AND json_extract(p.data, '$.type') = 'tool'
             AND json_extract(p.data, '$.tool') = 'question' AND json_extract(p.data, '$.state.status') IN ('running', 'pending') LIMIT 1)
        FROM session s WHERE s.parent_id IS NULL AND s.time_updated >= ?1 ORDER BY s.time_updated DESC LIMIT 40
        """, [since])
        for r in rows {
            let updated = Int64(r[3] ?? "") ?? 0
            let msg = r[4].flatMap(Files.json)
            var state: String
            var question: String?
            if let q = r[5] {
                state = "waiting"
                question = findString(Files.json(q), keys: ["question", "header"]).map { Clean.text($0, 80) } ?? "有个问题需要你确认"
            } else if msg?["role"] as? String == "user" {
                state = "running"
            } else if (msg?["time"] as? [String: Any])?["completed"] == nil {
                state = "running"
            } else if msg?["error"] != nil {
                state = ((msg?["error"] as? [String: Any])?["name"] as? String)?.contains("Abort") == true ? "stopped" : "failed"
            } else {
                state = "done"
            }
            if state == "running" { state = SessionState.running(updated, now: now, idleMs: Timing.cliIdleMs) }
            guard SessionState.visible(state, updated: updated, now: now) else { continue }
            out.append(LiveSession(agent: info.id, sid: r[0] ?? "", title: r[1], state: state, updatedAt: updated,
                                   question: question, ws: r[2], host: "terminal"))
        }
        return out
    }
}
