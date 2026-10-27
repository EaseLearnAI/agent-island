// 新手引导：第一次打开时出现，也可以从菜单栏「新手引导…」或再次双击 App 打开。
// 欢迎 → 环境检查（检测到哪些 AI 助手 / 安装位置）→ 辅助功能权限（实时检测）→ 开机自启 → 完成（试一下）
import AppKit
import SwiftUI

enum GuideStep {
    static let welcome = 0
    static let check = 1
    static let permission = 2
    static let login = 3
    static let done = 4
    static let count = 5
}

final class OnboardingState: ObservableObject {
    @Published var step: Int
    @Published var env = Env.status()
    @Published var snapshot: LiveSnapshot?
    @Published var wantLogin: Bool
    @Published var message: String?
    @Published var justGranted = false
    var demo: () -> Void = {}
    var close: () -> Void = {}
    var timer: Timer?

    init(step: Int) {
        self.step = step
        let chosenOff = UserDefaults.standard.bool(forKey: "loginChosen") && Env.loginStatus() != "enabled"
        wantLogin = !chosenOff
        refresh()
    }

    func start() {
        timer?.invalidate()
        // 每秒检测一次：用户在系统设置里打开开关后，这里马上变绿
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        let before = env.axTrusted
        let e = Env.status()
        if e != env { env = e }
        if step == GuideStep.check { snapshot = SessionStore.snapshot() }
        if step == GuideStep.permission && !before && e.axTrusted {
            justGranted = true
            NSSound(named: "Glass")?.play()
        }
    }

    func go(_ s: Int) {
        if step == GuideStep.login && s > step { applyLogin() }
        message = nil
        withAnimation(.easeOut(duration: 0.22)) { step = max(0, min(GuideStep.count - 1, s)) }
        if step == GuideStep.done { UserDefaults.standard.set(true, forKey: "onboarded") }
        refresh()
    }

    func applyLogin() {
        do {
            try Env.setLogin(wantLogin)
            UserDefaults.standard.set(true, forKey: "loginChosen")
        } catch {
            message = "没能设置开机自启：\(error.localizedDescription)"
        }
        env = Env.status()
    }

    func moveToApplications() {
        do {
            let dest = try Env.moveToApplications()
            UserDefaults.standard.set(GuideStep.permission, forKey: "resumeStep")
            UserDefaults.standard.synchronize()
            Env.relaunch(dest)
        } catch {
            message = "移动失败：\(error.localizedDescription)。也可以手动把 \(appName) 拖进「应用程序」文件夹。"
        }
    }

}

// MARK: - 按钮样式（自绘，窗口不在前台时颜色也不变灰）

