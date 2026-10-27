// Qwen Code: <QWEN_RUNTIME_DIR or ~/.qwen>/projects/<sanitized cwd>/chats/<session id>.jsonl
// Records: {uuid, parentUuid, sessionId, timestamp, type: user|assistant|tool_result|system, subtype?, cwd, message?,
//           toolCallResult?, systemPayload?}. message is a Gemini Content: {role, parts:[{text}|{functionCall:{id,name,args}}]}.
// system/turn_result {state: completed|cancelled|error} closes a turn; system/custom_title sets the title.
// Open functionCall "ask_user_question" with no tool_result yet → waiting.
import Foundation
import SwiftUI

struct QwenCodeSource: AgentSource {
    let info = AgentInfo(id: "qwen", name: "Qwen Code", short: "Qwen",
                         color: Color(red: 0.42, green: 0.36, blue: 0.95),
                         bundleIDs: [], appNames: [], cli: true, monogram: "Q",
                         iconURLs: ["https://github.com/QwenLM.png?size=256"])

    func root(_ home: String) -> String {
        if home == NSHomeDirectory(), let d = ProcessInfo.processInfo.environment["QWEN_RUNTIME_DIR"], !d.isEmpty { return d }
        return home + "/.qwen"
    }

    func dataPaths(home: String) -> [String] {
        let p = root(home) + "/projects"
        return Files.isDir(p) ? [p] : []
    }

    func parts(_ r: [String: Any]) -> [[String: Any]] { (r["message"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] }

    func infer(_ recs: [[String: Any]], idleMs: Int64) -> (String, String?)? {
        var state: String?
        var open: [String: (String, Any?)] = [:]
        for r in recs {
            let type = r["type"] as? String ?? ""
            let sub = r["subtype"] as? String
            switch type {
            case "user":
                if sub == nil || sub == "mid_turn_user_message" { state = "running" }
            case "assistant":
                state = state ?? "running"
                for p in parts(r) {
                    if let fc = p["functionCall"] as? [String: Any], let id = fc["id"] as? String {
                        open[id] = ((fc["name"] as? String) ?? "", fc["args"])
                    }
                }
            case "tool_result":
                if let id = (r["toolCallResult"] as? [String: Any])?["callId"] as? String { open[id] = nil }
                for p in parts(r) { if let id = (p["functionResponse"] as? [String: Any])?["id"] as? String { open[id] = nil } }
            case "system" where sub == "turn_result":
                open.removeAll()
                switch (r["systemPayload"] as? [String: Any])?["state"] as? String {
                case "error": state = "failed"
                case "cancelled": state = "stopped"
                default: state = "done"
                }
            default: break
            }
        }
        guard let s = state else { return nil }
        if s == "running", let ask = open.values.first(where: { $0.0 == "ask_user_question" }) {
            return ("waiting", findString(ask.1, keys: ["question", "header"]).map { Clean.text($0, 80) } ?? "有个问题需要你确认")
        }
        return (s, nil)
    }

    func title(_ recs: [[String: Any]]) -> String? {
        for r in recs.reversed() where r["subtype"] as? String == "custom_title" {
            if let t = findString(r["systemPayload"], keys: ["customTitle", "title"]) { return t }
        }
        for r in recs where r["type"] as? String == "user" && r["subtype"] == nil {
            if let t = parts(r).compactMap({ $0["text"] as? String }).first, !t.hasPrefix("<") { return t }
        }
        return nil
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        guard let projects = dataPaths(home: home).first else { return [] }
        var out: [LiveSession] = []
        for proj in Files.list(projects) {
            let chats = projects + "/" + proj + "/chats"
            guard Files.isDir(chats) else { continue }
            for f in Files.list(chats) where f.hasSuffix(".jsonl") {
                let path = chats + "/" + f
                let mtime = Files.mtimeMs(path)
                guard now - mtime <= Timing.stallMs else { continue }
                let head = Files.headLines(path).compactMap(Files.json)
                let tail = Files.tailLines(path, maxBytes: 512 * 1024).compactMap(Files.json)
                guard var (state, question) = infer(tail, idleMs: now - mtime) else { continue }
                if state == "running" { state = SessionState.running(mtime, now: now, idleMs: Timing.cliIdleMs) }
                guard SessionState.visible(state, updated: mtime, now: now) else { continue }
                let cwd = (tail.last { $0["cwd"] is String }?["cwd"] as? String) ?? (head.first { $0["cwd"] is String }?["cwd"] as? String)
                out.append(LiveSession(agent: info.id, sid: String(f.dropLast(6)), title: title(tail) ?? title(head), state: state,
                                       updatedAt: mtime, question: question, ws: cwd, projectFallback: proj, host: "terminal"))
            }
        }
        return out
    }
}
