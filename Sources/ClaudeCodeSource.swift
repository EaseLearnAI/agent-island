// Claude Code (CLI / IDE / desktop): ~/.claude/projects/<project-slug>/<session-id>.jsonl
// One JSON object per line: type user | assistant | summary | system ...; assistant content blocks carry tool_use,
// user entries carry tool_result. State is inferred from the transcript tail + file activity:
//   unanswered AskUserQuestion / ExitPlanMode → waiting · pending tool_use or fresh user turn → running
//   final assistant text → done · "[Request interrupted by user" → stopped · API error message → failed
// Limitation: permission prompts are not written to the transcript, so they show as "running".
import Foundation
import SwiftUI

struct ClaudeCodeSource: AgentSource {
    let info = AgentInfo(id: "claude", name: "Claude Code", short: "Claude",
                         color: Color(red: 0.85, green: 0.47, blue: 0.34),
                         bundleIDs: ["com.anthropic.claudefordesktop"], appNames: ["Claude"], cli: true)

    func root(_ home: String) -> String {
        if home == NSHomeDirectory(), let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { return d }
        return home + "/.claude"
    }

    func dataPaths(home: String) -> [String] {
        let p = root(home) + "/projects"
        return Files.isDir(p) ? [p] : []
    }

    static let askTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    func blocks(_ msg: [String: Any]?) -> [[String: Any]] {
        if let a = msg?["content"] as? [[String: Any]] { return a }
        if let s = msg?["content"] as? String { return [["type": "text", "text": s]] }
        return []
    }

    func userText(_ e: [String: Any]) -> String? {
        for b in blocks(e["message"] as? [String: Any]) where b["type"] as? String == "text" {
            if let t = b["text"] as? String { return t }
        }
        return nil
    }

    /// First real prompt (skips slash-command wrappers, caveats and meta entries) or a stored summary / custom title.
    func title(_ head: [[String: Any]], _ tail: [[String: Any]]) -> String? {
        for e in tail.reversed() {
            if let t = e["customTitle"] as? String, !t.isEmpty { return t }
        }
        for e in head + tail {
            if e["type"] as? String == "summary", let s = e["summary"] as? String, !s.isEmpty { return s }
        }
        for e in head where e["type"] as? String == "user" && (e["isMeta"] as? Bool) != true && (e["isSidechain"] as? Bool) != true {
            guard let t = userText(e) else { continue }
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.hasPrefix("<") || s.hasPrefix("Caveat:") || s.hasPrefix("[Request interrupted") { continue }
            return s
        }
        return nil
    }

    struct Inferred { var state: String; var question: String? }

    func infer(_ entries: [[String: Any]], idleMs: Int64) -> Inferred? {
        let turns = entries.filter { e in
            let t = e["type"] as? String
            return (t == "user" || t == "assistant") && (e["isSidechain"] as? Bool) != true && (e["isMeta"] as? Bool) != true
        }
        guard let last = turns.last else { return nil }
        // tool_use ids that already have a result
        var answered = Set<String>()
        for e in turns where e["type"] as? String == "user" {
            for b in blocks(e["message"] as? [String: Any]) where b["type"] as? String == "tool_result" {
                if let id = b["tool_use_id"] as? String { answered.insert(id) }
            }
        }
        if last["type"] as? String == "user" {
            let text = userText(last) ?? ""
            if text.hasPrefix("[Request interrupted by user") { return Inferred(state: "stopped") }
            return Inferred(state: "running")
        }
        // assistant
        if (last["isApiErrorMessage"] as? Bool) == true || last["error"] != nil { return Inferred(state: "failed") }
        let msg = last["message"] as? [String: Any]
        // pending tool uses across the trailing assistant entries (one entry per content block)
        var pending: [[String: Any]] = []
        for e in turns.reversed() {
            guard e["type"] as? String == "assistant" else { break }
            for b in blocks(e["message"] as? [String: Any]) where b["type"] as? String == "tool_use" {
                if let id = b["id"] as? String, !answered.contains(id) { pending.append(b) }
            }
        }
        if let ask = pending.first(where: { Self.askTools.contains(($0["name"] as? String) ?? "") }) {
            if ask["name"] as? String == "ExitPlanMode" { return Inferred(state: "waiting", question: "计划写好了，等你确认") }
            let q = findString(ask["input"], keys: ["question", "header"]).map { Clean.text($0, 80) }
            return Inferred(state: "waiting", question: q ?? "有个问题需要你确认")
        }
        if !pending.isEmpty { return Inferred(state: "running") }
        let stop = msg?["stop_reason"] as? String
        if stop == "end_turn" || stop == "stop_sequence" || stop == "max_tokens" { return Inferred(state: "done") }
        // streaming entries have stop_reason null: treat as done once the file is quiet for a bit
        return Inferred(state: idleMs > 20_000 ? "done" : "running")
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        guard let projects = dataPaths(home: home).first else { return [] }
        var out: [LiveSession] = []
        for dir in Files.list(projects) {
            let d = projects + "/" + dir
            guard Files.isDir(d) else { continue }
            for f in Files.list(d) where f.hasSuffix(".jsonl") {
                let path = d + "/" + f
                let mtime = Files.mtimeMs(path)
                guard now - mtime <= Timing.stallMs else { continue }
                let tail = Files.tailLines(path).compactMap(Files.json)
                guard var inf = infer(tail, idleMs: now - mtime) else { continue }
                if inf.state == "running" { inf.state = SessionState.running(mtime, now: now, idleMs: Timing.cliIdleMs) }
                guard SessionState.visible(inf.state, updated: mtime, now: now) else { continue }
                let head = Files.headLines(path).compactMap(Files.json)
                let cwd = (tail.last { $0["cwd"] is String }?["cwd"] as? String) ?? (head.first { $0["cwd"] is String }?["cwd"] as? String)
                let entry = (tail.last { $0["entrypoint"] is String }?["entrypoint"] as? String) ?? ""
                let host = entry.contains("desktop") ? "app" : (entry.contains("vscode") || entry.contains("ide")) ? "editor" : "terminal"
                out.append(LiveSession(agent: info.id, sid: String(f.dropLast(6)), title: title(head, tail), state: inf.state,
                                       updatedAt: mtime, question: inf.question, ws: cwd, host: host))
            }
        }
        return out
    }
}
