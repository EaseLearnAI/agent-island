// Notch ownership: only one program can draw on the notch.
//  · single instance — whatever copy / version of Agent Island is launched, one process owns the notch (file lock)
//  · conflicts — other notch apps (older islands, NotchNook, boring.notch …) are detected; by default Agent Island
//    yields (menu bar only) until the user takes the notch over
//  · takeover — quits the other app; if a LaunchAgent keeps relaunching it, that agent is unloaded and its plist is
//    moved to Agent Island's "suspended" folder (nothing is deleted)
//  · restore — puts every suspended LaunchAgent back, reloads it and reopens the apps
import AppKit
import Foundation

struct NotchApp: Codable, Equatable {
    let name: String
    let pid: Int32
    let path: String?
}

struct Suspended: Codable, Equatable {
    let name: String
    let appPath: String?
    let label: String?
    let plistOriginal: String?
    let plistSaved: String?
}

enum NotchGuard {
    /// Executable / bundle names of programs known to draw on the notch.
    static let knownNames = ["TimeTodoIsland", "MCodeIsland", "NotchNook", "boringNotch", "Boring Notch", "Alcove",
                             "DynamicLake", "MediaMate", "NotchDrop", "Vibe Island", "VibeIsland", "Claude Island", "ClaudeIsland"]

    static var supportDir: String { NSHomeDirectory() + "/Library/Application Support/AgentIsland" }

    // MARK: single instance

    private static var lockFD: Int32 = -1

    /// true = this process owns the notch; false = another Agent Island (any copy / version) already runs
    static func acquireInstanceLock() -> Bool {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        lockFD = open(supportDir + "/instance.lock", O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return true }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 { return false }
        let info = "\(getpid()) \(appVersion) \(Bundle.main.bundlePath)\n"
        ftruncate(lockFD, 0)
        _ = info.withCString { write(lockFD, $0, strlen($0)) }
        return true
    }

    /// pid / version / path of the instance that holds the lock
    static func lockHolder() -> String? {
        try? String(contentsOfFile: supportDir + "/instance.lock", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: conflicts

    static func isNotchApp(_ a: NSRunningApplication) -> Bool {
        guard a.processIdentifier != getpid() else { return false }
        if a.bundleIdentifier == bundleID { return false }
        let names = [a.localizedName, a.bundleURL?.deletingPathExtension().lastPathComponent, a.executableURL?.lastPathComponent].compactMap { $0 }
        return names.contains { n in knownNames.contains { n.caseInsensitiveCompare($0) == .orderedSame } }
    }

    static func conflicts() -> [NotchApp] {
        if let o = ProcessInfo.processInfo.environment["AGENT_ISLAND_FAKE_CONFLICT"], !o.isEmpty {
            return [NotchApp(name: o, pid: 0, path: nil)]
        }
        return NSWorkspace.shared.runningApplications.filter(isNotchApp).map {
            NotchApp(name: $0.localizedName ?? $0.executableURL?.lastPathComponent ?? "?", pid: $0.processIdentifier, path: $0.bundleURL?.path)
        }
    }

    /// The user chose to own the notch even when other notch apps exist.
    static var owns: Bool {
        get { UserDefaults.standard.bool(forKey: "ownNotch") }
        set { UserDefaults.standard.set(newValue, forKey: "ownNotch") }
    }

    static var suspended: [Suspended] {
        get { (UserDefaults.standard.data(forKey: "suspendedApps")).flatMap { try? JSONDecoder().decode([Suspended].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "suspendedApps") }
    }

    /// Should the island draw on the notch right now?
    static func shouldShow(_ conflicts: [NotchApp]) -> Bool { owns || conflicts.isEmpty }

    // MARK: takeover / restore

    /// LaunchAgent plist (user domain) whose program points into this app
    static func launchAgent(for appPath: String?) -> (label: String, plist: String)? {
        guard let appPath, !appPath.isEmpty else { return nil }
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        for f in Files.list(dir) where f.hasSuffix(".plist") {
            let p = dir + "/" + f
            guard let d = NSDictionary(contentsOfFile: p) as? [String: Any] else { continue }
            let prog = ((d["ProgramArguments"] as? [String]) ?? []) + [(d["Program"] as? String) ?? ""]
            if prog.contains(where: { $0.hasPrefix(appPath) }), let label = d["Label"] as? String { return (label, p) }
        }
        return nil
    }

    @discardableResult
    static func takeOver() -> [Suspended] {
        var done: [Suspended] = []
        let fm = FileManager.default
        let saveDir = supportDir + "/suspended"
        try? fm.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
        for app in NSWorkspace.shared.runningApplications where isNotchApp(app) {
            let name = app.localizedName ?? app.executableURL?.lastPathComponent ?? "?"
            let path = app.bundleURL?.path
            var rec = Suspended(name: name, appPath: path, label: nil, plistOriginal: nil, plistSaved: nil)
            if let (label, plist) = launchAgent(for: path) {
                Env.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
                let saved = saveDir + "/" + (plist as NSString).lastPathComponent
                try? fm.removeItem(atPath: saved)
                if (try? fm.moveItem(atPath: plist, toPath: saved)) != nil {
                    rec = Suspended(name: name, appPath: path, label: label, plistOriginal: plist, plistSaved: saved)
                }
            }
            if !app.isTerminated { app.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if !app.isTerminated { app.forceTerminate() } }
            done.append(rec)
        }
        suspended = suspended.filter { s in !done.contains { $0.name == s.name } } + done
        owns = true
        return done
    }

    @discardableResult
    static func restore() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for s in suspended {
            if let saved = s.plistSaved, let orig = s.plistOriginal, fm.fileExists(atPath: saved) {
                try? fm.moveItem(atPath: saved, toPath: orig)
                Env.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", orig])
                out.append("\(s.name): launch agent restored")
            } else if let p = s.appPath, fm.fileExists(atPath: p) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: NSWorkspace.OpenConfiguration())
                out.append("\(s.name): reopened")
            }
        }
        suspended = []
        owns = false
        return out
    }
}
