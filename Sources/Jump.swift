// Click a session → jump to it in its agent.
// None of the supported desktop apps exposes a "open session <id>" deeplink, so for desktop apps we use
// Accessibility (AX): find the sidebar row whose label equals the session title and press it.
// CLI sessions (Claude Code / Codex in a terminal) raise the terminal or editor window whose title mentions the project.
// Without Accessibility permission we just bring the app to the front.
import AppKit
import ApplicationServices

enum AgentJump {
    static let queue = DispatchQueue(label: "agent-island.jump")
    static var busy = false
    /// Called when Accessibility permission is missing (opens the onboarding permission page)
    static var onNeedPermission: (() -> Void)?
    /// Self-test: don't switch apps, only remember where we would go
    static var dryRun = false
    static var lastTarget: String?
    /// apps whose web content AX tree was already switched on
    static var warmed = Set<pid_t>()

    /// Electron apps only build their accessibility tree after AXManualAccessibility is set, which takes a few
    /// seconds the first time. Do it ahead of the first click for every running desktop agent.
    static func warmUp() {
        guard AXIsProcessTrusted() else { return }
        for s in Agents.all {
            for app in AppLocator.running(s.info) where !warmed.contains(app.processIdentifier) {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                warmed.insert(app.processIdentifier)
            }
        }
    }

