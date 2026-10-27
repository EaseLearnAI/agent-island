// Agent adapters: every supported AI coding agent is one `AgentSource`.
// A source only READS local state files of that agent and maps them to `LiveSession`s.
// Adding a new agent = one new file implementing `AgentSource` + one line in `Agents.all`.
import AppKit
import Foundation
import SQLite3
import SwiftUI

/// Static description of an agent product.
struct AgentInfo {
    let id: String            // stable id: mcode / claude / codex / kimi / zcode
    let name: String          // display name
    let short: String         // short label for chips
    let color: Color
    /// Desktop app bundle ids (prefix match). Empty = CLI-only agent.
    let bundleIDs: [String]
    /// Fallback: app file names in /Applications that start with one of these.
    let appNames: [String]
    /// The agent is (also) a terminal CLI: clicking a session may go to the terminal hosting it.
    let cli: Bool
}

struct SourceError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

protocol AgentSource {
    var info: AgentInfo { get }
    /// Local data locations that exist on this Mac. Empty = agent not installed / never used.
    func dataPaths(home: String) -> [String]
    /// Top-level sessions that are active, waiting for the user, or ended within `Timing.recentMs`.
    func sessions(home: String, now: Int64) throws -> [LiveSession]
}

/// Shared thresholds (milliseconds).
enum Timing {
    static let hour: Int64 = 3600 * 1000
    /// running but no update for 2h → "stalled"
    static let stallMs: Int64 = 2 * hour
    /// ended sessions stay visible for 30 min
    static let recentMs: Int64 = 30 * 60 * 1000
    /// only questions asked within 2h count as "waiting"
    static let askMs: Int64 = 2 * hour
    /// CLI agents: no log write for this long while "running" → "stalled" (the CLI may have been killed)
    static let cliIdleMs: Int64 = 15 * 60 * 1000
    /// "running" with no update for this long is a leftover from a crash, not a live session
    static let abandonMs: Int64 = 12 * hour

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Registry

enum Agents {
    static let all: [AgentSource] = [MCodeSource(), ClaudeCodeSource(), CodexSource(), KimiSource(), ZCodeSource()]

    static func find(_ id: String) -> AgentSource? { all.first { $0.info.id == id } }
    static func info(_ id: String) -> AgentInfo? { find(id)?.info }

    /// Home directory used to look for agent data. Tests point it at a fixture folder.
    static var home: String = {
        if let h = ProcessInfo.processInfo.environment["AGENT_ISLAND_HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }()

    /// `--agents kimi,zcode` on the command line limits which sources are read.
    static var cliFilter: Set<String>?

    static var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "disabledAgents") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "disabledAgents") }
    }

    static func isEnabled(_ id: String) -> Bool {
        if let f = cliFilter { return f.contains(id) }
        return !disabled.contains(id)
    }

    static var enabled: [AgentSource] { all.filter { isEnabled($0.info.id) } }
}

// MARK: - App lookup

enum AppLocator {
    static func matches(_ info: AgentInfo, _ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.contains("helper") else { return false }
        return info.bundleIDs.contains { id.hasPrefix($0.lowercased()) }
    }

    /// Running desktop apps of an agent (regular, visible apps only).
    static func running(_ info: AgentInfo) -> [NSRunningApplication] {
        guard !info.bundleIDs.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && matches(info, $0.bundleIdentifier) }
    }

    static func installed(_ info: AgentInfo) -> URL? {
        for id in info.bundleIDs {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        guard !info.appNames.isEmpty else { return nil }
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if let n = names.sorted().first(where: { n in n.hasSuffix(".app") && info.appNames.contains { n.hasPrefix($0) } }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(n)
            }
        }
        return nil
    }

    static func describe(_ url: URL) -> String {
        let d = Bundle(url: url)?.infoDictionary
        let name = (d?["CFBundleDisplayName"] as? String) ?? (d?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        if let v = d?["CFBundleShortVersionString"] as? String { return "\(name) \(v)" }
        return name
    }

    /// Terminals / editors that commonly host CLI agents, in preference order.
    static let terminalHosts = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
    ]
    static let editorHosts = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed"]
}

