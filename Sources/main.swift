// Agent Island · entry point
// Reads local state of AI coding agents (MiniMax Code / Claude Code / Codex / Kimi Code / ZCode) — read-only, offline.
// Command line (testing / troubleshooting):
//   AgentIsland                              normal start (notch island + menu bar icon; onboarding on first launch)
//   --snapshot                               print one session snapshot as JSON and exit
//   --agents kimi,zcode                      only read these agents (works with every mode)
//   --home PATH                              look for agent data under PATH instead of ~ (fixtures)
//   --open ID|TITLE                          jump to a session like a click on the island (prints hit / miss)
//   --check                                  print environment JSON (agents / permissions / login item / location)
//   --preview KIND [--seconds N]             render a UI state with sample data, print the window number, stay N s
//                                            KIND: compact / list / list-ax / empty / nodata / flash-done / flash-waiting / flash-failed / guide:0…4
//   --login on|off|status                    login item
//   --move-to-applications                   copy into Applications (no relaunch), print the new path
//   --uninstall --yes                        uninstall (login item off, settings cleared, app to Trash)
//   --reset-onboarding                       show onboarding again on next launch
//   --render-icon OUT.png / --version
import AppKit
import SwiftUI

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func printJSON<T: Encodable>(_ v: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) { print(s) }
}

let reopenNote = Notification.Name("io.github.easelearnai.agent-island.reopen")

