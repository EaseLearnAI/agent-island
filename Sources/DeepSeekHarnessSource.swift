// DeepSeek Harness (dsh — CLI / Web UI / desktop): <DSH_HOME or ~/.dsh>/sessions/<project>/<session>/session.vN.jsonl[.zstd]
// First line: {"type":"session","version":N,"id","createdAt","cwd","delegationDepth"}; then events
//   turn/start → running · turn/end {reason:{kind: completed|max-tokens|error|aborted|blocked}}
//   approval/asked {id, toolName, reason} until approval/decided {id} → waiting
//   tool/call {name:"ask_user_question", callId} until tool/result {callId} → waiting
//   session/title {title} · working-directory/change {cwd}
// Logs are zstd-compressed by default, one zstd frame per append. macOS has no system zstd, so the tail frames are
// decoded with the zstd CLI if present, else with Node ≥ 22.15 (zlib.zstdDecompressSync, which dsh users have).
import Foundation
import SwiftUI

struct DeepSeekHarnessSource: AgentSource {
    let info = AgentInfo(id: "dsh", name: "DeepSeek Harness", short: "DSH",
                         color: Color(red: 0.3, green: 0.42, blue: 1.0),
                         bundleIDs: ["com.deepseek.dsh", "com.deepseek.harness"], appNames: ["DeepSeek Harness"], cli: true, monogram: "DS",
                         iconURLs: ["https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/apps/desktop/resources/icon.png",
                                    "https://github.com/deepseek-ai.png?size=256"])

    func root(_ home: String) -> String {
        if home == NSHomeDirectory(), let d = ProcessInfo.processInfo.environment["DSH_HOME"], !d.isEmpty { return d }
        return home + "/.dsh"
    }

    func dataPaths(home: String) -> [String] {
        let p = root(home) + "/sessions"
        return Files.isDir(p) ? [p] : []
    }

    /// Newest generation log in one session directory (session.jsonl, session.v4.jsonl, *.zstd …)
    func logFile(_ dir: String) -> String? {
        var best: (Int, String)?
        for f in Files.list(dir) where f.hasPrefix("session") && (f.hasSuffix(".jsonl") || f.hasSuffix(".jsonl.zstd")) {
            let base = f.replacingOccurrences(of: ".zstd", with: "").replacingOccurrences(of: ".jsonl", with: "")
            let v = base == "session" ? 0 : Int(base.dropFirst("session.v".count)) ?? -1
            if v >= 0, best == nil || v > best!.0 { best = (v, dir + "/" + f) }
        }
        return best?.1
    }

    struct Parsed: Equatable {
        var state: String?
        var question: String?
        var title: String?
        var cwd: String?
        var depth = 0
    }

    func parse(_ lines: [String]) -> Parsed {
        var p = Parsed()
        var approvals: [String: String] = [:]
        var asks: [String: String] = [:]
        for l in lines {
            guard let o = Files.json(l), let type = o["type"] as? String else { continue }
            let d = o["data"] as? [String: Any] ?? [:]
            switch type {
            case "session":
                p.cwd = o["cwd"] as? String ?? p.cwd
                p.depth = Int(num(o["delegationDepth"]) ?? 0)
            case "working-directory/change": p.cwd = d["cwd"] as? String ?? p.cwd
            case "session/title": p.title = d["title"] as? String ?? p.title
            case "turn/start": p.state = "running"
            case "turn/end":
                approvals.removeAll(); asks.removeAll()
                let kind = (d["reason"] as? [String: Any])?["kind"] as? String
                switch kind {
                case "error": p.state = "failed"
                case "aborted", "blocked": p.state = "stopped"
                default: p.state = "done"
                }
            case "approval/asked":
                if let id = d["id"] as? String {
                    let what = (d["reason"] as? String) ?? (d["toolName"] as? String) ?? ""
                    approvals[id] = what.isEmpty ? "有个操作等你批准" : "等你批准：\(Clean.text(what, 60))"
                }
            case "approval/decided": if let id = d["id"] as? String { approvals[id] = nil }
            case "tool/call":
                if d["name"] as? String == "ask_user_question", let id = d["callId"] as? String {
                    let args = (d["arguments"] as? String).flatMap(Files.json) ?? d["arguments"]
                    asks[id] = findString(args, keys: ["question", "header"]).map { Clean.text($0, 80) } ?? "有个问题需要你确认"
                }
            case "tool/result":
                if let id = d["callId"] as? String ?? d["toolCallId"] as? String { asks[id] = nil }
            default: break
            }
        }
        if p.state == "running", let q = asks.values.first ?? approvals.values.first {
            p.state = "waiting"; p.question = q
        }
        return p
    }

    // MARK: reading (plain or zstd), cached by file size

    private static var cache: [String: (size: Int64, head: Parsed, tail: Parsed)] = [:]
    private static let lock = NSLock()

