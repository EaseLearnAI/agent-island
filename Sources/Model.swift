// Agent Island · data model + state machine
// One island for every local AI coding agent: running / waiting for you / stalled / done / failed / stopped.
// Modes: idle (same size as the notch) → compact (both sides of the notch: spinner + phrase | session dots + count)
//        → flash (a card when a session changes state) → list (hover: all sessions, open / dismiss).
import AppKit
import ApplicationServices
import SwiftUI

let bundleID = "io.github.easelearnai.agent-island"
let appName = "Agent Island"

/// One agent session. state = running / stalled / waiting / done / failed / stopped
struct LiveSession: Codable, Identifiable, Equatable {
    /// "<agent>:<session id>" — unique across agents
    let id: String
    let agent: String
    let sid: String
    let title: String?
    let project: String?
    let state: String
    let updatedAt: Double
    let question: String?
    let fullTitle: String?
    let ws: String?
    /// where the session lives when it is opened: app (desktop app) / terminal / editor
    let host: String

    init(agent: String, sid: String, title: String?, state: String, updatedAt: Int64, question: String?,
         ws: String?, projectFallback: String? = nil, host: String = "app") {
        id = agent + ":" + sid
        self.agent = agent
        self.sid = sid
        let full = Clean.text(title, 300)
        self.title = Clean.text(full.isEmpty ? "(无标题)" : full, 60)
        fullTitle = full.isEmpty ? nil : full
        project = Clean.projectName(ws) ?? projectFallback
        self.state = state
        self.updatedAt = Double(updatedAt)
        self.question = question
        self.ws = ws
        self.host = host
    }

    /// demo / preview rows
    init(id: String, agent: String, title: String, project: String?, state: String, updatedAt: Double, question: String? = nil) {
        self.id = id
        self.agent = agent
        sid = id
        self.title = title
        self.project = project
        self.state = state
        self.updatedAt = updatedAt
        self.question = question
        fullTitle = title
        ws = nil
        host = "app"
    }

    var name: String { (title?.isEmpty == false ? title : nil) ?? "(无标题)" }
    var ended: Bool { ["done", "failed", "stopped"].contains(state) }
    var agentInfo: AgentInfo? { Agents.info(agent) }
    var agentShort: String { agentInfo?.short ?? agent }
    var agentColor: Color { agentInfo?.color ?? Palette.accent }
}

struct LiveSnapshot: Codable, Equatable {
    let running: Int
    let waiting: Int
    let stalled: Int
    let sessions: [LiveSession]
    /// agents that were read for this snapshot
    let agents: [String]
    /// agent id → read error (other agents still work)
    let issues: [String: String]
    let error: String?
}

/// 会话状态变化时弹出来的小卡片
struct Flash: Identifiable, Equatable {
    let id = UUID()
    let session: LiveSession
    let kind: String  // done / waiting / failed
    let at = Date()
}

/// 刚结束的那一下：收起态短暂显示「全部完成 / 出错了」
struct LastEnd: Equatable {
    let ok: Bool
    let at: Date
    let project: String?
}

enum Mode: Equatable { case idle, compact, flash, list }

/// 收起态显示什么（优先级从上到下）
enum CompactKind: Equatable { case waiting, running, stalled, finished(Bool) }

enum Palette {
    static let urgent = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let green = Color(red: 0.2, green: 0.8, blue: 0.4)
    /// running accent
    static let accent = Color(red: 41 / 255, green: 182 / 255, blue: 254 / 255)
    static let wait = Color(red: 1.0, green: 0.6, blue: 0.12)
    static let muted = Color.white.opacity(0.4)
}

func stateColor(_ s: String) -> Color {
    switch s {
    case "running": return Palette.accent
    case "waiting": return Palette.wait
    case "done": return Palette.green
    case "failed": return Palette.urgent
    default: return Palette.muted
    }
}

func stateName(_ s: String) -> String {
    switch s {
    case "running": return "进行中"
    case "stalled": return "没动静"
    case "waiting": return "等你回答"
    case "done": return "已完成"
    case "failed": return "出错"
    default: return "已停止"
    }
}

let thinkingPhrases = ["思考中…", "推进中…", "写代码中…", "整理中…", "检索中…", "构建中…", "调试中…", "规划中…", "生成中…", "验证中…", "重构中…", "收尾中…"]

func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}

func timeAgoMs(_ ms: Double) -> String { ago(Date(timeIntervalSince1970: ms / 1000)) }

/// With "Reduce motion" on, spinners freeze and glows stop pulsing
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - 状态

