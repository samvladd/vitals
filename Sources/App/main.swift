import AppKit

/// A borderless panel that drops from the menu bar, takes keys for the settings fields and closes
/// on a click elsewhere.
final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil); (NSApp.delegate as? AppDelegate)?.panelClosed() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var links: [HostLink] = []
    private var panel: DropPanel!
    private var dashboard: Dashboard!
    private var settings: SettingsView?
    private var clickMonitor: Any?
    private var historyTimer: Timer?
    private var lastStatusKey = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.migrate()
        links = Prefs.remoteHosts.map(HostLink.remote) + [HostLink(key: "local", sshHost: nil)]
        dashboard = Dashboard(links: links)
        dashboard.onSettings = { [weak self] in self?.showSettings() }
        dashboard.onQuit = { NSApp.terminate(nil) }
        dashboard.onSetup = { [weak self] l in self?.setup(l, remove: false) }
        dashboard.onOpenLogs = { [weak self] in self?.openLogs() }
        dashboard.onHeight = { [weak self] h in if self?.settings == nil { self?.resize(h) } }
        dashboard.selectionChanged = { [weak self] in self?.applyIntervals(); self?.dashboard.link.fetchHistory(); self?.dashboard.needsDisplay = true }

        panel = DropPanel(contentRect: dashboard.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true                      // it floats over other windows: the one place a shadow belongs
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let container = NSView(frame: dashboard.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Theme.line.cgColor
        container.addSubview(dashboard)
        dashboard.autoresizingMask = [.width, .height]
        panel.contentView = container

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly

        for l in links { watch(l) }
        applyIntervals()
        updateStatus()

        // `--render <dir>`: draw the panel to PNG files and quit (for design review).
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            // Settings is made early so the Tailscale suggestions have time to arrive.
            var preview: SettingsView?
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { preview = SettingsView(links: self.links, height: 640) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [self] in
                let (selected, range, menuBar) = (Prefs.selected, Prefs.range, Prefs.menuBar)
                for l in self.links {
                    Prefs.selected = l.key
                    let file = l.key.replacingOccurrences(of: ":", with: "-")
                    for (r, name) in [(1, "1h"), (3, "14d")] {
                        Prefs.range = r
                        self.snapshot(self.dashboard, to: dir.appendingPathComponent("\(file)-\(name).png"))
                    }
                }
                Prefs.range = range; Prefs.selected = selected
                if let s = preview { self.snapshot(s, to: dir.appendingPathComponent("settings.png")) }
                for key in ["all", "local"] {
                    Prefs.menuBar = key
                    self.snapshot(StatusBarPreview(image: StatusRenderer.image(for: self.shownInBar)), to: dir.appendingPathComponent("menubar-\(key).png"))
                }
                Prefs.menuBar = menuBar
                print(StatusRenderer.tooltip(for: self.links))
                NSApp.terminate(nil)
            }
            for l in links { l.interval = 1; l.wantsProcs = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.links.forEach { $0.fetchHistory() } }
        }

        // `--selftest <dir>`: open the real panel from the status item, click through it, save what it shows.
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            var log: [String] = []
            func shot(_ name: String) {
                guard let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            }
            let steps: [(Double, () -> Void)] = [
                (8, { self.item.button?.performClick(nil)
                      // A click in another app would close the panel mid-test; this run ignores them.
                      if let m = self.clickMonitor { NSEvent.removeMonitor(m); self.clickMonitor = nil }
                      log.append("open: visible=\(self.panel.isVisible) frame=\(self.panel.frame) screen=\(self.panel.screen?.visibleFrame ?? .zero)")
                      log.append("intervals: " + self.links.map { "\($0.key)=\($0.interval)" }.joined(separator: " ")) }),
                (3, { shot("1-open") }),
                (0.5, { log.append("tab.local: \(self.dashboard.perform("tab.local"))"); log.append("intervals: " + self.links.map { "\($0.key)=\($0.interval)" }.joined(separator: " ")) }),
                (2, { log.append("range.0: \(self.dashboard.perform("range.0"))"); shot("2-local-10m") }),
                (0.5, { log.append("fan.fixed (true only with fan setup): \(self.dashboard.perform("fan.fixed"))")
                        log.append("fan.auto: \(self.dashboard.perform("fan.auto"))") }),     // and hand the fans straight back
                (0.5, { log.append("settings: \(self.dashboard.perform("foot.settings"))"); shot("3-settings") }),
                (0.5, { log.append("menubar seg local: \(self.settings?.perform("seg.local") ?? false) -> \(Prefs.menuBar)"); Prefs.menuBar = "all" }),
                (0.5, { self.settings?.addField.stringValue = "-oProxyCommand=x"
                        log.append("add invalid (expect false): \(self.settings?.add("-oProxyCommand=x") ?? true)")
                        log.append("add selftest-host: \(self.settings?.add("selftest-host") ?? false) -> " + self.links.map(\.key).joined(separator: " "))
                        shot("4-settings-added") }),
                (1, { log.append("remove selftest-host: \(self.settings?.perform("remove.selftest-host") ?? false) -> " + self.links.map(\.key).joined(separator: " "))
                      log.append("hosts: \(Prefs.remoteHosts)") }),
                (0.5, { log.append("done: \(self.settings?.perform("done") ?? false), settings closed=\(self.settings == nil)") }),
                (0.5, { let last = self.links.last { !$0.isLocal }?.key ?? "local"
                        log.append("tab.\(last): \(self.dashboard.perform("tab.\(last)"))"); shot("5-last-remote")
                        log.append("intervals: " + self.links.map { "\($0.key)=\($0.interval)" }.joined(separator: " ")) }),
                (2, { Prefs.selected = self.links[0].key; Prefs.range = 1; self.dashboard.needsDisplay = true
                        self.item.button?.performClick(nil); log.append("toggle closed: visible=\(self.panel.isVisible)")
                        log.append("intervals: " + self.links.map { "\($0.key)=\($0.interval)" }.joined(separator: " "))
                        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
                        NSApp.terminate(nil) }),
            ]
            var t = 0.0
            for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        }

        // `--bench`: open the panel for 30 s and report the CPU it cost.
        if CommandLine.arguments.contains("--bench") {
            func cpu() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.open(); let c0 = cpu(); Canvas.draws = 0; Canvas.drawTime = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    print(String(format: "open 30 s: cpu %.2f s (%.1f%%), draws %d, draw time %.2f s", cpu() - c0, (cpu() - c0) / 30 * 100, Canvas.draws, Canvas.drawTime))
                    self.close(); let c1 = cpu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        print(String(format: "closed 30 s: cpu %.2f s (%.1f%%)", cpu() - c1, (cpu() - c1) / 30 * 100)); NSApp.terminate(nil)
                    }
                }
            }
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.links.forEach { $0.start() } }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        links.forEach { $0.stop() }                 // closes stdin: each agent hands its fans back to macOS
        usleep(400_000)
    }

    // MARK: hosts

    private func watch(_ l: HostLink) {
        l.onUpdate = { [weak self, weak l] in self?.updated(l) }
        l.start()
    }

    /// After the list changes in Settings: same order as Prefs.remoteHosts, this Mac last. Macs that
    /// stay keep their connection; removed ones are retired (stdin closes, so their agent hands the
    /// fans back), added ones start.
    private func rebuildLinks() {
        let old = links
        let next = Prefs.remoteHosts.map { h in old.first { $0.sshHost == h } ?? HostLink.remote(h) } + old.filter(\.isLocal)
        for l in old where !next.contains(where: { $0 === l }) { l.retire() }
        for l in next where !old.contains(where: { $0 === l }) { watch(l) }
        links = next
        dashboard.links = next
        settings?.links = next
        if !next.contains(where: { $0.key == Prefs.selected }) { Prefs.selected = next[0].key }
        if Prefs.menuBar != "all", !next.contains(where: { $0.key == Prefs.menuBar }) { Prefs.menuBar = "all" }
        lastStatusKey = ""; updateStatus(); applyIntervals()
    }

    // MARK: updates

    private var statusTimer: Timer?

    private func updated(_ l: HostLink?) {
        // The menu bar redraw is the costly part of an update; coalesce it to one per 5 s.
        if statusTimer == nil {
            statusTimer = Timer.scheduledTimer(withTimeInterval: lastStatusKey.isEmpty ? 0.2 : 5, repeats: false) { [weak self] _ in
                self?.statusTimer = nil; self?.updateStatus()
            }
            statusTimer?.tolerance = 1
        }
        if panel.isVisible { settings?.needsDisplay = true; if l === dashboard.link || settings == nil { dashboard.needsDisplay = true } }
    }

    /// "all" (or a Mac no longer listed) shows every Mac; otherwise the one chosen.
    private var shownInBar: [HostLink] {
        let one = links.filter { $0.key == Prefs.menuBar }
        return one.isEmpty ? links : one
    }

    private func updateStatus() {
        let shown = shownInBar
        let key = StatusRenderer.readings(for: shown).map { "\($0.top)|\($0.bottom)" }.joined(separator: ",")
            + shown.map { "\($0.key)=\($0.state == .live)" }.joined()
        guard key != lastStatusKey else { return }      // redraw the menu bar only when the text changes
        lastStatusKey = key
        item.button?.image = StatusRenderer.image(for: shown)
        item.button?.toolTip = StatusRenderer.tooltip(for: shown)
    }

    /// Fast while you look, slow when you don't: 1 s for the open view, 5 s for the menu bar, 30 s otherwise.
    private func applyIntervals() {
        let shown = Set(shownInBar.map(\.key))
        for l in links {
            l.wantsProcs = panel?.isVisible == true
            if panel?.isVisible == true && l === dashboard.link { l.interval = 1 }
            else if shown.contains(l.key) || panel?.isVisible == true { l.interval = 5 }
            else { l.interval = 30 }
        }
    }

    // MARK: panel

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    private func open() {
        guard let button = item.button, let bw = button.window else { return }
        let r = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen ?? NSScreen.main!
        let size = panel.frame.size
        var x = r.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: r.minY - 6))
        panel.contentView?.isHidden = false
        panel.orderFrontRegardless()
        panel.makeKey()
        applyIntervals()
        for l in links { if l.state == .live { l.send("now") } }
        dashboard.link.fetchHistory()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.dashboard.link.fetchHistory() }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        dashboard.needsDisplay = true
    }

    private func close() {
        panel.orderOut(nil)
        panelClosed()
    }

    func panelClosed() {
        // Give back the panel's backing store while nobody is looking; it is redrawn on open.
        panel.contentView?.isHidden = true
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        historyTimer?.invalidate(); historyTimer = nil
        if settings != nil { hideSettings() }
        applyIntervals()
    }

    private func resize(_ h: CGFloat) {
        var f = panel.frame
        // Never taller than the screen; Settings scrolls instead.
        let h = min(h, ((panel.screen ?? NSScreen.main)?.visibleFrame.height ?? h) - 16)
        let top = f.maxY
        f.size.height = h; f.origin.y = top - h
        panel.setFrame(f, display: true)
    }

    // MARK: settings

    private func showSettings() {
        let s = SettingsView(links: links, height: panel.frame.height)
        s.autoresizingMask = [.width, .height]
        s.onDone = { [weak self] in self?.hideSettings() }
        s.onSetup = { [weak self] l, remove in self?.setup(l, remove: remove) }
        s.onHostsChanged = { [weak self] in self?.rebuildLinks() }
        s.onChange = { [weak self] in self?.lastStatusKey = ""; self?.updateStatus(); self?.applyIntervals() }
        // Many Macs make Settings taller than the dashboard: grow the panel, never shrink below it.
        s.onHeight = { [weak self] h in guard let self, self.settings != nil else { return }; self.resize(max(h, self.dashboard.measured)) }
        panel.contentView?.addSubview(s)
        dashboard.isHidden = true
        settings = s
    }

    private func hideSettings() {
        settings?.removeFromSuperview(); settings = nil
        dashboard.isHidden = false
        resize(dashboard.measured)
        dashboard.needsDisplay = true
    }

    // MARK: fan setup

    private func setup(_ l: HostLink, remove: Bool) {
        let verb = remove ? "remove-root" : "setup-root"
        if l.isLocal {
            let path = HostLink.localAgent.path.replacingOccurrences(of: "\"", with: "\\\"")
            let cmd = "\\\"\(path)\\\" \(verb) --user \(NSUserName())"
            let script = "do shell script \"\(cmd)\" with administrator privileges with prompt \"Vitals needs your password to control the fans on this Mac.\""
            DispatchQueue.global().async { [weak self] in
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
                DispatchQueue.main.async { if err == nil, self?.links.contains(where: { $0 === l }) == true { l.start() } }
            }
        } else {
            let host = l.sshHost ?? ""
            let cmd = "ssh -t \(host) 'sudo ~/.vitals/vitals-agent \(verb)' && exit"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            // Reconnect a few times while the password is typed in Terminal (unless that Mac was removed meanwhile).
            for delay in [15.0, 30, 60, 120] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak l] in
                    guard let l, self?.links.contains(where: { $0 === l }) == true else { return }
                    if (l.snap?.root ?? false) == remove || (!remove && l.snap?.v != vitalsVersion) { l.start() }
                }
            }
        }
        close()
    }

    private func snapshot(_ v: NSView, to url: URL) {
        if let d = v as? Dashboard {
            d.frame.size.height = 2000; d.display()        // first pass measures the height
            d.frame.size.height = d.measured
        } else if let s = v as? SettingsView {
            s.frame.size.height = 2000                      // not in a window: measure by drawing offscreen
            if let rep = s.bitmapImageRepForCachingDisplay(in: s.bounds) { s.cacheDisplay(in: s.bounds, to: rep) }
            s.frame.size.height = max(s.measured, dashboard.measured)
        }
        v.display()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: logs

    private func openLogs() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vitals")
        let l = dashboard.link
        if l.isLocal {
            NSWorkspace.shared.open(base.appendingPathComponent("Logs"))
            close()
            return
        }
        // Copy that Mac's log files here first, so they open like any other folder. Named by host:
        // two Mac minis share a model name.
        let host = l.sshHost ?? ""
        let dest = base.appendingPathComponent("\(host) logs")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        p.arguments = ["-q", "-o", "BatchMode=yes", "\(host):Library/Application\\ Support/Vitals/Logs/*.csv", dest.path]
        p.terminationHandler = { _ in DispatchQueue.main.async { NSWorkspace.shared.open(dest) } }
        try? p.run()
        close()
    }
}

/// Shows the menu bar image on a dark strip, for review.
final class StatusBarPreview: NSView {
    let image: NSImage
    init(image: NSImage) { self.image = image; super.init(frame: NSRect(x: 0, y: 0, width: image.size.width + 40, height: 30)) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        NSColor(hex: 0x2b2b2e).setFill(); bounds.fill()
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            self.image.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
        }
        tinted.draw(at: NSPoint(x: 20, y: 4), from: .zero, operation: .sourceOver, fraction: 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