struct FilledButton: ButtonStyle {
    var color: Color = Palette.accent
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(prominent ? .white : .primary)
            .padding(.horizontal, 16)
            .frame(minWidth: 84, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? color : Color.primary.opacity(0.07)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - 窗口

final class OnboardingController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    var state: OnboardingState?
    var onDemo: () -> Void = {}

    func show(step: Int) {
        if let w = window, let s = state {
            s.go(step)
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let s = OnboardingState(step: step)
        s.demo = { [weak self] in self?.onDemo() }
        s.close = { [weak self] in self?.window?.close() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = appName
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(s: s))
        w.delegate = self
        window = w
        state = s
        s.start()
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        state?.stop()
        // 中途关掉也算看过了，下次启动不再自动弹；菜单栏里随时能重新打开
        UserDefaults.standard.set(true, forKey: "onboarded")
        window = nil
        state = nil
    }
}

// MARK: - 页面

struct OnboardingView: View {
    @ObservedObject var s: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch s.step {
                case GuideStep.welcome: WelcomePage()
                case GuideStep.check: CheckPage(s: s)
                case GuideStep.permission: PermissionPage(s: s)
                case GuideStep.login: LoginPage(s: s)
                default: DonePage(s: s)
                }
            }
            .id(s.step)
            .transition(.opacity)
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: 620, height: 540)
    }

    var primaryTitle: String {
        switch s.step {
        case GuideStep.welcome: return "开始设置"
        case GuideStep.permission: return s.env.axTrusted ? "下一步" : "跳过，以后再开"
        case GuideStep.done: return "完成"
        default: return "下一步"
        }
    }

    var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<GuideStep.count, id: \.self) { i in
                    Capsule()
                        .fill(i == s.step ? Palette.accent : Color.secondary.opacity(0.25))
                        .frame(width: i == s.step ? 18 : 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.2), value: s.step)
            Spacer()
            if s.step > GuideStep.welcome && s.step < GuideStep.done {
                Button("上一步") { s.go(s.step - 1) }
                    .buttonStyle(FilledButton(prominent: false))
            }
            if s.step == GuideStep.permission && !s.env.axTrusted {
                Button(primaryTitle) { s.go(s.step + 1) }
                    .buttonStyle(FilledButton(prominent: false))
            } else {
                Button(primaryTitle) {
                    if s.step == GuideStep.done { s.close() } else { s.go(s.step + 1) }
                }
                .buttonStyle(FilledButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 66)
        .overlay(Divider(), alignment: .top)
    }
}

struct PageHeader: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.14)))
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 状态行：ok = true 绿 / false 红 / nil 橙（建议处理）
struct StatusRow<Trailing: View>: View {
    let ok: Bool?
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(ok == true ? Palette.green : ok == false ? Palette.urgent : Palette.wait)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

extension StatusRow where Trailing == EmptyView {
    init(ok: Bool?, title: String, detail: String) {
        self.init(ok: ok, title: title, detail: detail, trailing: { EmptyView() })
    }
}

struct MessageLine: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Palette.urgent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 1 欢迎

/// Illustration: the notch with a spinner + session dots, and a "done" card below
struct IslandMock: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.83, green: 0.85, blue: 0.87), Color(red: 0.90, green: 0.88, blue: 0.84)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.white.opacity(0.45)).frame(height: 26)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    SpinnerView(size: 16)
                    PhraseTicker(size: 10)
                }
                .frame(width: 104, alignment: .leading)
                .padding(.leading, 10)
                Spacer(minLength: 96)
                HStack(spacing: 5) {
                    SessionDots(states: ["waiting", "running", "running"])
                    Text("3").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.white)
                }
                .frame(width: 60, alignment: .trailing)
                .padding(.trailing, 10)
            }
            .frame(width: 300, height: 26)
            .background(NotchShape(ear: 6, bottom: 11).fill(Color.black).frame(width: 312, height: 26))
            HStack(spacing: 10) {
                CheckDraw(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("生成 PPT 初稿").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    Text("Claude · deck · 刚刚跑完").font(.system(size: 10.5)).foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Text("打开").font(.system(size: 10.5, weight: .bold)).foregroundColor(.black)
                    .padding(.horizontal, 9).frame(height: 21).background(Capsule().fill(Palette.green))
            }
            .padding(.horizontal, 14)
            .frame(width: 290, height: 52)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .offset(y: 44)
        }
        .frame(height: 124)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Palette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            IslandMock()
            VStack(alignment: .leading, spacing: 6) {
                Text(appName).font(.system(size: 24, weight: .bold))
                Text("把 Claude Code、Codex、Kimi Code、ZCode、MiniMax Code 等 AI 编程助手的会话进度，放到屏幕顶部的刘海上。")
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "rectangle.topthird.inset.filled", title: "一眼看清进度", detail: "哪些对话在跑、哪个在等你回答、哪个刚做完，刘海两侧实时显示。")
                FeatureRow(icon: "bell.badge", title: "做完了会叫你", detail: "对话完成、等你回答或出错时，从刘海弹出提醒。")
                FeatureRow(icon: "arrow.up.forward.app", title: "点一下就回到那条对话", detail: "鼠标移到刘海上展开列表，点哪条就跳到对应助手里的哪条（命令行助手会切到对应的终端窗口）。")
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("只在本机只读各助手的本地状态文件，不联网、不上传任何数据。")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }
}

