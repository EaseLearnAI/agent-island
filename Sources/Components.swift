// Small building blocks: spinner, state badge, phrase ticker, notch shape, buttons…
import AppKit
import SwiftUI

// MARK: - Spinner (drawn in code, no bundled artwork)

/// A rotating arc with a pulsing core. running: spins; waiting: half speed; stopped: frozen first frame.
struct SpinnerView: View {
    var size: CGFloat = 20
    var playing = true
    var speed: Double = 1
    var color: Color = Palette.accent

    var body: some View {
        let play = playing && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !play)) { ctx in
            let t = play ? ctx.date.timeIntervalSinceReferenceDate * speed : 0
            let k = play ? 0.5 - 0.5 * cos(t * 2 * .pi / 1.4) : 0.6
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: max(1.6, size * 0.11))
                Circle()
                    .trim(from: 0, to: 0.62)
                    .stroke(AngularGradient(colors: [color.opacity(0), color, .white.opacity(0.95)], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(224)),
                            style: StrokeStyle(lineWidth: max(1.6, size * 0.11), lineCap: .round))
                    .rotationEffect(.degrees(t * 300))
                Circle()
                    .fill(color)
                    .frame(width: size * (0.22 + 0.1 * k), height: size * (0.22 + 0.1 * k))
                    .opacity(0.55 + 0.45 * k)
            }
            .padding(size * 0.08)
        }
        .frame(width: size, height: size)
    }
}

/// 0…1 的周期相位，给呼吸灯、小点这些用（都走 TimelineView，不用 repeatForever，避免和外层弹簧动画串味）
func phase(_ d: Date, _ period: Double, offset: Double = 0) -> Double {
    let t = d.timeIntervalSinceReferenceDate / period + offset
    return t - floor(t)
}

func breathe(_ d: Date, _ period: Double, offset: Double = 0) -> Double {
    0.5 - 0.5 * cos(phase(d, period, offset: offset) * 2 * .pi)
}

/// Small state badge at the bottom-right of the spinner
struct StateBadge: View {
    let state: String
    var size: CGFloat = 10
    var breathing = false

    var symbol: String {
        switch state {
        case "waiting": return "questionmark"
        case "done": return "checkmark"
        case "failed": return "exclamationmark"
        case "stalled": return "moon.fill"
        default: return "stop.fill"
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !breathing || reduceMotion)) { ctx in
            let k = breathing && !reduceMotion ? breathe(ctx.date, 1.2) : 0
            Image(systemName: symbol)
                .font(.system(size: size * 0.6, weight: .black))
                .foregroundColor(.black)
                .frame(width: size, height: size)
                .background(Circle().fill(stateColor(state)))
                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                .scaleEffect(1 + 0.18 * k)
        }
    }
}

/// Session glyph: spinning while running, slow spinner + orange "?" while waiting, check / cross when ended
struct SessionGlyph: View {
    let state: String
    var size: CGFloat = 22
    var color: Color = Palette.accent