final class IslandModel: ObservableObject {
    @Published var mode: Mode = .idle
    @Published var notch = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
    @Published var online = true
    @Published var error: String?
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }

    @Published var live: [LiveSession] = []
    /// agents read in the last snapshot
    @Published var agents: [String] = []
    var agentCount: Int { agents.count }
    @Published var running = 0
    @Published var waiting = 0
    @Published var stalled = 0
    @Published var flash: Flash?
    @Published var flashStart = Date()
    @Published var flashTotal: TimeInterval = 4
    @Published var flashPaused = false
    @Published var lastEnd: LastEnd?
    /// 数量变化时的一下「挤压回弹」
    @Published var bump = false
    /// 有没有「辅助功能」权限（没有时列表底部提示去开启）
    @Published var axTrusted = AXIsProcessTrusted()
    var onNeedPermission: (() -> Void)?
    /// 截图预览用：卡片不自动收起
    var frozen = false

    /// 用户在列表里清掉的已结束会话：id → 清除时的 updatedAt；会话之后再有动静会重新出现
    var dismissed: [String: Double] = (UserDefaults.standard.dictionary(forKey: "dismissed") as? [String: Double]) ?? [:] {
        didSet { UserDefaults.standard.set(dismissed, forKey: "dismissed") }
    }

    var all: [LiveSession] = []
    var flashQueue: [Flash] = []
    var liveLoaded = false
    var hovering = false
    var flashTimer: Timer?
    var hoverWork: DispatchWorkItem?
    var onModeChange: (() -> Void)?

    let wide: CGFloat = 480
    let flashWidth: CGFloat = 430

    static let emptyH: CGFloat = 54
    static let footerH: CGFloat = 40
    /// 会话行 = 52 高的卡片 + 4 的行间距
    static let sessionH: CGFloat = 56
    static let sessionGap: CGFloat = 4
    static let flashBodyH: CGFloat = 76
    /// 列表里一次露出的会话行数；超过的在会话区域里滚动查看
    static let maxRows = 4

    var activeSessions: [LiveSession] { live.filter { ["waiting", "running", "stalled"].contains($0.state) } }
    var hasEnded: Bool { live.contains { $0.ended } }
    var recentEnd: LastEnd? { lastEnd.flatMap { Date().timeIntervalSince($0.at) < 12 ? $0 : nil } }

    var compactKind: CompactKind? {
        if waiting > 0 { return .waiting }
        if running > 0 { return .running }
        if stalled > 0 { return .stalled }
        if let e = recentEnd { return .finished(e.ok) }
        return nil
    }

    /// 没有卡片/悬停时停在哪个形态：没有活跃会话就缩回刘海里
    var resting: Mode { compactKind == nil ? .idle : .compact }

    /// 收起时刘海两侧各露出多宽
    var wing: CGFloat { 126 }

    var liveRows: [LiveSession] { Array(live.prefix(Self.maxRows)) }
    var listScrollable: Bool { live.count > Self.maxRows }

    var listHeight: CGFloat {
        var h = notch.height + 6
        h += liveRows.isEmpty ? Self.emptyH : CGFloat(liveRows.count) * Self.sessionH + 4
        return h + Self.footerH + 6
    }

    var size: CGSize {
        switch mode {
        case .idle: return notch
        case .compact: return CGSize(width: notch.width + wing * 2, height: notch.height)
        case .flash: return CGSize(width: flashWidth, height: notch.height + Self.flashBodyH)
        case .list: return CGSize(width: wide, height: listHeight)
        }
    }

    var bottomRadius: CGFloat {
        switch mode {
        case .idle: return 10
        case .compact: return 13
        case .flash: return 24
        case .list: return 26
        }
    }

    /// 顶部两角向外翻的「耳朵」，让岛和屏幕上沿自然衔接
    var earRadius: CGFloat {
        switch mode {
        case .idle: return 0
        case .compact: return 6
        default: return 10
        }
    }

    func setMode(_ m: Mode) {
        // 卡片接卡片（完成 → 等你回答）也要通知一次：日志 / 鼠标区域跟着更新
        guard m != mode || m == .flash else { return }
        mode = m
        onModeChange?()
    }

    /// 定时刷新：「刚完成」12 秒后收回、相对时间文案更新
    func tick() {
        if mode == .idle || mode == .compact { setMode(resting) }
        objectWillChange.send()
    }

    // MARK: 会话快照

    /// 每 2 秒一次：对比上一次的状态，变了就弹卡片
    func applyLive(_ r: LiveSnapshot) {
        if !frozen { axTrusted = AXIsProcessTrusted() }
        online = r.error == nil
        error = r.error
        if agents != r.agents { agents = r.agents }
        let prev = Dictionary(all.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        let before = [running, waiting, stalled]
        all = r.sessions
        refilter()
        if !liveLoaded {
            liveLoaded = true
            if mode == .idle || mode == .compact { setMode(resting) }
            return
        }
        for s in r.sessions {
            let p = prev[s.id]
            guard p != s.state else { continue }
            switch s.state {
            case "waiting":
                enqueueFlash(Flash(session: s, kind: "waiting"))
            case "done" where p == "running" || p == "stalled" || p == "waiting":
                lastEnd = LastEnd(ok: true, at: Date(), project: s.project)
                enqueueFlash(Flash(session: s, kind: "done"))
            case "failed" where p != nil:
                lastEnd = LastEnd(ok: false, at: Date(), project: s.project)
                enqueueFlash(Flash(session: s, kind: "failed"))
            default:
                break
            }
        }
        if before != [running, waiting, stalled] && mode == .compact { pulse() }
        if mode == .idle || mode == .compact { setMode(resting) }
    }

    func refilter() {
        live = all.filter { s in !(s.ended && (dismissed[s.id] ?? -1) >= s.updatedAt) }
        running = live.filter { $0.state == "running" }.count
        waiting = live.filter { $0.state == "waiting" }.count
        stalled = live.filter { $0.state == "stalled" }.count
        // 清除记录只留还在快照里的，避免无限增长
        let ids = Set(all.map(\.id))
        if dismissed.keys.contains(where: { !ids.contains($0) }) { dismissed = dismissed.filter { ids.contains($0.key) } }
    }

    // MARK: 管理

    /// 从岛上清掉一条已结束的会话（不动助手里的数据）
    func dismiss(_ s: LiveSession) {
        guard s.ended else { return }
        dismissed[s.id] = s.updatedAt
        refilter()
    }

    func clearEnded() {
        for s in live where s.ended { dismissed[s.id] = s.updatedAt }
        refilter()
    }

    func pulse() {
        bump = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in self?.bump = false }
    }

    func enqueueFlash(_ f: Flash) {
        flashQueue.removeAll { $0.session.id == f.session.id }
        flashQueue.append(f)
        if flashQueue.count > 3 { flashQueue.removeFirst(flashQueue.count - 3) }
        if !hovering && (mode == .idle || mode == .compact) { presentFlash() }
    }

    /// 取下一张还有效的卡片：等你回答的要还在等，完成/出错的 1 分钟内才弹
    func presentFlash() {
        while !flashQueue.isEmpty {
            let f = flashQueue.removeFirst()
            let still = live.first(where: { $0.id == f.session.id })?.state
            if f.kind == "waiting" && still != "waiting" { continue }
            if f.kind != "waiting" && Date().timeIntervalSince(f.at) > 60 { continue }
            flash = f
            setMode(.flash)
            if !muted {
                let name = f.kind == "done" ? "Glass" : f.kind == "waiting" ? "Tink" : "Basso"
                NSSound(named: name)?.play()
            }
            scheduleFlashTimer()
            return
        }
        settle()
    }

    func flashDuration() -> TimeInterval {
        switch flash?.kind {
        case "waiting": return 8
        case "failed": return 6
        default: return 4.5
        }
    }

    func scheduleFlashTimer(_ seconds: TimeInterval? = nil) {
        flashTimer?.invalidate()
        guard mode == .flash, !hovering, !frozen else { return }
        let s = seconds ?? flashDuration()
        flashStart = Date()
        flashTotal = s
        flashPaused = false
        flashTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            self?.flash = nil
            self?.presentFlash()
        }
    }

    /// 收回：还有没弹的会话卡片就接着弹，否则停到收起态
    func settle() {
        flashTimer?.invalidate()
        flash = nil
        if !hovering && !flashQueue.isEmpty { presentFlash(); return }
        setMode(resting)
    }

    /// 两指上滑：卡片先收起，列表直接收回
    func swipeAway() {
        switch mode {
        case .flash: flash = nil; presentFlash()
        case .list: settle()
        default: break
        }
    }

    // 悬停：停留 0.18s 才展开，离开 0.35s 后收回；卡片上多停一会儿就展开成列表
    func setHover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        hoverWork?.cancel()
        if inside {
            if mode == .flash { flashTimer?.invalidate(); flashPaused = true }
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, [.idle, .compact, .flash].contains(self.mode) else { return }
                self.flashTimer?.invalidate()
                self.flash = nil
                self.setMode(.list)
            }
            hoverWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (mode == .flash ? 0.45 : 0.18), execute: w)
        } else {
            if mode == .flash { scheduleFlashTimer(2.5); return }
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, self.mode == .list else { return }
                self.settle()
            }
            hoverWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }

    /// Click a session: bring its agent to the front and select that session (Accessibility), or the hosting terminal for CLIs
    func openSession(_ s: LiveSession) {
        AgentJump.open(s)
    }

    /// Open the agent app of the most relevant session (or the first installed one)
    func openAgent() {
        AgentJump.openApp(live.first?.agent)
    }

    /// 引导最后一步「试一下」：弹一张示例卡片
    func demo() {
        let s = LiveSession(id: "demo", agent: live.first?.agent ?? "claude", title: "欢迎使用 Agent Island", project: "示例", state: "done",
                            updatedAt: Date().timeIntervalSince1970 * 1000)
        flashQueue.removeAll { $0.session.id == "demo" }
        flashQueue.insert(Flash(session: s, kind: "done"), at: 0)
        if mode == .list { setMode(resting) }
        if mode != .flash { presentFlash() }
    }

    func tapFlash() {
        if flash?.session.id == "demo" { flash = nil; presentFlash(); return }
        if let s = flash?.session { openSession(s) } else { openAgent() }
        flash = nil
        presentFlash()
    }
}