// MARK: 2 环境检查

struct CheckPage: View {
    @ObservedObject var s: OnboardingState

    var folderName: String {
        let p = s.env.appPath
        if s.env.translocated || p.hasPrefix("/Volumes/") { return "安装盘 / 下载文件" }
        return URL(fileURLWithPath: p).deletingLastPathComponent().lastPathComponent
    }

    func detail(_ a: AgentStatus) -> String {
        guard let p = a.dataPath else {
            return a.appName.map { "已安装 \($0)，还没有会话数据" } ?? "未检测到（装好并用过一次后会自动识别）"
        }
        var parts: [String] = []
        if let n = a.appName { parts.append(n + (a.running ? " · 正在运行" : "")) }
        if let snap = s.snapshot {
            let mine = snap.sessions.filter { $0.agent == a.id }
            if let err = snap.issues[a.id] { parts.append("读取出错：\(err)") }
            else { parts.append("\(mine.filter { !$0.ended }.count) 个进行中") }
        }
        if parts.isEmpty { parts.append((p as NSString).abbreviatingWithTildeInPath) }
        if !a.enabled { parts.append("已在菜单里关闭") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(icon: "checklist", color: Palette.accent, title: "检查一下环境",
                       subtitle: "灵动岛会读取这台 Mac 上已安装的 AI 编程助手的本地状态。至少有一个是绿色就可以继续。")
            VStack(spacing: 6) {
                ForEach(s.env.agents, id: \.id) { a in
                    StatusRow(ok: a.dataPath != nil ? true : nil, title: a.name, detail: detail(a))
                }
                StatusRow(ok: s.env.inApplications ? true : nil, title: "安装位置",
                          detail: s.env.inApplications ? "已在「应用程序」文件夹里" : "现在是从「\(folderName)」运行的。移到「应用程序」后，开机自启和权限都更稳定。") {
                    if !s.env.inApplications {
                        Button("移到应用程序") { s.moveToApplications() }.buttonStyle(FilledButton())
                    }
                }
            }
            MessageLine(text: s.message)
            Button {
                s.refresh()
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.link)
        }
    }
}

// MARK: 3 辅助功能

/// 示意「系统设置 → 隐私与安全性 → 辅助功能」里要打开的那一行
struct SettingsRowMock: View {
    let on: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
            Text(appName).font(.system(size: 13))
            Spacer()
            TimelineView(.animation(minimumInterval: 1 / 20, paused: on || reduceMotion)) { ctx in
                let k = on || reduceMotion ? 0 : breathe(ctx.date, 1.4)
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Palette.green : Color.secondary.opacity(0.3)).frame(width: 38, height: 22)
                    Circle().fill(Color.white).frame(width: 18, height: 18).padding(2).shadow(color: .black.opacity(0.2), radius: 1)
                }
                .overlay(Capsule().stroke(Palette.wait, lineWidth: 2).padding(-4).opacity(on ? 0 : 0.35 + 0.65 * k))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }
}