    var body: some View {
        Group {
            switch state {
            case "running":
                SpinnerView(size: size, color: color)
            case "waiting":
                SpinnerView(size: size, speed: 0.5, color: color)
                    .overlay(StateBadge(state: "waiting", size: size * 0.5, breathing: true).offset(x: size * 0.18, y: size * 0.16), alignment: .bottomTrailing)
            case "stalled":
                SpinnerView(size: size, playing: false, color: color)
                    .opacity(0.45)
                    .overlay(StateBadge(state: "stalled", size: size * 0.46).offset(x: size * 0.16, y: size * 0.14), alignment: .bottomTrailing)
            case "done":
                Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.72, weight: .semibold)).foregroundColor(Palette.green)
            case "failed":
                Image(systemName: "xmark.circle.fill").font(.system(size: size * 0.72, weight: .semibold)).foregroundColor(Palette.urgent)
            default:
                Image(systemName: "stop.circle.fill").font(.system(size: size * 0.72, weight: .semibold)).foregroundColor(Palette.muted)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Rotating "thinking" phrases, offset per session; old phrase floats up, new one fades in from below
struct PhraseTicker: View {
    var seed = 0
    var interval: Double = 2.4
    var size: CGFloat = 11
    var shimmer = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { ctx in
            let i = (Int(ctx.date.timeIntervalSinceReferenceDate / interval) + seed * 5) % thinkingPhrases.count
            ZStack(alignment: .leading) {
                Text(thinkingPhrases[i])
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize()
                    .modifier(Shimmer(active: shimmer))
                    .id(i)
                    .transition(.asymmetric(
                        insertion: AnyTransition.offset(y: 8).combined(with: .opacity).combined(with: .modifier(active: BlurFade(radius: 3), identity: BlurFade(radius: 0))),
                        removal: AnyTransition.offset(y: -8).combined(with: .opacity)
                    ))
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: i)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// A highlight sweeping across the text
struct Shimmer: ViewModifier {
    var active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if !active || reduceMotion {
            content
        } else {
            content.overlay(
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    GeometryReader { g in
                        let p = phase(ctx.date, 1.8)
                        LinearGradient(colors: [.clear, Palette.accent.opacity(0.95), .white, Palette.accent.opacity(0.95), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.55)
                            .offset(x: (p * 1.9 - 0.6) * g.size.width)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            )
        }
    }
}

/// 收起态右边：每个活跃会话一个小点（蓝 = 进行中、橙 = 等你、灰 = 没动静），进行中的像波浪一样依次亮
struct SessionDots: View {
    let states: [String]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { ctx in
            HStack(spacing: 3) {
                ForEach(Array(states.prefix(5).enumerated()), id: \.offset) { i, s in
                    let k = reduceMotion ? 1 : breathe(ctx.date, s == "waiting" ? 1.2 : 1.0, offset: s == "running" ? -Double(i) * 0.18 : 0)
                    Circle()
                        .fill(stateColor(s))
                        .frame(width: 5, height: 5)
                        .opacity(s == "stalled" ? 0.6 : 0.45 + 0.55 * k)
                        .scaleEffect(s == "running" ? 0.85 + 0.25 * k : 1)
                }
            }
        }
    }
}

/// 等你回答时岛外面一圈橙色呼吸光
struct WaitingGlow: View {
    let ear: CGFloat
    let bottom: CGFloat
    let size: CGSize
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { ctx in
            let k = reduceMotion ? 0.6 : breathe(ctx.date, 1.6)
            NotchShape(ear: ear, bottom: bottom)
                .fill(Palette.wait)
                .frame(width: size.width + ear * 2, height: size.height)
                .blur(radius: 10)
                .opacity(0.16 + 0.34 * k)
        }
        .allowsHitTesting(false)
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.minY + r.height * 0.9))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        return p
    }
}

/// 完成：外圈先画一圈，再把对勾「写」出来
struct CheckDraw: View {
    var size: CGFloat = 34
    var color: Color = Palette.green
    @State private var p: CGFloat = 0
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16))
            Circle()
                .trim(from: 0, to: p)
                .stroke(color, style: StrokeStyle(lineWidth: max(1.6, size * 0.06), lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape()
                .trim(from: 0, to: p)
                .stroke(color, style: StrokeStyle(lineWidth: max(2, size * 0.08), lineCap: .round, lineJoin: .round))
                .padding(size * 0.3)
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion { p = 1; return }
            withAnimation(.easeOut(duration: 0.55).delay(0.18)) { p = 1 }
        }
    }
}

/// 出错：红圈带一下左右抖
struct FailMark: View {
    var size: CGFloat = 34
    @State private var shake: CGFloat = 0
    var body: some View {
        ZStack {
            Circle().fill(Palette.urgent.opacity(0.16))
            Image(systemName: "exclamationmark").font(.system(size: size * 0.45, weight: .black)).foregroundColor(Palette.urgent)
        }
        .frame(width: size, height: size)
        .offset(x: shake)
        .onAppear {
            guard !reduceMotion else { return }
            let steps: [CGFloat] = [5, -4, 3, -2, 0]
            for (i, v) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(i) * 0.06) {
                    withAnimation(.easeInOut(duration: 0.06)) { shake = v }
                }
            }
        }
    }
}

