// Island views: compact (both sides of the notch) / state cards / hover list
import AppKit
import SwiftUI

struct IslandView: View {
    @ObservedObject var m: IslandModel
    /// 展开有一点回弹
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)

    var body: some View {
        let size = m.size
        let ear = m.earRadius
        let expanded = [.flash, .list].contains(m.mode)
        let glow = m.waiting > 0 && (m.mode == .compact || (m.mode == .flash && m.flash?.kind == "waiting"))
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if glow {
                    WaitingGlow(ear: ear, bottom: m.bottomRadius, size: size).transition(.opacity)
                }
                NotchShape(ear: ear, bottom: m.bottomRadius)
                    .fill(Color.black)
                    .frame(width: size.width + ear * 2, height: size.height)
                    .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 24, y: 8)
                content
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: m.bottomRadius, bottomTrailingRadius: m.bottomRadius, style: .continuous))
            }
            // 数量变了：横向挤一下再弹回（锚在刘海上沿）
            .scaleEffect(x: m.bump ? 1.06 : 1, y: m.bump ? 1.1 : 1, anchor: .top)
            .opacity(m.mode == .idle && !m.hasNotch ? 0 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: m.mode)
        .animation(spring, value: size)
        .animation(spring, value: m.flash?.id)
        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: m.bump)
        .animation(.easeInOut(duration: 0.3), value: glow)
    }

    @ViewBuilder var content: some View {
        switch m.mode {
        case .idle: Color.clear
        case .compact: compact.transition(.island)
        case .flash: if let f = m.flash { flashView(f).id(f.id).transition(.island) }
        case .list: list.transition(.island)
        }
    }

    func side(_ width: CGFloat) -> CGFloat { (width - m.notch.width) / 2 - 26 }

    // MARK: 收起态：刘海两侧

    var compact: some View {
        let kind = m.compactKind ?? .running
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                compactIcon(kind).frame(width: 20, height: 20)
                compactLabel(kind)
            }
            .id(kindKey(kind))
            .transition(.morph)
            .padding(.leading, 13)
            .frame(width: m.wing, alignment: .leading)
            Spacer(minLength: m.notch.width)
            compactRight(kind)
                .padding(.trailing, 13)
                .frame(width: m.wing, alignment: .trailing)
        }
        .frame(height: m.notch.height)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: kindKey(kind))
        .contentShape(Rectangle())
        .onTapGesture { m.setMode(.list) }
    }

    func kindKey(_ k: CompactKind) -> String {
        switch k {
        case .waiting: return "waiting"
        case .running: return "running"
        case .stalled: return "stalled"
        case .finished(let ok): return ok ? "done" : "failed"
        }
    }

    @ViewBuilder func compactIcon(_ k: CompactKind) -> some View {
        switch k {
        case .waiting: SessionGlyph(state: "waiting", size: 20, color: m.activeSessions.first?.agentColor ?? Palette.accent)
        case .running: SpinnerView(size: 20, color: m.activeSessions.first(where: { $0.state == "running" })?.agentColor ?? Palette.accent)
        case .stalled: SessionGlyph(state: "stalled", size: 20)
        case .finished(let ok):
            if ok { CheckDraw(size: 18) } else { FailMark(size: 18) }
        }
    }

    @ViewBuilder func compactLabel(_ k: CompactKind) -> some View {
        let font = Font.system(size: 11, weight: .semibold)
        switch k {
        case .waiting:
            Text(m.waiting > 1 ? "\(m.waiting) 个等你回答" : "等你回答").font(font).foregroundColor(Palette.wait).lineLimit(1)
        case .running:
            PhraseTicker()
        case .stalled:
            Text("没动静了").font(font).foregroundColor(.white.opacity(0.5)).lineLimit(1)
        case .finished(let ok):
            Text(ok ? "全部完成" : "出错了").font(font).foregroundColor(ok ? Palette.green : Palette.urgent).lineLimit(1)
        }
    }

    @ViewBuilder func compactRight(_ k: CompactKind) -> some View {
        switch k {
        case .waiting, .running, .stalled:
            let active = m.activeSessions
            HStack(spacing: 6) {
                SessionDots(states: active.map(\.state))
                Text("\(active.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .contentTransition(.numericText())
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: active.count)
        case .finished:
            if let p = m.recentEnd?.project {
                Text(p).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // 顶部一行（和刘海同高），中间让出刘海
    func topBar<L: View, R: View>(width: CGFloat? = nil, @ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        let s = side(width ?? m.wide)
        return HStack(spacing: 0) {
            left().frame(width: s, alignment: .leading)
            Spacer(minLength: 0)
            right().frame(width: s, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: m.notch.height)
    }

    var muteButton: some View {
        IconButton(name: m.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { m.muted.toggle() }
    }

    // MARK: 会话卡片（状态变化时弹出）

    func flashView(_ f: Flash) -> some View {
        let s = f.session
        let color = stateColor(f.kind)
        let headline = f.kind == "done" ? "完成了" : f.kind == "waiting" ? "等你回答" : "出错了"
        let icon = f.kind == "done" ? "checkmark" : f.kind == "waiting" ? "questionmark" : "exclamationmark"
        let sub: String = {
            switch f.kind {
            case "waiting": return s.question ?? "有个问题需要你确认"
            case "failed": return "运行中断了，点开看看原因"
            default: return [s.agentShort, s.project].compactMap { $0 }.joined(separator: " · ") + " · 刚刚跑完"
            }
        }()
        return VStack(spacing: 0) {
            topBar(width: m.flashWidth) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 9.5, weight: .black))
                    Text(headline).font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(color)
            } right: {
                HStack(spacing: 5) {
                    Circle().fill(s.agentColor).frame(width: 7, height: 7)
                    Text(s.agentShort).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.55))
                }
            }
            HStack(spacing: 12) {
                Group {
                    switch f.kind {
                    case "done": CheckDraw(size: 36)
                    case "failed": FailMark(size: 36)
                    default:
                        ZStack {
                            Circle().fill(Palette.wait.opacity(0.14))
                            SessionGlyph(state: "waiting", size: 28, color: s.agentColor)
                        }
                        .frame(width: 36, height: 36)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        if f.kind == "waiting", let p = s.project { Chip(text: p).fixedSize() }
                    }
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundColor(f.kind == "waiting" ? .white.opacity(0.75) : .white.opacity(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(f.kind == "waiting" ? "去回答" : "打开")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(color))
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            Spacer(minLength: 0)
            CountdownBar(start: m.flashStart, total: m.flashTotal, paused: m.flashPaused, color: color)
                .padding(.horizontal, 34)
                .padding(.bottom, 7)
        }
        .contentShape(Rectangle())
        .onTapGesture { m.tapFlash() }
    }

    // MARK: 悬停展开：会话列表

    var list: some View {
        VStack(spacing: 0) {
            topBar {
                // 顶栏左边只有 ~120pt：用「数字 + 色点」，不写长文案
                HStack(spacing: 7) {
                    if !m.online {
                        Text("未找到数据").foregroundColor(Palette.urgent.opacity(0.85))
                    } else {
                        SpinnerView(size: 14, playing: m.running > 0)
                        if m.running == 0 && m.waiting == 0 && m.stalled == 0 {
                            Text("都歇着").foregroundColor(.white.opacity(0.45))
                        } else {
                            if m.running > 0 { countDot(m.running, Palette.accent, "进行中") }
                            if m.waiting > 0 { countDot(m.waiting, Palette.wait, "等你回答") }
                            if m.stalled > 0 { countDot(m.stalled, .white.opacity(0.45), "没动静") }
                        }
                    }
                }
                .fixedSize()
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
            } right: {
                HStack(spacing: 2) {
                    muteButton
                    IconButton(name: "xmark.circle", enabled: m.hasEnded) { m.clearEnded() }
                        .help("清除已结束的会话")
                    IconButton(name: "arrow.up.right.square") { m.openAgent(); m.settle() }
                        .help("打开 \(m.live.first?.agentInfo?.name ?? "AI 助手")")
                }
            }
            VStack(spacing: 0) {
                if m.liveRows.isEmpty {
                    emptyRow
                } else {
                    // 最多露出 4 行，多出来的会话在这块区域里上下滚动
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(m.live.enumerated()), id: \.element.id) { i, s in
                                sessionRow(s, i).modifier(StaggerIn(index: min(i, 4)))
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: CGFloat(m.liveRows.count) * IslandModel.sessionH)
                    .mask(
                        LinearGradient(
                            stops: m.listScrollable
                                ? [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .black.opacity(0.25), location: 1)]
                                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                            startPoint: .top, endPoint: .bottom)
                    )
                    Color.clear.frame(height: 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            footer
            Spacer(minLength: 0)
        }
    }

    func countDot(_ n: Int, _ c: Color, _ help: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text("\(n)").foregroundColor(c)
        }
        .help("\(n) 个\(help)")
    }

    /// Session row: click to jump to the session in its agent; ended rows can be dismissed from the island on hover
    func sessionRow(_ s: LiveSession, _ index: Int) -> some View {
        let color = stateColor(s.state)
        let accent = s.state == "waiting" || s.state == "failed"
        return HoverRow(radius: 12, base: .white.opacity(0.045), action: { m.openSession(s); m.settle() }) { hover in
            HStack(spacing: 10) {
                SessionGlyph(state: s.state, size: 22, color: s.agentColor)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(s.ended ? 0.62 : 0.95))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(s.agentShort)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(s.agentColor)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(s.agentColor.opacity(0.16)))
                            .fixedSize()
                        if let p = s.project {
                            Text(p).foregroundColor(.white.opacity(0.42)).lineLimit(1).fixedSize()
                        }
                        if s.state == "running" {
                            Text("·").foregroundColor(.white.opacity(0.25))
                            PhraseTicker(seed: index + 1, interval: 2.8, size: 11, shimmer: false).opacity(0.7)
                        } else if s.state == "waiting" {
                            Text("·").foregroundColor(.white.opacity(0.25))
                            Text(s.question ?? "等你确认").foregroundColor(Palette.wait.opacity(0.92)).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(stateName(s.state))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(color)
                        .padding(.horizontal, 7)
                        .frame(height: 17)
                        .background(Capsule().fill(color.opacity(0.14)))
                    HStack(spacing: 3) {
                        if hover {
                            Text(s.state == "waiting" ? "去回答" : "打开对话")
                            Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .bold))
                        } else {
                            Text(timeAgoMs(s.updatedAt))
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(hover ? 0.75 : 0.32))
                }
                .fixedSize()
                if s.ended {
                    IconButton(name: "xmark", size: 9.5) { withAnimation(.easeOut(duration: 0.2)) { m.dismiss(s) } }
                        .opacity(hover ? 1 : 0)
                        .help("从灵动岛清除（不影响助手里的对话）")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, s.ended ? 4 : 12)
            .frame(height: IslandModel.sessionH - IslandModel.sessionGap)
            .overlay(alignment: .leading) {
                if accent {
                    Capsule().fill(color).frame(width: 3, height: 22).offset(x: 1.5)
                }
            }
        }
        .padding(.bottom, IslandModel.sessionGap)
    }

    var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: m.online ? "moon.zzz.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(m.online ? .white.opacity(0.35) : Palette.urgent.opacity(0.85))
            Text(m.online ? "没有进行中的对话，30 分钟内也没有刚结束的" : (m.error ?? "没找到任何支持的 AI 编程助手数据"))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: IslandModel.emptyH)
    }

    var footer: some View {
        HStack(spacing: 8) {
            if !m.axTrusted {
                // without Accessibility, clicking a session can only bring the app to the front: suggest enabling it
                HoverRow(radius: 11, base: Palette.wait.opacity(0.12), action: { m.onNeedPermission?(); m.settle() }) { hover in
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .bold))
                        Text("开启辅助功能，点对话直达")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.wait.opacity(hover ? 1 : 0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                }
                .fixedSize()
            } else {
                Text(m.live.isEmpty ? "\(m.agentCount) 个助手 · 会话实时状态" : "\(m.live.count) 个对话 · 进行中和 30 分钟内结束的")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HoverRow(radius: 13, base: .white.opacity(0.1), action: { m.openAgent(); m.settle() }) { hover in
                HStack(spacing: 4) {
                    Text("打开 \(m.live.first?.agentInfo?.short ?? "助手")")
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(hover ? 1 : 0.85))
                .padding(.horizontal, 12)
                .frame(height: 26)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: IslandModel.footerH)
    }
}