// MARK: - 窗口

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = IslandModel()
    let guide = OnboardingController()
    let preview: String?
    var panel: IslandPanel!
    var statusItem: NSStatusItem?
    var monitors: [Any] = []
    var tickTimer: Timer?
    var liveTimer: Timer?
    var liveBusy = false
    var swipeAcc: CGFloat = 0
    var swipeFired = false
    var promptedPermission = false
    var selfTesting = false
    let canvas = CGSize(width: 640, height: 560)
    let dbQueue = DispatchQueue(label: "agent-island.read", qos: .utility)

    init(preview: String?) {
        self.preview = preview
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只留一个实例：再打开一次（比如双击 App）就让已经在跑的那个弹出引导，自己退出
        if preview == nil && Bundle.main.bundleIdentifier == bundleID {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != getpid() }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(reopenNote, object: nil, userInfo: nil, deliverImmediately: true)
                exit(0)
            }
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopen), name: reopenNote, object: nil)
        }

        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let host = FirstMouseHostingView(rootView: IslandView(m: model))
        host.frame = NSRect(origin: .zero, size: canvas)
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        model.onModeChange = { [weak self] in
            guard let self else { return }
            // 运行日志（~/Library/Logs 或终端里可见），也给自动化测试判断界面状态
            if self.preview == nil {
                print("mode: \(self.model.mode)\(self.model.mode == .flash ? self.model.flash.map { " · \($0.kind) · \($0.session.name)" } ?? "" : "")")
                fflush(stdout)
            }
            DispatchQueue.main.async { self.updateMouse() }
        }
        model.onNeedPermission = { [weak self] in self?.showGuide(GuideStep.permission) }
        // 点对话但没权限：本次运行只弹一次引导，之后只把助手叫到前台，不反复打扰
        AgentJump.onNeedPermission = { [weak self] in
            guard let self, !self.promptedPermission else { return }
            self.promptedPermission = true
            self.showGuide(GuideStep.permission)
        }
        guide.onDemo = { [weak self] in self?.model.demo() }

        if let p = preview { startPreview(p); return }

        setupStatusItem()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.updateMouse() }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited], handler: { [weak self] e in self?.updateMouse(); return e }) {
            monitors.append(l)
        }
        if let s = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] e in self?.handleScroll(e); return e }) {
            monitors.append(s)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(layout), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(layout), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.tick(); AgentJump.warmUp() }
        AgentJump.warmUp()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollLive() }
        print("\(appName) \(appVersion) 启动，检测到：\(SessionStore.detected().map(\.info.id).joined(separator: ", "))")
        fflush(stdout)
        pollLive()

        if CommandLine.arguments.contains("--selftest") { runSelfTest(); return }
        let d = UserDefaults.standard
        if d.object(forKey: "resumeStep") != nil {
            let s = d.integer(forKey: "resumeStep")
            d.removeObject(forKey: "resumeStep")
            showGuide(s)
        } else if !d.bool(forKey: "onboarded") {
            showGuide(GuideStep.welcome)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopen()
        return false
    }

    /// 再次打开 App：都设置好了就显示「设置好了」页（提示 + 状态），否则回到环境检查
    @objc func reopen() {
        DispatchQueue.main.async {
            let e = Env.status()
            self.showGuide(e.axTrusted && !e.detected.isEmpty ? GuideStep.done : GuideStep.check)
        }
    }

    func showGuide(_ step: Int) {
        print("guide: \(step)")
        fflush(stdout)
        guide.show(step: step)
        if preview != nil, let w = guide.window {
            print("GUIDE_WINDOW \(w.windowNumber)")
            fflush(stdout)
        }
    }

    /// read every 2 s; skip if the previous read has not finished
    func pollLive() {
        guard !liveBusy else { return }
        liveBusy = true
        dbQueue.async { [weak self] in
            let snap = SessionStore.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.liveBusy = false
                self.model.applyLive(snap)
                self.refreshStatus()
            }
        }
    }

    // MARK: 截图预览

    func startPreview(_ kind: String) {
        model.frozen = true
        let now = Date().timeIntervalSince1970 * 1000
        func s(_ id: String, _ a: String, _ t: String, _ p: String, _ st: String, _ agoMin: Double, _ q: String? = nil) -> LiveSession {
            LiveSession(id: id, agent: a, title: t, project: p, state: st, updatedAt: now - agoMin * 60000, question: q)
        }
        let fake = [
            s("w", "kimi", "确认发布方案", "marketing", "waiting", 2, "直接发到群里，还是先给你看一眼？"),
            s("r1", "claude", "重构登录模块", "web-app", "running", 0.2),
            s("r2", "codex", "补齐单元测试", "api-server", "running", 1),
            s("st", "zcode", "批量生成配图", "assets", "stalled", 150),
            s("f", "mcode", "部署落地页", "landing", "failed", 6),
            s("d", "claude", "生成 PPT 初稿", "deck", "done", 3),
        ]
        func snap(_ list: [LiveSession], error: String? = nil) -> LiveSnapshot {
            LiveSnapshot(running: list.filter { $0.state == "running" }.count, waiting: list.filter { $0.state == "waiting" }.count,
                         stalled: list.filter { $0.state == "stalled" }.count, sessions: list, agents: ["claude", "codex", "kimi", "zcode", "mcode"], issues: [:], error: error)
        }
        switch kind {
        case "empty": model.applyLive(snap([]))
        case "nodata": model.applyLive(snap([], error: "没找到任何支持的 AI 编程助手数据"))
        default: model.applyLive(snap(fake))
        }
        if kind == "list-ax" { model.axTrusted = true }
        if kind.hasPrefix("list") || kind == "empty" || kind == "nodata" { model.setMode(.list) }
        if kind == "compact" { model.setMode(.compact) }
        if kind.hasPrefix("flash-") {
            let k = String(kind.dropFirst(6))
            let session = fake.first { $0.state == (k == "done" ? "done" : k == "waiting" ? "waiting" : "failed") }!
            model.flash = Flash(session: session, kind: k)
            model.setMode(.flash)
        }
        if kind.hasPrefix("guide:") { showGuide(Int(kind.dropFirst(6)) ?? 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("ISLAND_WINDOW \(self.panel.windowNumber)")
            fflush(stdout)
        }
        let secs = Double(argValue("--seconds") ?? "") ?? 15
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    }

    // MARK: 菜单栏

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: appName)
        img?.isTemplate = true
        item.button?.image = img
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatus()
    }

    func refreshStatus() {
        guard let b = statusItem?.button else { return }
        let active = model.activeSessions.count
        b.title = active > 0 ? " \(active)" : ""
        b.contentTintColor = model.waiting > 0 ? NSColor.systemOrange : nil
        b.toolTip = "\(appName)：\(model.running) 进行中 · \(model.waiting) 等你回答"
    }

    func item(_ title: String, _ action: Selector?, key: String = "", on: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.isEnabled = enabled && action != nil
        if let on { it.state = on ? .on : .off }
        return it
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(model.online ? "\(model.running) 进行中 · \(model.waiting) 等你回答 · \(model.stalled) 没动静" : (model.error ?? "未找到 AI 助手数据"), nil))
        let sessions = model.live.prefix(8)
        if !sessions.isEmpty {
            menu.addItem(.separator())
            for s in sessions {
                let it = item("\(stateName(s.state)) · \(s.agentShort) · \(s.name)", #selector(openSessionItem(_:)))
                it.representedObject = s.id
                it.toolTip = [s.project, s.question].compactMap { $0 }.joined(separator: " · ")
                menu.addItem(it)
            }
            menu.addItem(item("清除已结束的对话", #selector(clearEnded), enabled: model.hasEnded))
        }
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "打开助手", action: nil, keyEquivalent: "")
        let openMenu = NSMenu()
        for s in Agents.all where AppLocator.installed(s.info) != nil || !AppLocator.running(s.info).isEmpty {
            let it = item(s.info.name, #selector(openAgentItem(_:)))
            it.representedObject = s.info.id
            openMenu.addItem(it)
        }
        if openMenu.items.isEmpty { openMenu.addItem(item("没有检测到桌面端助手", nil)) }
        openItem.submenu = openMenu
        menu.addItem(openItem)
        if !AXIsProcessTrusted() {
            let ax = item("开启辅助功能（点对话直达）…", #selector(openPermission))
            ax.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(ax)
        }
        menu.addItem(item("静音", #selector(toggleMute), on: model.muted))
        menu.addItem(item("登录时自动启动", #selector(toggleLogin), on: Env.loginStatus() == "enabled"))

        let sourceItem = NSMenuItem(title: "数据来源", action: nil, keyEquivalent: "")
        let source = NSMenu()
        let home = Agents.home
        for s in Agents.all {
            let found = !s.dataPaths(home: home).isEmpty
            let n = model.live.filter { $0.agent == s.info.id && !$0.ended }.count
            let it = item(found ? "\(s.info.name)\(n > 0 ? "（\(n) 个进行中）" : "")" : "\(s.info.name)（未检测到）",
                          #selector(toggleAgent(_:)), on: Agents.isEnabled(s.info.id) && found, enabled: found)
            it.representedObject = s.info.id
            source.addItem(it)
        }
        sourceItem.submenu = source
        menu.addItem(sourceItem)

        menu.addItem(.separator())
        menu.addItem(item("新手引导…", #selector(openGuide)))
        menu.addItem(item("关于 \(appName)", #selector(about)))
        menu.addItem(item("卸载 \(appName)…", #selector(uninstall)))
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    @objc func openSessionItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = model.live.first(where: { $0.id == id }) else { return }
        model.openSession(s)
    }

    @objc func toggleAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var d = Agents.disabled
        if d.contains(id) { d.remove(id) } else { d.insert(id) }
        Agents.disabled = d
        model.liveLoaded = false  // don't treat the source switch as state changes (no cards)
        pollLive()
    }

    @objc func openAgentItem(_ sender: NSMenuItem) {
        AgentJump.openApp(sender.representedObject as? String)
    }

    @objc func clearEnded() { model.clearEnded(); refreshStatus() }
    @objc func openPermission() { showGuide(GuideStep.permission) }
    @objc func openGuide() { showGuide(GuideStep.welcome) }
    @objc func toggleMute() { model.muted.toggle() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() {
        let on = Env.loginStatus() != "enabled"
        do {
            try Env.setLogin(on)
            UserDefaults.standard.set(true, forKey: "loginChosen")
        } catch {
            alert("没能设置开机自启", error.localizedDescription)
        }
    }

    @objc func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .credits: NSAttributedString(string: "把 AI 编程助手的会话进度放到刘海上。\n支持 Claude Code / Codex / Kimi Code / ZCode / MiniMax Code。\n只在本机只读状态文件，不联网、不上传数据。\ngithub.com/EaseLearnAI/agent-island",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func uninstall() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "卸载 \(appName)？"
        a.informativeText = "会关闭开机自启、清除灵动岛的设置，并把 App 移到废纸篓。各助手里的对话不受影响。"
        a.addButton(withTitle: "卸载")
        a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Env.uninstall()
        NSApp.terminate(nil)
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: 手势与布局

    /// 两指上滑（手指方向，兼容自然滚动）收起卡片/列表
    func handleScroll(_ e: NSEvent) {
        guard e.window === panel, [.flash, .list].contains(model.mode) else { return }
        if model.mode == .list && model.listScrollable { return }
        if e.phase.contains(.began) { swipeAcc = 0; swipeFired = false }
        let dy = e.scrollingDeltaY
        let fingerUp = e.isDirectionInvertedFromDevice ? dy < 0 : dy > 0
        guard fingerUp, abs(dy) > abs(e.scrollingDeltaX) else { return }
        swipeAcc += abs(dy)
        if swipeAcc > 26 && !swipeFired {
            swipeFired = true
            model.swipeAway()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.swipeAcc = 0; self?.swipeFired = false }
        }
    }

    /// 优先放在带刘海的内建屏上；没有刘海的屏，收起时完全隐藏，展开时从顶部菜单栏中间落下。
    func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    @objc func layout() {
        guard let screen = targetScreen() else { return }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            model.hasNotch = true
            model.notch = CGSize(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
        } else {
            model.hasNotch = false
            model.notch = CGSize(width: 190, height: max(24, f.maxY - screen.visibleFrame.maxY))
        }
        panel.setFrame(NSRect(x: f.midX - canvas.width / 2, y: f.maxY - canvas.height, width: canvas.width, height: canvas.height), display: true)
        panel.orderFrontRegardless()
    }

    /// 只有鼠标在岛的实际形状里时窗口才接收点击，其余区域点击穿透到菜单栏/下面的窗口。
    func updateMouse() {
        guard !selfTesting else { return }
        let s = model.size
        let f = panel.frame
        var r = NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
        if model.mode == .idle || model.mode == .compact { r = r.insetBy(dx: -8, dy: -4) }
        let inside = r.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !(inside && model.mode != .idle)
        model.setHover(inside)
    }
}

// MARK: - Self-test (--selftest --home fixtures): walks user actions through the real state machine, prints PASS / FAIL

extension IslandController {
    func runSelfTest() {
        AgentJump.dryRun = true
        selfTesting = true  // 自测期间不看真实鼠标位置，免得用户动鼠标干扰悬停判断
        var fails = 0
        var steps: [(String, Double, () -> Bool)] = []
        func check(_ name: String, after: Double = 0.6, _ ok: @escaping () -> Bool) { steps.append((name, after, ok)) }
        func act(_ f: @escaping () -> Void) { steps.append(("", 0, { f(); return true })) }

        check("启动后读到会话，有进行中的 → 收起态", after: 3) { self.model.liveLoaded && self.model.mode == .compact && self.model.running > 0 }
        act { self.model.setHover(true) }
        check("鼠标移到刘海 → 展开会话列表") { self.model.mode == .list }
        act { self.model.setHover(false) }
        check("鼠标移开 → 收回收起态", after: 0.8) { self.model.mode == .compact }
        act { self.model.setHover(true) }
        check("再次悬停展开") { self.model.mode == .list }
        act { self.model.swipeAway() }
        check("两指上滑 → 收起") { self.model.mode == .compact }
        act { self.model.setHover(false) }
        var dismissedID = ""
        act {
            if let s = self.model.live.first(where: { $0.ended }) { dismissedID = s.id; self.model.dismiss(s) }
        }
        check("清除一条已结束的对话 → 从列表消失") { !dismissedID.isEmpty && !self.model.live.contains { $0.id == dismissedID } }
        check("清除后经过一次刷新仍不出现", after: 2.6) { !self.model.live.contains { $0.id == dismissedID } }
        act { self.model.clearEnded() }
        check("一键清除已结束") { !self.model.hasEnded && !self.model.activeSessions.isEmpty }
        act { if let s = self.model.live.first { self.model.openSession(s) } }
        check("点对话：找到要跳转的助手", after: 0.8) { AgentJump.lastTarget != nil }
        check("没有辅助功能权限时点对话 → 打开引导的权限页") { AXIsProcessTrusted() || self.guide.state?.step == GuideStep.permission }
        act { self.model.onNeedPermission?() }
        check("列表底部「开启辅助功能」→ 权限页") { self.guide.state?.step == GuideStep.permission && self.guide.window?.isVisible == true }
        act { self.guide.state?.go(GuideStep.welcome) }
        check("引导：欢迎页") { self.guide.state?.step == GuideStep.welcome }
        act { self.guide.state?.go(GuideStep.check) }
        check("引导：环境检查读到数据") { !(self.guide.state?.env.detected.isEmpty ?? true) && self.guide.state?.snapshot?.error == nil }
        act { self.guide.state?.go(GuideStep.permission) }
        check("引导：权限页状态与系统一致") { self.guide.state?.env.axTrusted == AXIsProcessTrusted() }
        act { self.guide.state?.go(GuideStep.login); self.guide.state?.wantLogin = false }
        act { self.guide.state?.go(GuideStep.done) }
        check("引导：开机自启按选择生效（关）并到完成页") { self.guide.state?.step == GuideStep.done && Env.loginStatus() != "enabled" && self.guide.state?.message == nil }
        check("引导：完成后记为已看过") { UserDefaults.standard.bool(forKey: "onboarded") }
        act { self.guide.state?.demo() }
        check("「试一下」→ 刘海弹出示例卡片") { self.model.mode == .flash && self.model.flash?.session.id == "demo" }
        act { self.model.tapFlash() }
        check("点示例卡片 → 收起，不去打开助手") { self.model.mode != .flash }
        act { self.guide.state?.close() }
        check("关闭引导窗口") { self.guide.window == nil }
        act { self.reopen() }
        check("再次打开 App → 唤起引导", after: 0.8) { self.guide.window?.isVisible == true }
        act { self.guide.state?.close() }
        check("菜单栏图标存在") { self.statusItem?.button != nil }
        check("菜单项齐全") {
            let menu = NSMenu()
            self.menuNeedsUpdate(menu)
            let titles = menu.items.map(\.title)
            let need = ["打开助手", "静音", "登录时自动启动", "数据来源", "新手引导…", "关于 \(appName)", "卸载 \(appName)…", "退出"]
            let sessionItems = menu.items.filter { $0.action == #selector(self.openSessionItem(_:)) }.count
            return need.allSatisfy(titles.contains) && sessionItems == min(8, self.model.live.count)
                && (AXIsProcessTrusted() || titles.contains("开启辅助功能（点对话直达）…"))
        }
        act { self.model.muted = true }
        check("静音设置会保存") { UserDefaults.standard.bool(forKey: "muted") }
        act { self.model.muted = false }

        func run(_ i: Int) {
            guard i < steps.count else {
                print(fails == 0 ? "SELFTEST OK" : "SELFTEST FAILED \(fails)")
                fflush(stdout)
                exit(fails == 0 ? 0 : 1)
            }
            let (name, delay, f) = steps[i]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let ok = f()
                if !name.isEmpty {
                    print("\(ok ? "PASS" : "FAIL") \(name)")
                    fflush(stdout)
                    if !ok { fails += 1 }
                }
                run(i + 1)
            }
        }
        run(0)
    }
}

// MARK: - 命令行模式

/// App icon: dark rounded square, a notch pill with three state dots (running / waiting / done) and a card
func renderIcon(to path: String, size: Int = 1024) -> Bool {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.1, alpha: 1)])
    bg?.draw(in: NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225), angle: -90)
    let pw = rect.width * 0.7, ph = rect.width * 0.24
    let pill = NSRect(x: rect.midX - pw / 2, y: rect.maxY - rect.width * 0.2 - ph, width: pw, height: ph)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: ph / 2, yRadius: ph / 2).fill()
    let dots: [NSColor] = [NSColor(calibratedRed: 0.16, green: 0.71, blue: 1, alpha: 1), NSColor(calibratedRed: 1, green: 0.6, blue: 0.12, alpha: 1),
                           NSColor(calibratedRed: 0.2, green: 0.8, blue: 0.4, alpha: 1)]
    let d = ph * 0.42
    for (i, col) in dots.enumerated() {
        col.setFill()
        let x = pill.midX + CGFloat(i - 1) * d * 1.7 - d / 2
        NSBezierPath(ovalIn: NSRect(x: x, y: pill.midY - d / 2, width: d, height: d)).fill()
    }
    let cw = rect.width * 0.62, ch = rect.width * 0.2
    let card = NSRect(x: rect.midX - cw / 2, y: pill.minY - rect.width * 0.1 - ch, width: cw, height: ch)
    NSColor(calibratedWhite: 1, alpha: 0.1).setFill()
    NSBezierPath(roundedRect: card, xRadius: ch * 0.3, yRadius: ch * 0.3).fill()
    NSColor(calibratedRed: 0.2, green: 0.8, blue: 0.4, alpha: 1).setFill()
    let cd = ch * 0.46
    NSBezierPath(ovalIn: NSRect(x: card.minX + ch * 0.3, y: card.midY - cd / 2, width: cd, height: cd)).fill()
    NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + ch * 0.3 + cd + ch * 0.25, y: card.midY - ch * 0.07, width: cw * 0.5, height: ch * 0.14), xRadius: ch * 0.07, yRadius: ch * 0.07).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

let args = CommandLine.arguments
if let a = argValue("--agents") {
    Agents.cliFilter = Set(a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
}
if let h = argValue("--home") { Agents.home = h }
if args.contains("--version") {
    print(appVersion)
    exit(0)
}
if args.contains("--snapshot") {
    let snap = SessionStore.snapshot()
    printJSON(snap)
    exit(snap.error == nil ? 0 : 2)
}
if let target = argValue("--open") {
    // jump to one session (agent:sid, or a title substring) the same way a click on the island does
    let snap = SessionStore.snapshot(limit: 100)
    guard let s = snap.sessions.first(where: { $0.id == target || $0.name.contains(target) }) else { print("not found: \(target)"); exit(2) }
    print("open: \(s.id) · \(s.name)")
    AgentJump.open(s)
    RunLoop.main.run(until: Date().addingTimeInterval(Double(argValue("--seconds") ?? "") ?? 5))
    print("frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
    exit(0)
}
if args.contains("--check") {
    printJSON(Env.status())
    exit(0)
}
if let v = argValue("--login") {
    do {
        if v == "on" { try Env.setLogin(true) } else if v == "off" { try Env.setLogin(false) }
        print(Env.loginStatus())
        exit(0)
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
}
if args.contains("--move-to-applications") {
    do {
        print(try Env.moveToApplications().path)
        exit(0)
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
}
if args.contains("--uninstall") {
    guard args.contains("--yes") else { print("加 --yes 确认"); exit(1) }
    printJSON(Env.uninstall())
    exit(0)
}
if args.contains("--reset-onboarding") {
    UserDefaults.standard.removeObject(forKey: "onboarded")
    exit(0)
}
if let out = argValue("--render-icon") {
    exit(renderIcon(to: out) ? 0 : 1)
}

let app = NSApplication.shared
let controller = IslandController(preview: argValue("--preview"))
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