/// 列表里一行一行错开落下
struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -6)
            .blur(radius: shown ? 0 : 3)
            .onAppear {
                if reduceMotion { shown = true; return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8).delay(0.06 + Double(index) * 0.045)) { shown = true }
            }
    }
}

// MARK: - 外形与小组件

/// 刘海外形：顶部两角向外翻（耳朵），底部大圆角
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, e = ear
        let b = max(0, min(bottom, h / 2, (w - 2 * e) / 2))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: e, y: e), control: CGPoint(x: e, y: 0))
        p.addLine(to: CGPoint(x: e, y: h - b))
        p.addQuadCurve(to: CGPoint(x: e + b, y: h), control: CGPoint(x: e, y: h))
        p.addLine(to: CGPoint(x: w - e - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - e, y: h - b), control: CGPoint(x: w - e, y: h))
        p.addLine(to: CGPoint(x: w - e, y: e))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - e, y: 0))
        p.closeSubpath()
        return p
    }
}

struct BlurFade: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// 先长形状、再让内容带一点模糊淡入；收起时内容先消失
    static var island: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.opacity
                .combined(with: .modifier(active: BlurFade(radius: 6), identity: BlurFade(radius: 0)))
                .combined(with: .scale(scale: 0.96, anchor: .top))
                .animation(.easeOut(duration: 0.24).delay(0.08)),
            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.1))
        )
    }

    /// 收起态里换内容（进行中 → 等你 → 完成）：模糊缩放淡入淡出
    static var morph: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.opacity
                .combined(with: .modifier(active: BlurFade(radius: 4), identity: BlurFade(radius: 0)))
                .combined(with: .scale(scale: 0.8, anchor: .leading))
                .animation(.spring(response: 0.36, dampingFraction: 0.75).delay(0.05)),
            removal: AnyTransition.opacity
                .combined(with: .modifier(active: BlurFade(radius: 4), identity: BlurFade(radius: 0)))
                .animation(.easeIn(duration: 0.12))
        )
    }
}

struct Chip: View {
    let text: String
    var color: Color = .white.opacity(0.55)
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.09)))
    }
}

/// 横幅底部的等宽操作按钮
struct ActionButton: View {
    let title: String
    var fill: Color = Color.white.opacity(0.1)
    var fg: Color = .white
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(fg)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

struct IconButton: View {
    let name: String
    var enabled = true
    var size: CGFloat = 11.5
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(.white.opacity(!enabled ? 0.2 : hover ? 0.95 : 0.55))
            .frame(width: 24, height: 22)
            .background(Circle().fill(Color.white.opacity(hover && enabled ? 0.12 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if enabled { action() } }
    }
}

struct ProgressRing: View {
    let value: Double
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}

/// 紧急时呼吸闪烁的图标
struct PulseIcon: View {
    let name: String
    let color: Color
    let pulse: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !pulse || reduceMotion)) { ctx in
            Image(systemName: name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
                .opacity(pulse && !reduceMotion ? 0.3 + 0.7 * breathe(ctx.date, 1.8) : 1)
        }
    }
}

/// 横幅 / 卡片自动收起的倒计时细条；悬停时暂停并回满
struct CountdownBar: View {
    let start: Date
    let total: TimeInterval
    let paused: Bool
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { ctx in
            let left = paused ? 1 : max(0, 1 - ctx.date.timeIntervalSince(start) / max(total, 0.1))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color.opacity(paused ? 0.35 : 0.75)).frame(width: g.size.width * left)
                }
            }
        }
        .frame(height: 2)
    }
}

struct HoverRow<C: View>: View {
    var radius: CGFloat = 12
    var base: Color = .clear
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> C
    @State private var hover = false
    var body: some View {
        content(hover)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hover ? Color.white.opacity(0.09) : base))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .onTapGesture(perform: action)
    }
}