// MARK: - Read helpers

enum Clean {
    static let wrapRe = try! NSRegularExpression(pattern: "<([a-z]+(?:[-_][a-z]+)+)\\b[^>]*>[\\s\\S]*?</\\1>", options: [.caseInsensitive])

    /// Strips harness-injected `<xxx-yyy>…</xxx-yyy>` blocks, collapses whitespace, truncates.
    static func text(_ s: String?, _ max: Int) -> String {
        var t = s ?? ""
        t = wrapRe.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    static func projectName(_ path: String?) -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p).lastPathComponent
    }
}

enum Files {
    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func list(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    static func mtimeMs(_ p: String) -> Int64 {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return 0 }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    /// Last `maxBytes` of a text file split into complete lines (the partial first line is dropped).
    static func tailLines(_ p: String, maxBytes: Int = 256 * 1024) -> [String] {
        guard let h = FileHandle(forReadingAtPath: p) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        let s = String(decoding: data, as: UTF8.self)
        var lines = s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// First `maxBytes` of a text file split into complete lines.
    static func headLines(_ p: String, maxBytes: Int = 64 * 1024) -> [String] {
        guard let h = FileHandle(forReadingAtPath: p) else { return [] }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxBytes) else { return [] }
        let s = String(decoding: data, as: UTF8.self)
        var lines = s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if data.count >= maxBytes, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    static func json(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func jsonFile(_ p: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: p) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

enum ISO8601 {
    static let frac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let plain = ISO8601DateFormatter()
    static func parse(_ s: String) -> Date? { frac.date(from: s) ?? plain.date(from: s) }
}

/// Number (ms) from JSON: Int / Double / numeric string / ISO-8601 date string.
func num(_ v: Any?) -> Int64? {
    switch v {
    case let n as NSNumber: return n.int64Value
    case let s as String: return Int64(s) ?? ISO8601.parse(s).map { Int64($0.timeIntervalSince1970 * 1000) }
    default: return nil
    }
}

/// First string found under one of `keys`, searching nested dictionaries / arrays depth-first.
func findString(_ v: Any?, keys: [String], depth: Int = 0) -> String? {
    guard depth < 8 else { return nil }
    if let d = v as? [String: Any] {
        for k in keys { if let s = d[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s } }
        for (_, x) in d { if let s = findString(x, keys: keys, depth: depth + 1) { return s } }
    } else if let a = v as? [Any] {
        for x in a { if let s = findString(x, keys: keys, depth: depth + 1) { return s } }
    }
    return nil
}

func processAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

/// Minimal read-only SQLite access: opens, runs, closes. Values come back as strings.
enum SQLite {
    static func query(_ path: String, _ sql: String, _ binds: [Any] = []) throws -> [[String?]] {
        guard Files.exists(path) else { throw SourceError("数据库不存在：\(path)") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SourceError("打不开数据库：\(msg)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SourceError("查询失败（数据结构可能变了）：\(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[String?]] = []
        let n = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SourceError("读取失败：\(String(cString: sqlite3_errmsg(db)))") }
            var row: [String?] = []
            for i in 0..<n {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL { row.append(nil); continue }
                row.append(sqlite3_column_text(stmt, i).map { String(cString: $0) })
            }
            rows.append(row)
        }
        return rows
    }
}

/// Session state helpers shared by sources.
enum SessionState {
    static let rank = ["waiting": 0, "running": 1, "stalled": 2, "failed": 3, "done": 4, "stopped": 5]

    /// running → stalled when nothing changed for too long
    static func running(_ updated: Int64, now: Int64, idleMs: Int64 = Timing.stallMs) -> String {
        now - updated > idleMs ? "stalled" : "running"
    }

    static func visible(_ state: String, updated: Int64, now: Int64) -> Bool {
        ["waiting", "running", "stalled"].contains(state) || now - updated <= Timing.recentMs
    }
}
