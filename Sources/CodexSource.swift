// OpenAI Codex (CLI / IDE / desktop): ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
// Lines: {"timestamp","type": session_meta | turn_context | response_item | event_msg, "payload": {...}}.
// event_msg payload types used here: task_started / user_message → running, task_complete → done,
// turn_aborted → stopped, error → failed, *approval_request / request_user_input → waiting.
// Older rollouts without task events fall back to response_item function_call / function_call_output pairing.
import Foundation
import SwiftUI

struct CodexSource: AgentSource {
    let info = AgentInfo(id: "codex", name: "Codex", short: "Codex",
                         color: Color(red: 0.06, green: 0.64, blue: 0.5),
                         bundleIDs: ["com.openai.codex"], appNames: ["Codex"], cli: true)

    func root(_ home: String) -> String {
        if home == NSHomeDirectory(), let d = ProcessInfo.processInfo.environment["CODEX_HOME"], !d.isEmpty { return d }
        return home + "/.codex"
    }

    func dataPaths(home: String) -> [String] {
        let p = root(home) + "/sessions"
        return Files.isDir(p) ? [p] : []
    }

    /// Day folders that can contain sessions touched recently (today + yesterday, local time).
    func recentDayDirs(_ sessions: String, now: Int64) -> [String] {
        var out: [String] = []
        let cal = Calendar.current
        for back in 0...1 {
            let d = Date(timeIntervalSince1970: Double(now) / 1000).addingTimeInterval(Double(-back) * 86400)
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let p = String(format: "%@/%04d/%02d/%02d", sessions, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            if Files.isDir(p) { out.append(p) }
        }
        return out
    }

    func threadNames(_ root: String) -> [String: String] {
        var m: [String: String] = [:]
        for l in Files.tailLines(root + "/session_index.jsonl", maxBytes: 512 * 1024) {
            guard let o = Files.json(l), let id = o["id"] as? String, let n = o["thread_name"] as? String, !n.isEmpty else { continue }
            m[id] = n
        }
        return m
    }

    static func isContext(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("<environment_context") || t.hasPrefix("<user_instructions") || t.hasPrefix("# AGENTS.md")
            || t.hasPrefix("<permissions") || t.hasPrefix("<INSTRUCTIONS")
    }

    struct Inferred { var state: String?; var question: String? }

    func infer(_ lines: [[String: Any]], idleMs: Int64) -> Inferred {
        var state: String?
        var waiting: String?
        var pendingCalls = Set<String>()
        var lastItem = ""
        for o in lines {
            let type = o["type"] as? String
            let p = o["payload"] as? [String: Any] ?? [:]
            let pt = p["type"] as? String ?? ""
            if type == "event_msg" {
                switch pt {
                case "task_started", "user_message": state = "running"; waiting = nil
                case "task_complete": state = "done"; waiting = nil; pendingCalls.removeAll()
                case "turn_aborted": state = "stopped"; waiting = nil; pendingCalls.removeAll()
                case "error": state = "failed"; waiting = nil
                case "exec_command_begin", "patch_apply_begin", "agent_message": waiting = nil
                default:
                    if pt.hasSuffix("approval_request") {
                        let cmd = findString(p, keys: ["command", "reason"]).map { Clean.text($0, 60) }
                        waiting = cmd.map { "等你批准：\($0)" } ?? "有个操作等你批准"
                    } else if pt == "request_user_input" || pt.contains("elicitation") {
                        waiting = findString(p, keys: ["question", "message", "prompt"]).map { Clean.text($0, 80) } ?? "有个问题需要你确认"
                    }
                }
            } else if type == "response_item" {
                if pt == "function_call" || pt == "custom_tool_call" || pt == "local_shell_call" {
                    if let id = p["call_id"] as? String { pendingCalls.insert(id) }
                    lastItem = "call"
                } else if pt == "function_call_output" || pt == "custom_tool_call_output" {
                    if let id = p["call_id"] as? String { pendingCalls.remove(id) }
                    lastItem = "output"
                } else if pt == "message" {
                    lastItem = (p["role"] as? String) == "assistant" ? "assistant" : "user"
                }
            }
        }
        if let w = waiting { return Inferred(state: "waiting", question: w) }
        if let s = state { return Inferred(state: s) }
        // no task events: guess from the last response item
        if !pendingCalls.isEmpty || lastItem == "output" || lastItem == "user" { return Inferred(state: "running") }
        if lastItem == "assistant" { return Inferred(state: idleMs > 20_000 ? "done" : "running") }
        return Inferred(state: nil)
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        guard let sessionsDir = dataPaths(home: home).first else { return [] }
        let names = threadNames(root(home))
        var out: [LiveSession] = []
        for day in recentDayDirs(sessionsDir, now: now) {
            for f in Files.list(day) where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                let path = day + "/" + f
                let mtime = Files.mtimeMs(path)
                guard now - mtime <= Timing.stallMs else { continue }
                let head = Files.headLines(path).compactMap(Files.json)
                let meta = head.first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any]
                // sub-agent threads belong to their parent session
                if let src = meta?["source"], !(src is String) { continue }
                let tail = Files.tailLines(path).compactMap(Files.json)
                var inf = infer(tail, idleMs: now - mtime)
                guard var state = inf.state else { continue }
                if state == "running" { state = SessionState.running(mtime, now: now, idleMs: Timing.cliIdleMs) }
                inf.state = state
                guard SessionState.visible(state, updated: mtime, now: now) else { continue }
                let sid = (meta?["id"] as? String) ?? String(f.dropLast(6))
                var title = names[sid]
                if title == nil {
                    for o in head + tail where o["type"] as? String == "event_msg" {
                        let p = o["payload"] as? [String: Any]
                        if p?["type"] as? String == "user_message", let m = p?["message"] as? String, !Self.isContext(m) { title = m; break }
                    }
                }
                let cwd = (tail.last { ($0["payload"] as? [String: Any])?["cwd"] is String }?["payload"] as? [String: Any])?["cwd"] as? String
                    ?? meta?["cwd"] as? String
                let origin = ((meta?["originator"] as? String) ?? "").lowercased()
                let host = origin.contains("vscode") ? "editor" : (origin.contains("desktop") || origin.contains("app")) ? "app" : "terminal"
                out.append(LiveSession(agent: info.id, sid: sid, title: title, state: state, updatedAt: mtime,
                                       question: inf.question, ws: cwd, host: host))
            }
        }
        return out
    }
}