    static func norm(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Open an agent app without a specific session (falls back to the first installed desktop agent).
    static func openApp(_ agent: String?) {
        let infos = ([agent].compactMap { $0 }.compactMap(Agents.info)) + Agents.all.map(\.info)
        for info in infos {
            if let app = AppLocator.running(info).first { bringFront(app); return }
            if let url = AppLocator.installed(info) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    static func open(_ s: LiveSession) {
        guard let info = Agents.info(s.agent) else { return }
        let title = norm(s.fullTitle ?? s.title ?? "")
        DispatchQueue.main.async {
            guard !busy else { return }
            busy = true
            let trusted = AXIsProcessTrusted()
            let viaTerminal = info.cli && s.host != "app"
            if dryRun {
                lastTarget = viaTerminal ? "terminal:\(s.project ?? "")" : (AppLocator.running(info).first?.bundleURL ?? AppLocator.installed(info))?.path
                busy = false
                if !trusted && !title.isEmpty { onNeedPermission?() }
                return
            }
            if viaTerminal {
                openTerminal(s, trusted: trusted)
                busy = false
                return
            }
            let running = AppLocator.running(info)
            if running.isEmpty {
                if let url = AppLocator.installed(info) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            } else {
                bringFront(running[0])
            }
            guard !title.isEmpty else { busy = false; return }
            guard trusted else {
                busy = false
                onNeedPermission?()
                return
            }
            let cold = running.isEmpty || running.contains { !warmed.contains($0.processIdentifier) }
            warmUp()
            queue.async {
                // a freshly launched / never-warmed Electron app needs a few seconds before its web content shows up in the AX tree
                let deadline = Date().addingTimeInterval(running.isEmpty ? 12 : cold ? 8 : 3)
                var expanded = Set<pid_t>()
                var hit = false
                repeat {
                    for app in AppLocator.running(info) {
                        let ax = AXUIElementCreateApplication(app.processIdentifier)
                        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                        if info.id == "mcode" {
                            var ex = expanded.contains(app.processIdentifier)
                            if let el = MCodeSidebar.find(ax, title: title, ws: s.ws, expanded: &ex) {
                                hit = AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
                            }
                            if ex { expanded.insert(app.processIdentifier) }
                        } else {
                            hit = GenericSidebar.press(ax, title: title)
                        }
                        if hit { break }
                    }
                    if hit { break }
                    Thread.sleep(forTimeInterval: 0.4)
                } while Date() < deadline
                DispatchQueue.main.async {
                    print("jump: \(info.id) \(hit ? "hit" : "miss") · \(title.prefix(40))")
                    fflush(stdout)
                    busy = false
                }
            }
        }
    }

    /// Bring to front; if the window was closed / minimized, openApplication brings the main window back
    static func bringFront(_ app: NSRunningApplication) {
        app.unhide()
        app.activate()
        if let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: CLI sessions

    /// Raise the terminal / editor window that mentions the project folder; otherwise the first running terminal.
    static func openTerminal(_ s: LiveSession, trusted: Bool) {
        let ids = s.host == "editor" ? AppLocator.editorHosts + AppLocator.terminalHosts : AppLocator.terminalHosts
        let apps = ids.flatMap { id in NSRunningApplication.runningApplications(withBundleIdentifier: id) }
        guard !apps.isEmpty else { return }
        let needles = [s.project, s.agentInfo?.short.lowercased()].compactMap { $0 }.filter { !$0.isEmpty }
        if trusted {
            for app in apps {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                let windows = (AX.attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
                for w in windows {
                    let t = ((AX.attr(w, kAXTitleAttribute) as? String) ?? "").lowercased()
                    if needles.contains(where: { t.contains($0.lowercased()) }) {
                        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                        app.activate()
                        lastTarget = "terminal:\(app.bundleIdentifier ?? "")"
                        return
                    }
                }
            }
        }
        apps[0].activate()
    }
}

enum AX {
    static func attr(_ e: AXUIElement, _ k: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, k as CFString, &v)
        return v
    }

    static func label(_ e: AXUIElement) -> String {
        for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = attr(e, k) as? String, !s.isEmpty { return s }
        }
        return ""
    }

    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return (names as? [String]) ?? []
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func parent(_ e: AXUIElement) -> AXUIElement? {
        guard let p = attr(e, kAXParentAttribute) else { return nil }
        return (p as! AXUIElement)
    }

    /// Real mouse click at the element center (for web rows that don't expose AXPress)
    static func click(_ r: CGRect) {
        let pt = CGPoint(x: r.midX, y: r.midY)
        let src = CGEventSource(stateID: .hidSystemState)
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}

/// Any Electron / native agent app: find an element whose label matches the session title, prefer the left-most one
/// (the sidebar), press it or its nearest pressable ancestor; if nothing is pressable, click it.
enum GenericSidebar {
    struct Hit { let el: AXUIElement; let x: CGFloat }

    static func matches(_ label: String, _ title: String) -> Bool {
        let l = AgentJump.norm(label)
        guard !l.isEmpty else { return false }
        if l == title { return true }
        // truncated rows: "Fix the login bug in…" vs full title
        let core = l.hasSuffix("…") ? String(l.dropLast()) : l.hasSuffix("...") ? String(l.dropLast(3)) : l
        return core.count >= 8 && (title.hasPrefix(core) || core.hasPrefix(title))
    }

    static func press(_ app: AXUIElement, title: String) -> Bool {
        var hits: [Hit] = []
        var visited = 0
        let windows = (AX.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows { walk(w, title: title, hits: &hits, visited: &visited, depth: 0) }
        for h in hits.sorted(by: { $0.x < $1.x }) {
            var el: AXUIElement? = h.el
            for _ in 0..<6 {
                guard let e = el else { break }
                if AX.actions(e).contains(kAXPressAction as String), AXUIElementPerformAction(e, kAXPressAction as CFString) == .success {
                    return true
                }
                el = AX.parent(e)
            }
            if let r = AX.frame(h.el), r.width > 0 {
                AX.click(r)
                return true
            }
        }
        return false
    }

    static func walk(_ e: AXUIElement, title: String, hits: inout [Hit], visited: inout Int, depth: Int) {
        guard depth < 50, visited < 8000 else { return }
        visited += 1
        let label = AX.label(e)
        if label.count <= 400, matches(label, title) {
            hits.append(Hit(el: e, x: AX.frame(e)?.minX ?? .greatestFiniteMagnitude))
            return
        }
        for k in (AX.attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(k, title: title, hits: &hits, visited: &visited, depth: depth + 1)
        }
    }
}

/// MiniMax Code sidebar: project headers (class "group/project-header", label "name, /abs/path") are siblings of
/// their session rows (class "mavis-sidebar-item"), so the project scope is passed along sibling order; collapsed
/// projects are expanded once via their "More" row.
enum MCodeSidebar {
    struct Hit { let el: AXUIElement; let scope: String }

    static func find(_ ax: AXUIElement, title: String, ws: String?, expanded: inout Bool) -> AXUIElement? {
        var hits: [Hit] = [], more: [Hit] = []
        walk(ax, scope: "", title: title, hits: &hits, more: &more)
        if pick(hits, ws) == nil, !more.isEmpty, !expanded {
            expanded = true
            let scoped = more.filter { ws != nil && $0.scope == ws }
            for m in scoped.isEmpty ? more : scoped { AXUIElementPerformAction(m.el, kAXPressAction as CFString) }
            Thread.sleep(forTimeInterval: 0.35)
            hits = []; more = []
            walk(ax, scope: "", title: title, hits: &hits, more: &more)
        }
        return pick(hits, ws)?.el
    }

    static func pick(_ hits: [Hit], _ ws: String?) -> Hit? {
        if let ws, let h = hits.first(where: { $0.scope == ws }) { return h }
        return hits.first
    }

    static func label(_ e: AXUIElement) -> String {
        let t = (AX.attr(e, "AXTitle") as? String) ?? ""
        return t.isEmpty ? ((AX.attr(e, "AXDescription") as? String) ?? "") : t
    }

    static func walk(_ e: AXUIElement, scope: String, title: String, hits: inout [Hit], more: inout [Hit], depth: Int = 0) {
        guard depth < 60 else { return }
        var scope = scope
        for k in (AX.attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
            let cls = (AX.attr(k, "AXDOMClassList") as? [String]) ?? []
            if cls.contains("mavis-sidebar-item") {
                let l = label(k)
                if cls.contains("group/project-header") {
                    if let r = l.range(of: ", /") { scope = String(l[l.index(after: r.lowerBound)...]).trimmingCharacters(in: .whitespaces) }
                } else if l == "更多" || l == "More" {
                    more.append(Hit(el: k, scope: scope))
                } else if AgentJump.norm(l) == title {
                    hits.append(Hit(el: k, scope: scope))
                }
                continue
            }
            walk(k, scope: scope, title: title, hits: &hits, more: &more, depth: depth + 1)
        }
    }
}
