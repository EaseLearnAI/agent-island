// Gemini CLI: ~/.gemini/tmp/<project slug>/chats/session-<time>-<id>.jsonl (older versions: session-*.json)
// JSONL: metadata lines ({sessionId, startTime, lastUpdated, summary, kind}, {"$set": {...}}), message records
// {id, timestamp, type: user|gemini|info|error|warning, content, toolCalls:[{id, name, args, status}]} — a message is
// re-appended whole when its tool calls change, so the last line per id wins; {"$rewindTo": id} truncates.
// ~/.gemini/projects.json maps project paths to slugs.
// Tool status: validating / scheduled / executing → running · awaiting_approval → waiting · ask_user → waiting
import Foundation
import SwiftUI

struct GeminiCLISource: AgentSource {
    let info = AgentInfo(id: "gemini", name: "Gemini CLI", short: "Gemini",
                         color: Color(red: 0.27, green: 0.53, blue: 0.96),
                         bundleIDs: [], appNames: [], cli: true, monogram: "G",
                         iconURLs: ["https://github.com/google-gemini.png?size=256"])

    func root(_ home: String) -> String { home + "/.gemini" }

    func dataPaths(home: String) -> [String] {
        let p = root(home) + "/tmp"
        return Files.isDir(p) ? [p] : []
    }

    func slugPaths(_ home: String) -> [String: String] {
        guard let o = Files.jsonFile(root(home) + "/projects.json"), let m = o["projects"] as? [String: String] else { return [:] }
        return Dictionary(m.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
    }

    static func text(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let a = content as? [Any] {
            let parts = a.compactMap { ($0 as? [String: Any])?["text"] as? String ?? ($0 as? String) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return (content as? [String: Any])?["text"] as? String
    }

    struct Parsed { var messages: [[String: Any]] = []; var meta: [String: Any] = [:] }

    func parse(_ path: String) -> Parsed {
        var p = Parsed()
        if path.hasSuffix(".json") {
            guard let o = Files.jsonFile(path) else { return p }
            p.meta = o
            p.messages = o["messages"] as? [[String: Any]] ?? []
            return p
        }
        var order: [String] = []
        var byID: [String: [String: Any]] = [:]
        for l in Files.headLines(path, maxBytes: 4096) + Files.tailLines(path, maxBytes: 512 * 1024) {
            guard let o = Files.json(l) else { continue }
            if let set = o["$set"] as? [String: Any] { p.meta.merge(set) { _, b in b }; continue }
            if let to = o["$rewindTo"] as? String {
                if let i = order.firstIndex(of: to) { for id in order[i...] { byID[id] = nil }; order.removeSubrange(i...) }
                continue
            }
            if let patch = o["$patch"] as? [String: Any], let id = patch["id"] as? String, var m = byID[id] {
                if let c = patch["content"] { m["content"] = c }
                byID[id] = m
                continue
            }
            if let id = o["id"] as? String, o["type"] is String {
                if byID[id] == nil { order.append(id) }
                byID[id] = o
            } else if o["sessionId"] != nil {
                p.meta.merge(o) { a, _ in a }
            }
        }
        p.messages = order.compactMap { byID[$0] }
        return p
    }

    func infer(_ msgs: [[String: Any]], idleMs: Int64) -> (String, String?)? {
        let turns = msgs.filter { ["user", "gemini", "error"].contains($0["type"] as? String ?? "") }
        guard let last = turns.last else { return nil }
        switch last["type"] as? String {
        case "user": return ("running", nil)
        case "error": return ("failed", nil)
        default:
            let calls = last["toolCalls"] as? [[String: Any]] ?? []
            if let ask = calls.first(where: { ($0["name"] as? String) == "ask_user" && !["success", "error", "cancelled"].contains($0["status"] as? String ?? "") }) {
                return ("waiting", findString(ask["args"], keys: ["question", "header"]).map { Clean.text($0, 80) } ?? "有个问题需要你确认")
            }
            if let c = calls.first(where: { ($0["status"] as? String) == "awaiting_approval" }) {
                return ("waiting", "等你批准：\(Clean.text((c["displayName"] as? String) ?? (c["name"] as? String) ?? "", 60))")
            }
            if calls.contains(where: { ["validating", "scheduled", "executing"].contains($0["status"] as? String ?? "") }) { return ("running", nil) }
            if !calls.isEmpty && calls.allSatisfy({ ($0["status"] as? String) == "cancelled" }) { return ("stopped", nil) }
            if !calls.isEmpty { return (idleMs > 60_000 ? "stopped" : "running", nil) }  // results go back to the model
            return (idleMs > 20_000 ? "done" : "running", nil)
        }
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        guard let tmp = dataPaths(home: home).first else { return [] }
        let paths = slugPaths(home)
        var out: [LiveSession] = []
        for slug in Files.list(tmp) {
            let chats = tmp + "/" + slug + "/chats"
            guard Files.isDir(chats) else { continue }
            for f in Files.list(chats) where f.hasPrefix("session-") && (f.hasSuffix(".jsonl") || f.hasSuffix(".json")) {
                let path = chats + "/" + f
                let mtime = Files.mtimeMs(path)
                guard now - mtime <= Timing.stallMs else { continue }
                let p = parse(path)
                guard var (state, question) = infer(p.messages, idleMs: now - mtime) else { continue }
                if state == "running" { state = SessionState.running(mtime, now: now, idleMs: Timing.cliIdleMs) }
                guard SessionState.visible(state, updated: mtime, now: now) else { continue }
                let title = (p.meta["summary"] as? String)
                    ?? p.messages.first { ($0["type"] as? String) == "user" }.flatMap { Self.text($0["content"]) }
                let sid = (p.meta["sessionId"] as? String) ?? String(f.split(separator: ".").first ?? "")
                out.append(LiveSession(agent: info.id, sid: sid, title: title, state: state, updatedAt: mtime,
                                       question: question, ws: paths[slug], projectFallback: slug, host: "terminal"))
                _ = question
            }
        }
        return out
    }
}
