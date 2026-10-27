// Kimi Code desktop: ~/.kimi-code
//   sessions/<workspace>/<session>/state.json   title, cwd, updatedAt, lastTurnReason, archived
//   server/events/<session>.jsonl                event journal; "event.session.work_changed" carries
//                                                busy / pending_interaction (none|approval|question) / last_turn_reason
//   server/instances/*.json                      local server pid + heartbeat (is the app alive?)
import Foundation
import SwiftUI

struct KimiSource: AgentSource {
    let info = AgentInfo(id: "kimi", name: "Kimi Code", short: "Kimi",
                         color: Color(red: 0.36, green: 0.55, blue: 1.0),
                         bundleIDs: ["com.kimi.code.desktop"], appNames: ["Kimi Code"], cli: false, monogram: "K",
                         iconURLs: ["https://github.com/MoonshotAI.png?size=256"])

    func root(_ home: String) -> String { home + "/.kimi-code" }

    func dataPaths(home: String) -> [String] {
        let r = root(home)
        return Files.isDir(r + "/sessions") ? [r] : []
    }

    /// The desktop app runs a local server; a session can only be busy while that server is alive.
    func serverAlive(_ r: String, now: Int64) -> Bool {
        let dir = r + "/server/instances"
        for f in Files.list(dir) where f.hasSuffix(".json") {
            guard let o = Files.jsonFile(dir + "/" + f) else { continue }
            let pid = Int32(num(o["pid"]) ?? 0)
            let beat = num(o["heartbeat_at"]) ?? 0
            if processAlive(pid) && now - beat < 5 * 60 * 1000 { return true }
        }
        return false
    }

    struct Activity {
        var busy = false
        var pending = "none"
        var reason: String?
        var question: String?
        var found = false
    }

    /// Walks the journal tail backwards to the latest work_changed event; also picks up the pending question text.
    func activity(_ path: String) -> Activity {
        var a = Activity()
        let lines = Files.tailLines(path, maxBytes: 512 * 1024)
        var askPayload: [String: Any]?
        for line in lines.reversed() {
            guard line.contains("\"envelope\""), let o = Files.json(line), let env = o["envelope"] as? [String: Any],
                  let type = env["type"] as? String else { continue }
            let p = env["payload"] as? [String: Any] ?? [:]
            // the request can be written just before OR just after the state change; remember the newest one
            let isRequest = type.hasSuffix(".requested") && (type.contains("approval") || type.contains("question"))
            if isRequest && (askPayload == nil || type.hasPrefix("permission.")) { askPayload = p }
            if !a.found {
                guard type == "event.session.work_changed" else { continue }
                a.found = true
                a.busy = (p["busy"] as? Bool) ?? false
                a.pending = (p["pending_interaction"] as? String) ?? "none"
                a.reason = p["last_turn_reason"] as? String
                if a.pending == "none" { break }
                continue
            }
            if isRequest && askPayload != nil { break }
            if type == "turn.started" { break }
        }
        if a.pending != "none" {
            if a.pending == "question" {
                a.question = findString(askPayload, keys: ["question", "title", "prompt", "message"]).map { Clean.text($0, 80) } ?? "有个问题需要你确认"
            } else {
                let tool = findString(askPayload, keys: ["action", "toolName", "tool_name", "tool", "title"])
                a.question = tool.map { "等你批准：\(Clean.text($0, 60))" } ?? "有个操作等你批准"
            }
        }
        return a
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        let r = root(home)
        let alive = serverAlive(r, now: now)
        var out: [LiveSession] = []
        for ws in Files.list(r + "/sessions") {
            let wsDir = r + "/sessions/" + ws
            guard Files.isDir(wsDir) else { continue }
            for sid in Files.list(wsDir) where sid.hasPrefix("session_") {
                guard let st = Files.jsonFile(wsDir + "/" + sid + "/state.json") else { continue }
                if (st["archived"] as? Bool) == true { continue }
                let events = r + "/server/events/" + sid + ".jsonl"
                let updated = max(num(st["updatedAt"]) ?? 0, Files.mtimeMs(events))
                // old sessions can't be busy unless the server is alive and still writing
                if now - updated > Timing.stallMs && !alive { continue }
                if now - updated > 7 * 24 * Timing.hour { continue }
                var a = Files.exists(events) ? activity(events) : Activity()
                if !a.found { a.reason = st["lastTurnReason"] as? String }
                let state: String
                if alive && a.pending != "none" && now - updated <= Timing.askMs { state = "waiting" }
                else if a.busy { state = alive && now - updated <= Timing.abandonMs ? SessionState.running(updated, now: now) : "stopped" }
                else {
                    switch a.reason {
                    case "failed": state = "failed"
                    case "cancelled": state = "stopped"
                    default: state = "done"
                    }
                }
                guard SessionState.visible(state, updated: updated, now: now) else { continue }
                var title = st["title"] as? String
                if (title ?? "").trimmingCharacters(in: .whitespaces).isEmpty { title = st["lastPrompt"] as? String }
                out.append(LiveSession(agent: info.id, sid: sid, title: title, state: state, updatedAt: updated,
                                       question: state == "waiting" ? a.question : nil, ws: st["cwd"] as? String))
            }
        }
        return out
    }
}
