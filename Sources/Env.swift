// Runtime environment: which agents are installed / have data, permissions, install location, login item;
// plus the actions used by onboarding.
import AppKit
import ApplicationServices
import ServiceManagement

let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
let appBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
let appCommit = (Bundle.main.infoDictionary?["AgentIslandCommit"] as? String) ?? "local"
/// "2.1.0 (build 7, a1b2c3d)" — shown in About, --version and --check so it is always clear which copy is running
let appVersionLong = "\(appVersion) (build \(appBuild), \(appCommit))"

struct AgentStatus: Codable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var dataPath: String?
    var app: String?
    var appName: String?
    var running: Bool
}

struct EnvStatus: Codable, Equatable {
    var version: String
    var appPath: String
    var inApplications: Bool
    var translocated: Bool
    var agents: [AgentStatus]
    var axTrusted: Bool
    var loginItem: String  // enabled / disabled / requiresApproval / unknown

    var detected: [AgentStatus] { agents.filter { $0.dataPath != nil } }
}

enum Env {
    static let accessibilityURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let loginItemsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    /// 「应用程序」文件夹：/Applications 可写就放那里，否则 ~/Applications；测试时可用环境变量指到临时目录
    static func appsDir() -> String {
        if let e = ProcessInfo.processInfo.environment["AGENT_ISLAND_APPS_DIR"], !e.isEmpty { return e }
        return FileManager.default.isWritableFile(atPath: "/Applications") ? "/Applications" : NSHomeDirectory() + "/Applications"
    }

    static func status() -> EnvStatus {
        let path = Bundle.main.bundleURL.path
        let dirs = ["/Applications/", NSHomeDirectory() + "/Applications/", appsDir() + "/"]
        let home = Agents.home
        let agents = Agents.all.map { s -> AgentStatus in
            let running = AppLocator.running(s.info).first
            let app = running?.bundleURL ?? AppLocator.installed(s.info)
            return AgentStatus(id: s.info.id, name: s.info.name, enabled: Agents.isEnabled(s.info.id),
                               dataPath: s.dataPaths(home: home).first, app: app?.path, appName: app.map(AppLocator.describe),
                               running: running != nil)
        }
        return EnvStatus(
            version: appVersionLong,
            appPath: path,
            inApplications: dirs.contains { path.hasPrefix($0) },
            translocated: path.contains("/AppTranslocation/"),
            agents: agents,
            axTrusted: AXIsProcessTrusted(),
            loginItem: loginStatus())
    }

    // MARK: 辅助功能

    /// 把 App 加进「辅助功能」列表（系统会弹一次提示），并直接打开对应的设置页
    static func requestAccessibility() {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opt)
        openSettings(accessibilityURL)
    }

    static func openSettings(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    // MARK: 登录项

    static func loginStatus() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        // notFound = 从没注册过，对用户来说就是「未开启」
        case .notRegistered, .notFound: return "disabled"
        @unknown default: return "unknown"
        }
    }

    static func setLogin(_ on: Bool) throws {
        let s = SMAppService.mainApp
        if on {
            if s.status != .enabled { try s.register() }
        } else if s.status == .enabled || s.status == .requiresApproval {
            try s.unregister()
        }
    }

    // MARK: 安装位置

    /// 复制到「应用程序」并去掉隔离标记（用户已经同意打开过了），返回新位置
    static func moveToApplications() throws -> URL {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: appsDir())
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("AgentIsland.app")
        let src = Bundle.main.bundleURL
        if src.standardizedFileURL.path == dest.standardizedFileURL.path { return dest }
        if fm.fileExists(atPath: dest.path) {
            if (try? fm.trashItem(at: dest, resultingItemURL: nil)) == nil { try fm.removeItem(at: dest) }
        }
        try fm.copyItem(at: src, to: dest)
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        return dest
    }

    /// 退出当前进程，1 秒后从新位置重新打开
    static func relaunch(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: 卸载

    /// 关登录项、清设置、把 App 移到废纸篓。返回做了哪些事
    @discardableResult
    static func uninstall() -> [String] {
        var done: [String] = []
        if (try? setLogin(false)) != nil { done.append("login-off") }
        let legacy = NSHomeDirectory() + "/Library/LaunchAgents/\(bundleID).plist"
        if FileManager.default.fileExists(atPath: legacy) {
            run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(bundleID)"])
            try? FileManager.default.removeItem(atPath: legacy)
            done.append("legacy-agent")
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        done.append("defaults")
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" && !app.path.contains("/AppTranslocation/") {
            let fm = FileManager.default
            if ProcessInfo.processInfo.environment["AGENT_ISLAND_UNINSTALL_DELETE"] == "1" {
                if (try? fm.removeItem(at: app)) != nil { done.append("app-deleted") }
            } else if (try? fm.trashItem(at: app, resultingItemURL: nil)) != nil {
                done.append("app-trashed")
            }
        }
        return done
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