    func read(_ path: String) -> (head: Parsed, tail: Parsed)? {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        Self.lock.lock()
        if let c = Self.cache[path], c.size == size { Self.lock.unlock(); return (c.head, c.tail) }
        Self.lock.unlock()
        let head: [String], tail: [String]
        if path.hasSuffix(".zstd") {
            guard let h = Zstd.decodeHead(path), let t = Zstd.decodeTail(path) else { return nil }
            head = h; tail = t
        } else {
            head = Files.headLines(path); tail = Files.tailLines(path, maxBytes: 512 * 1024)
        }
        let r = (head: parse(Array(head.prefix(200))), tail: parse(tail))
        Self.lock.lock(); Self.cache[path] = (size, r.head, r.tail); Self.lock.unlock()
        return r
    }

    func sessions(home: String, now: Int64) throws -> [LiveSession] {
        guard let root = dataPaths(home: home).first else { return [] }
        var out: [LiveSession] = []
        for proj in Files.list(root) where Files.isDir(root + "/" + proj) {
            for sid in Files.list(root + "/" + proj) {
                let dir = root + "/" + proj + "/" + sid
                guard Files.isDir(dir), let log = logFile(dir) else { continue }
                let mtime = Files.mtimeMs(log)
                guard now - mtime <= Timing.stallMs else { continue }
                var state: String, question: String?, title: String?, cwd: String?
                if let r = read(log) {
                    if r.head.depth > 0 { continue }  // delegated sub-agent sessions belong to their parent
                    state = r.tail.state ?? "running"
                    question = r.tail.question
                    title = r.tail.title ?? r.head.title
                    cwd = r.tail.cwd ?? r.head.cwd
                } else {
                    // no decoder available: activity from the file clock only
                    state = now - mtime < 30_000 ? "running" : "done"
                }
                if state == "running" || state == "waiting" {
                    if now - mtime > Timing.abandonMs { continue }
                    if state == "running" { state = SessionState.running(mtime, now: now, idleMs: Timing.cliIdleMs) }
                }
                guard SessionState.visible(state, updated: mtime, now: now) else { continue }
                out.append(LiveSession(agent: info.id, sid: sid, title: title ?? Clean.projectName(cwd), state: state,
                                       updatedAt: mtime, question: question, ws: cwd,
                                       host: AppLocator.running(info).isEmpty ? "terminal" : "app"))
            }
        }
        return out
    }
}

/// zstd frame decoding through an external decoder (zstd CLI or Node's zlib). Frames are found by their magic number.
enum Zstd {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static let decoders: [[String]] = {
        var out: [[String]] = []
        for p in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"] where FileManager.default.isExecutableFile(atPath: p) {
            out.append([p, "-dcq"])
        }
        let script = "const z=require('zlib');if(!z.zstdDecompressSync)process.exit(9);const b=require('fs').readFileSync(0);process.stdout.write(z.zstdDecompressSync(b))"
        for node in nodeCandidates() { out.append([node, "-e", script]) }
        return out
    }()

    static func nodeCandidates() -> [String] {
        var list = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let home = NSHomeDirectory()
        for base in [home + "/.nvm/versions/node", home + "/.local/share/fnm/node-versions", home + "/.volta/tools/image/node"] {
            for v in Files.list(base).reversed() {
                for p in [base + "/\(v)/bin/node", base + "/\(v)/installation/bin/node"] where Files.exists(p) { list.append(p) }
            }
        }
        return list.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var available: Bool { !decoders.isEmpty }

    static func run(_ cmd: [String], _ input: Data) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().async { inPipe.fileHandleForWriting.write(input); try? inPipe.fileHandleForWriting.close() }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out.isEmpty ? nil : out
    }

    static func decode(_ data: Data) -> String? {
        for d in decoders { if let out = run(d, data) { return String(decoding: out, as: UTF8.self) } }
        return nil
    }

    static func lines(_ s: String) -> [String] { s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    /// First frame(s): header + early events (title)
    static func decodeHead(_ path: String) -> [String]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 256 * 1024) else { return nil }
        // cut at the last frame start so the decoder only sees complete frames
        let starts = frameStarts(data)
        let end = starts.count > 1 ? starts.last! : data.count
        return decode(data.prefix(end)).map(lines)
    }

    /// Last frames of the file (each append is its own frame)
    static func decodeTail(_ path: String, window: Int = 512 * 1024) -> [String]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        // a magic number can also appear inside compressed bytes: try candidate starts until one decodes
        for s in frameStarts(data).prefix(8) {
            if let text = decode(data.suffix(from: data.startIndex + s)) { return lines(text) }
        }
        return nil
    }

    static func frameStarts(_ d: Data) -> [Int] {
        var out: [Int] = []
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            guard b.count >= 4 else { return }
            for i in 0...(b.count - 4) where b[i] == magic[0] && b[i + 1] == magic[1] && b[i + 2] == magic[2] && b[i + 3] == magic[3] {
                out.append(i)
            }
        }
        return out
    }
}