struct NumberedStep: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Palette.accent))
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PermissionPage: View {
    @ObservedObject var s: OnboardingState

    var body: some View {
        let on = s.env.axTrusted
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(icon: "hand.raised.fill", color: Palette.wait, title: "开启「辅助功能」权限",
                       subtitle: "点灵动岛上的某条对话时，要替你在助手的侧栏里点中那一条（或把对应的终端窗口提到最前）。macOS 规定这类操作必须先经过你授权。")
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 15, weight: .semibold))
                Text(on ? "已开启，点对话可以直达了" : "还没开启（打开后这里会自动变绿）")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(on ? Palette.green : Palette.wait)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill((on ? Palette.green : Palette.wait).opacity(0.12)))
            .animation(.easeOut(duration: 0.2), value: on)
            if !on {
                VStack(alignment: .leading, spacing: 9) {
                    NumberedStep(n: 1, text: "点下面的「打开系统设置」。如果先弹出提示框，选「打开系统设置」。")
                    NumberedStep(n: 2, text: "在「辅助功能」列表里找到「\(appName)」，打开右边的开关（可能要输入开机密码）。")
                    NumberedStep(n: 3, text: "回到这里，状态会自动变成「已开启」。")
                }
            }
            SettingsRowMock(on: on)
            if !on {
                Button {
                    Env.requestAccessibility()
                } label: {
                    Label("打开系统设置", systemImage: "gearshape").frame(minWidth: 140)
                }
                .buttonStyle(FilledButton(color: Palette.wait))
                Text("列表里没有？点列表下方的「+」，在「应用程序」里选 \(appName)。开关已打开但这里没变绿？把开关关掉再打开一次。")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("这个权限只用来点助手侧栏里的对话、切换终端窗口，不读取你的输入，也不看屏幕内容。")
                    .font(.system(size: 11.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: 4 开机自启

struct LoginPage: View {
    @ObservedObject var s: OnboardingState

    var statusText: String {
        switch s.env.loginItem {
        case "enabled": return "当前：已开启"
        case "requiresApproval": return "当前：等你在「系统设置 → 通用 → 登录项」里允许"
        default: return "当前：未开启"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "power", color: Palette.green, title: "开机自动启动",
                       subtitle: "灵动岛很轻：只在本机每 2 秒读一次对话状态。建议开机就启动，省得每次手动打开。")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录 Mac 时自动启动 \(appName)").font(.system(size: 13, weight: .semibold))
                    Text(statusText).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $s.wantLogin).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            if s.env.loginItem == "requiresApproval" {
                Button("打开登录项设置") { Env.openSettings(Env.loginItemsURL) }.buttonStyle(FilledButton(prominent: false))
            }
            Text("点「下一步」时生效，以后可以在菜单栏图标里随时改。")
                .font(.system(size: 11.5)).foregroundColor(.secondary)
            MessageLine(text: s.message)
        }
    }
}

// MARK: 5 完成

struct DonePage: View {
    @ObservedObject var s: OnboardingState

    func chip(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(text)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundColor(ok ? Palette.green : Palette.wait)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill((ok ? Palette.green : Palette.wait).opacity(0.12)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "checkmark.seal.fill", color: Palette.green, title: "设置好了",
                       subtitle: "灵动岛已经在刘海上待命。有对话在跑时，刘海两侧会出现旋转光环和进度小点。")
            HStack(spacing: 8) {
                chip(!s.env.detected.isEmpty, s.env.detected.isEmpty ? "还没找到助手数据" : "已连接 \(s.env.detected.count) 个助手")
                chip(s.env.axTrusted, s.env.axTrusted ? "辅助功能已开启" : "辅助功能未开启")
                chip(s.env.loginItem == "enabled", s.env.loginItem == "enabled" ? "开机自启" : "未开机自启")
            }
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "cursorarrow.motionlines", title: "鼠标移到刘海上", detail: "展开对话列表；点一行跳回那条对话，已结束的可以悬停点 × 清掉。")
                FeatureRow(icon: "bell.badge", title: "自动提醒", detail: "对话完成、等你回答、出错时自动弹出；两指上滑可以收起。")
                FeatureRow(icon: "menubar.rectangle", title: "菜单栏图标", detail: "看全部对话、选择要显示哪些助手、静音、开机自启、重新打开这个引导、卸载。")
            }
            Button {
                s.demo()
            } label: {
                Label("试一下：在刘海弹一张示例卡片", systemImage: "sparkles")
            }
            .buttonStyle(FilledButton(prominent: false))
        }
    }
}
