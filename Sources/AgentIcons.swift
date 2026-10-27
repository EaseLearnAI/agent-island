// Agent icons — one standard resolution chain for every agent, used by every surface (rows, cards, menus, onboarding):
//   1. user override   ~/Library/Application Support/AgentIsland/icons/<agent id>.png (or AGENT_ISLAND_ICON_DIR)
//   2. installed app   the icon of the agent's own app on this Mac (desktop app, or a helper app it ships)
//   3. downloaded      fetched on request from the project's own GitHub (menu "下载缺失的助手图标", --fetch-icons)
//   4. monogram        a rounded square in the agent's colour with its initials
// No third-party logo is bundled in this repository or the app.
import AppKit
import SwiftUI

struct IconInfo: Codable, Equatable {
    let agent: String
    let source: String   // override / app / monogram
    let path: String?
}

enum AgentIcons {
    private static var cache: [String: (NSImage, IconInfo)] = [:]
    private static let lock = NSLock()

    static var overrideDir: String {
        if let d = ProcessInfo.processInfo.environment["AGENT_ISLAND_ICON_DIR"], !d.isEmpty { return d }
        return NSHomeDirectory() + "/Library/Application Support/AgentIsland/icons"
    }

    /// App bundle that provides the icon: the agent's desktop app, else a helper app listed in iconApps.
    static func iconApp(_ info: AgentInfo) -> URL? {
        if ProcessInfo.processInfo.environment["AGENT_ISLAND_NO_APP_ICONS"] == "1" { return nil }
        if let u = AppLocator.installed(info), hasOwnIcon(u) { return u }
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for n in Files.list(dir) where n.hasSuffix(".app") && info.iconApps.contains(where: { n.hasPrefix($0) }) {
                let u = URL(fileURLWithPath: dir).appendingPathComponent(n)
                if hasOwnIcon(u) { return u }
            }
        }
        return nil
    }

    /// Helper apps without an icon would show the generic app icon — skip them
    static func hasOwnIcon(_ app: URL) -> Bool {
        let d = Bundle(url: app)?.infoDictionary
        return d?["CFBundleIconFile"] != nil || d?["CFBundleIconName"] != nil
    }

    static func resolve(_ id: String) -> (NSImage, IconInfo) {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[id] { return c }
        let info = Agents.info(id)
        var out: (NSImage, IconInfo)
        let custom = overrideDir + "/\(id).png"
        if Files.exists(custom), let img = NSImage(contentsOfFile: custom) {
            out = (img, IconInfo(agent: id, source: "override", path: custom))
        } else if let info, let app = iconApp(info) {
            out = (NSWorkspace.shared.icon(forFile: app.path), IconInfo(agent: id, source: "app", path: app.path))
        } else if Files.exists(IconFetcher.path(id)), let img = NSImage(contentsOfFile: IconFetcher.path(id)) {
            out = (img, IconInfo(agent: id, source: "downloaded", path: IconFetcher.path(id)))
        } else {
            out = (monogram(info), IconInfo(agent: id, source: "monogram", path: nil))
        }
        cache[id] = out
        return out
    }

    static func image(_ id: String) -> NSImage { resolve(id).0 }
    static func info(_ id: String) -> IconInfo { resolve(id).1 }

    /// Agents that currently fall back to a monogram and have an official icon source
    static func missing() -> [String] {
        Agents.all.filter { !$0.info.iconURLs.isEmpty && info($0.info.id).source == "monogram" }.map(\.info.id)
    }

    /// Forget cached icons (an app was installed / an override was added)
    static func reload() { lock.lock(); cache.removeAll(); lock.unlock() }

    /// 16 pt copy for NSMenuItem.image
    static func menuImage(_ id: String) -> NSImage {
        let src = image(id)
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            src.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return img
    }

    static func monogram(_ info: AgentInfo?) -> NSImage {
        let text = info?.monogram ?? "?"
        let color = NSColor(info?.color ?? Palette.accent)
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
            let box = r.insetBy(dx: 10, dy: 10)
            color.setFill()
            NSBezierPath(roundedRect: box, xRadius: box.width * 0.24, yRadius: box.width * 0.24).fill()
            let font = NSFont.systemFont(ofSize: text.count > 1 ? 44 : 60, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2))
            return true
        }
    }

    /// PNG of the resolved icon (for --icons OUT_DIR and tests)
    static func writePNG(_ id: String, to path: String, size: Int = 128) -> Bool {
        let src = image(id)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// The standard agent glyph: the agent's icon + a state decoration.
/// running: a spinning ring around the icon · waiting: breathing "?" badge · stalled / stopped: dimmed + badge ·
/// done: green check badge · failed: red "!" badge
struct AgentAvatar: View {
    let agent: String
    let state: String
    var size: CGFloat = 26

    var body: some View {
        let color = Agents.info(agent)?.color ?? Palette.accent
        let dim = state == "stalled" || state == "stopped"
        ZStack {
            if state == "running" {
                SpinnerRing(size: size, color: color)
            }
            Image(nsImage: AgentIcons.image(agent))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * (state == "running" ? 0.68 : 0.86), height: size * (state == "running" ? 0.68 : 0.86))
                .saturation(dim ? 0.2 : 1)
                .opacity(dim ? 0.55 : 1)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if state != "running" {
                StateBadge(state: state, size: size * 0.44, breathing: state == "waiting")
                    .offset(x: size * 0.1, y: size * 0.08)
            }
        }
        .help(Agents.info(agent)?.name ?? agent)
    }
}

/// Rotating arc only (goes around an icon)
struct SpinnerRing: View {
    var size: CGFloat
    var color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: max(1.5, size * 0.07))
                Circle()
                    .trim(from: 0, to: 0.6)
                    .stroke(AngularGradient(colors: [color.opacity(0), color, .white.opacity(0.95)], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(216)),
                            style: StrokeStyle(lineWidth: max(1.5, size * 0.07), lineCap: .round))
                    .rotationEffect(.degrees(t * 300))
            }
        }
        .frame(width: size, height: size)
    }
}


/// Downloads official icons for agents without a local app icon. Only runs when the user asks.
enum IconFetcher {
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment["AGENT_ISLAND_FETCHED_ICON_DIR"], !d.isEmpty { return d }
        return NSHomeDirectory() + "/Library/Application Support/AgentIsland/icons-downloaded"
    }
    static func path(_ id: String) -> String { dir + "/\(id).png" }

    /// Returns the agent ids that got an icon. all = refresh every agent that has a source, not only missing ones.
    @discardableResult
    static func fetchMissing(all: Bool = false) -> [String] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let targets = all ? Agents.all.filter { !$0.info.iconURLs.isEmpty }.map(\.info.id) : AgentIcons.missing()
        var got: [String] = []
        for id in targets {
            guard let info = Agents.info(id) else { continue }
            for u in info.iconURLs {
                guard let url = URL(string: u), let data = download(url), let img = NSImage(data: data),
                      img.size.width >= 32, save(img, to: path(id)) else { continue }
                got.append(id)
                break
            }
        }
        AgentIcons.reload()
        return got
    }

    static func download(_ url: URL) -> Data? {
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("AgentIsland/\(appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        return result
    }

    /// Normalised 256 px PNG with rounded corners, so square avatars look like app icons
    static func save(_ img: NSImage, to path: String) -> Bool {
        let size = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(roundedRect: r.insetBy(dx: 8, dy: 8), xRadius: 54, yRadius: 54).addClip()
        img.draw(in: r.insetBy(dx: 8, dy: 8), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
