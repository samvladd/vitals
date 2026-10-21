import AppKit
import ServiceManagement

/// Settings, in the same panel: a label column with what each setting does, the control beside it.
final class SettingsView: Canvas, NSTextFieldDelegate {
    var links: [HostLink] { didSet { needsDisplay = true } }
    var onDone: (() -> Void)?
    var onSetup: ((HostLink, Bool) -> Void)?      // link, remove
    var onHostsChanged: (() -> Void)?             // Prefs.remoteHosts changed
    var onChange: (() -> Void)?
    var onHeight: ((CGFloat) -> Void)?

    let addField = NSTextField()
    private let priceField = NSTextField()
    private var addError: String?
    private var suggestions: [Suggestion] = []
    private(set) var measured: CGFloat = 0
    private let pad: CGFloat = 16, labelW: CGFloat = 232

    /// A Mac of yours on Tailscale: the host to add, and the other names it may already be listed under.
    struct Suggestion { let host: String; let aliases: [String]; let name: String }

    init(links: [HostLink], height: CGFloat) {
        self.links = links
        super.init(frame: NSRect(x: 0, y: 0, width: Dashboard.width, height: height))
        for f in [addField, priceField] {
            f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
            f.font = Theme.font(13); f.textColor = Theme.text; f.delegate = self
            f.cell?.usesSingleLineMode = true; f.cell?.isScrollable = true
            addSubview(f)
        }
        addField.placeholderAttributedString = NSAttributedString(string: "SSH host, e.g. mac-mini", attributes: [.foregroundColor: Theme.faint, .font: Theme.font(13)])
        priceField.placeholderAttributedString = NSAttributedString(string: "0.00", attributes: [.foregroundColor: Theme.faint, .font: Theme.font(13)])
        priceField.stringValue = Prefs.price > 0 ? String(format: "%.2f", Prefs.price) : ""
        loadSuggestions()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Scrolls when the panel, held to the screen's height, is shorter than the settings.
    override func scrollWheel(with e: NSEvent) {
        let v = min(max(0, scrollY - e.scrollingDeltaY), max(0, measured - bounds.height))
        if v != scrollY { scrollY = v; needsDisplay = true }
    }

    func controlTextDidChange(_ n: Notification) {
        if (n.object as? NSTextField) === addField, addError != nil { addError = nil; needsDisplay = true }
    }

    func controlTextDidEndEditing(_ n: Notification) {
        if (n.object as? NSTextField) === addField {
            // Return adds; leaving the field (Done, a click elsewhere) keeps the text unsaved.
            if (n.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue { add(addField.stringValue) }
        } else {
            Prefs.price = Double(priceField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0
            onChange?()
        }
        needsDisplay = true
    }

    /// Adds a Mac by SSH host. Only what a host, an alias or user@host needs: nothing ssh could read as
    /// an option, nor a shell expand (the fan setup command is typed into Terminal).
    @discardableResult
    func add(_ raw: String) -> Bool {
        let h = raw.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return false }
        if h.hasPrefix("-") || h.count > 253 || !h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_@:".contains($0)) }) {
            addError = "A host name uses only letters, digits and . - _ @ :"
        } else if Prefs.remoteHosts.contains(h) {
            addError = "\(h) is already on the list."
        } else {
            Prefs.remoteHosts.append(h)
            if addField.stringValue.trimmingCharacters(in: .whitespaces) == h { addField.stringValue = "" }
            addError = nil
            onHostsChanged?()
        }
        needsDisplay = true
        return addError == nil
    }

    func remove(_ host: String) {
        Prefs.remoteHosts.removeAll { $0 == host }
        Prefs.forget(Prefs.key(host))
        onHostsChanged?()
        needsDisplay = true
    }

    /// Your own Macs on Tailscale, for one-click adding: macOS peers of the same user as this Mac, and
    /// untagged (tagged nodes belong to the tailnet, not to you). Asked once per opening, off the main thread.
    private func loadSuggestions() {
        let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let cli = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process(); p.executableURL = URL(fileURLWithPath: cli); p.arguments = ["status", "--json"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let me = (j["Self"] as? [String: Any])?["UserID"].map({ "\($0)" }),
                  let peers = j["Peer"] as? [String: [String: Any]] else { return }
            let found = peers.values.compactMap { p -> Suggestion? in
                guard p["OS"] as? String == "macOS", (p["Tags"] as? [Any] ?? []).isEmpty, p["UserID"].map({ "\($0)" }) == me,
                      let dns = p["DNSName"] as? String, let label = dns.split(separator: ".").first else { return nil }
                let full = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
                return Suggestion(host: String(label), aliases: [full] + (p["TailscaleIPs"] as? [String] ?? []), name: p["HostName"] as? String ?? "")
            }.sorted { $0.host < $1.host }
            DispatchQueue.main.async { self?.suggestions = found; self?.needsDisplay = true }
        }
    }

    private var y: CGFloat = 0

    override func render() {
        fill(bounds, Theme.ground)
        drawText("Settings", Theme.font(20, .semibold), Theme.text, pad, 18)
        let done = NSRect(x: Dashboard.width - pad - 72, y: 16, width: 72, height: 28)
        let hov = hit(done, "done") { [weak self] _ in self?.window?.makeFirstResponder(nil); self?.onDone?() }
        fill(done, hov ? Theme.chart2 : Theme.text, radius: 14)
        drawText("Done", Theme.font(13, .medium), Theme.ground, done.midX, done.minY + 6, align: .center)
        hline(0, 60, Dashboard.width, Theme.line)
        y = 76

        section("Your Macs", "SSH hosts or aliases from ~/.ssh/config. Vitals keeps one connection open to each and installs its agent there.") { x, w in
            var ry = y
            for l in links where !l.isLocal {
                let host = l.sshHost ?? "", name = l.name(among: links)
                let dot: NSColor = { switch l.state { case .live: return Theme.accent; case .offline: return Theme.negative; default: return Theme.warning } }()
                fill(NSRect(x: x, y: ry + 7, width: 6, height: 6), dot, radius: 3)
                let nw = drawText(name, Theme.font(13, .medium), Theme.text, x + 14, ry + 1, maxWidth: w - 60).width
                if name != host { drawText(host, Theme.font(12), Theme.faint, x + 22 + nw, ry + 2, maxWidth: max(0, w - 68 - nw)) }
                let st: String
                switch l.state {
                case .live: st = "Connected to \(l.info?.model ?? l.shortName)"
                case .connecting: st = "Connecting…"
                case .installing: st = "Installing the agent…"
                case .offline(let why): st = why
                }
                drawText(st, Theme.font(12), l.state == .live ? Theme.muted : Theme.warning, x + 14, ry + 20, maxWidth: w - 54)
                let rr = NSRect(x: x + w - 26, y: ry + 4, width: 26, height: 26)
                let hov = hit(rr, "remove.\(host)") { [weak self] _ in self?.remove(host) }
                stroke(rr, hov ? Theme.negative : Theme.chart4, radius: 13)
                drawText("×", Theme.font(15), hov ? Theme.negative : Theme.muted, rr.midX, rr.minY + 3, align: .center)
                ry += 44
            }
            if ry == y { drawText("Only this Mac for now.", Theme.font(12), Theme.faint, x, ry + 2); ry += 26 }

            field(addField, x, ry, w - 72)
            let ar = NSRect(x: x + w - 64, y: ry + 2, width: 64, height: 28)
            let ahov = hit(ar, "add") { [weak self] _ in guard let self else { return }; self.add(self.addField.stringValue) }
            stroke(ar, ahov ? Theme.text : Theme.chart3, radius: 14)
            drawText("Add", Theme.font(12, .medium), Theme.text, ar.midX, ar.minY + 6, align: .center)
            ry += 38
            if let addError { drawText(addError, Theme.font(12), Theme.warning, x, ry, maxWidth: w); ry += 22 }

            // One click for your other Macs on Tailscale, unless already listed under any of their names.
            let listed = Set(Prefs.remoteHosts.map { $0.lowercased() })
            let names = Set(links.compactMap { $0.info?.name.lowercased() })
            let fresh = suggestions.filter { s in
                !([s.host] + s.aliases).contains { listed.contains($0.lowercased()) } && !names.contains(s.name.lowercased())
            }
            if !fresh.isEmpty {
                drawText("On your tailnet", Theme.font(12), Theme.faint, x, ry + 5)
                let f = Theme.font(12, .medium)
                var cx = x + textWidth("On your tailnet", Theme.font(12)) + 10
                for s in fresh {
                    let cw = min(textWidth(s.host, f), w - 40) + 34
                    if cx + cw > x + w { cx = x; ry += 32 }
                    let r = NSRect(x: cx, y: ry, width: cw, height: 26)
                    let hov = hit(r, "suggest.\(s.host)") { [weak self] _ in self?.add(s.host) }
                    stroke(r, hov ? Theme.text : Theme.chart4, radius: 13)
                    drawText("+", Theme.font(13, .medium), Theme.accent, r.minX + 11, r.minY + 4)
                    drawText(s.host, f, hov ? Theme.text : Theme.muted, r.minX + 24, r.minY + 5, maxWidth: w - 40)
                    cx = r.maxX + 6
                }
                ry += 30
            }
            return ry - y
        }

        section("Menu bar", "Watts on top, the CPU temperature under it. Three Macs or more fold into one: total watts over the hottest CPU.") { x, w in
            segmented(menuBarOptions(), x: x, w: w)
            return 40
        }

        section("Fan curve", "Used when a fan is set to Curve. Between the two temperatures the speed rises in a straight line.") { x, w in
            stepper("Minimum speed at or below", value: Prefs.curveLow, x: x, w: w, dy: 0) { v in Prefs.curveLow = min(v, Prefs.curveHigh - 5) }
            stepper("Full speed at or above", value: Prefs.curveHigh, x: x, w: w, dy: 36) { v in Prefs.curveHigh = max(v, Prefs.curveLow + 5) }
            return 72
        }

        section("Fan control", "Setting fan speeds needs root. Setup asks for your password once, installs a root-owned copy of the agent and a sudo rule for exactly that program. Fans return to Auto whenever Vitals disconnects.") { x, w in
            for (i, l) in links.enumerated() {
                let ry = y + CGFloat(i) * 40
                drawText(l.name(among: links), Theme.font(13, .medium), Theme.text, x, ry + 6, maxWidth: w - 210)
                let on = l.snap?.root ?? false
                let stale = on && l.snap?.v != vitalsVersion
                pill(stale ? "Update available" : on ? "Enabled" : "Not set up",
                     stale ? Theme.pillWarn : on ? Theme.pillGood : Theme.pillNeutral, right: x + w - 92, ry + 5)
                let br = NSRect(x: x + w - 80, y: ry, width: 80, height: 28)
                let hov = hit(br, "setup.\(l.key)") { [weak self] _ in self?.onSetup?(l, on && !stale) }
                stroke(br, hov ? Theme.text : Theme.chart3, radius: 14)
                drawText(stale ? "Update" : on ? "Remove" : "Set up", Theme.font(12, .medium), Theme.text, br.midX, br.minY + 6, align: .center)
            }
            return CGFloat(links.count) * 40 + 8
        }

        section("Electricity price", "Per kWh, to show what each day costs. Leave it empty to hide costs.") { x, w in
            drawText("$", Theme.font(13), Theme.muted, x, y + 9)
            field(priceField, x + 14, y, 90)
            drawText("per kWh", Theme.font(13), Theme.muted, x + 118, y + 9)
            return 40
        }

        section("Open at login", "Start Vitals in the menu bar when you log in to this Mac.") { x, w in
            let on = SMAppService.mainApp.status == .enabled
            let tr = NSRect(x: x, y: y + 4, width: 36, height: 20)
            hit(tr.insetBy(dx: -4, dy: -4), "login") { [weak self] _ in
                if on { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
                self?.needsDisplay = true
            }
            fill(tr, on ? Theme.accent : Theme.raised, radius: 10)
            fill(NSRect(x: on ? tr.maxX - 18 : tr.minX + 2, y: tr.minY + 2, width: 16, height: 16), on ? Theme.ground : Theme.chart2, radius: 8)
            return 32
        }

        // Taller than the dashboard (many Macs): the panel grows to fit.
        if abs(y - measured) > 0.5 { measured = y; let h = y; DispatchQueue.main.async { self.onHeight?(h) } }
        if scrollY > max(0, y - bounds.height) { scrollY = max(0, y - bounds.height); needsDisplay = true }   // a Mac was removed
    }

    /// "All" and a segment per Mac while they fit (three Macs); beyond that, one segment stands for a
    /// single other Mac and steps to the next one each time it is clicked.
    private func menuBarOptions() -> [(id: String, label: String, active: Bool, set: () -> Void)] {
        let all = (id: "all", label: "All", active: !links.contains { $0.key == Prefs.menuBar }, set: { Prefs.menuBar = "all" })
        if links.count <= 3 {
            return links.map { l in (l.key, l.isLocal ? "This Mac" : l.name(among: links), l.key == Prefs.menuBar, { Prefs.menuBar = l.key }) } + [all]
        }
        let remotes = links.filter { !$0.isLocal }
        let i = remotes.firstIndex { $0.key == Prefs.menuBar }
        let next = remotes[i.map { ($0 + 1) % remotes.count } ?? 0]
        return [("local", "This Mac", Prefs.menuBar == "local", { Prefs.menuBar = "local" }),
                ("one", remotes[i ?? 0].name(among: links) + " ›", i != nil, { Prefs.menuBar = next.key }), all]
    }

    /// One settings row: title and help on the left, the control's area on the right.
    private func section(_ title: String, _ help: String, _ body: (CGFloat, CGFloat) -> CGFloat) {
        let x = pad + labelW + 24, w = Dashboard.width - x - pad
        drawText(title, Theme.font(13, .semibold), Theme.text, pad, y + 6)
        let helpRect = NSRect(x: pad, y: y + 26, width: labelW, height: 200)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(12), .foregroundColor: Theme.faint, .paragraphStyle: para]
        let helpH = (help as NSString).boundingRect(with: helpRect.size, options: [.usesLineFragmentOrigin], attributes: attrs).height
        (help as NSString).draw(with: helpRect, options: [.usesLineFragmentOrigin], attributes: attrs)
        let bodyH = body(x, w)
        y += max(26 + helpH, bodyH) + 18
        hline(pad, y - 10, Dashboard.width - pad * 2, Theme.line)
        y += 8
    }

    private func field(_ f: NSTextField, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
        let r = NSRect(x: x, y: y, width: w, height: 32)
        fill(r, Theme.surface, radius: 8)
        stroke(r, f.currentEditor() != nil ? Theme.chart3 : Theme.line, radius: 8)
        let fr = NSRect(x: x + 10, y: y + 7 - scrollY, width: w - 20, height: 18)
        if f.frame != fr { f.frame = fr }
    }

    private func segmented(_ options: [(id: String, label: String, active: Bool, set: () -> Void)], x: CGFloat, w: CGFloat) {
        let f = Theme.font(12, .medium)
        let natural = options.map { textWidth($0.label, f) }
        let cap = labelCap(natural, fitting: w - 4 - CGFloat(options.count) * 28)
        let widths = natural.map { min($0, cap) + 28 }
        let track = NSRect(x: x, y: y, width: widths.reduce(0, +) + 4, height: 30)
        fill(track, Theme.raised, radius: 15)
        var sx = track.minX + 2
        for (i, o) in options.enumerated() {
            let r = NSRect(x: sx, y: track.minY + 2, width: widths[i], height: 26)
            let hov = hit(r, "seg.\(o.id)") { [weak self] _ in o.set(); self?.onChange?(); self?.needsDisplay = true }
            if o.active { fill(r, Theme.text, radius: 13) }
            drawText(o.label, f, o.active ? Theme.ground : (hov ? Theme.text : Theme.muted), r.midX, r.minY + 5, align: .center, maxWidth: cap)
            sx += widths[i]
        }
    }

    private func stepper(_ label: String, value: Double, x: CGFloat, w: CGFloat, dy: CGFloat, set: @escaping (Double) -> Void) {
        let ry = y + dy
        drawText(label, Theme.font(13), Theme.muted, x, ry + 6)
        let vx = x + w - 120
        for (i, (glyph, delta)) in [("−", -5.0), ("+", 5.0)].enumerated() {
            let r = NSRect(x: i == 0 ? vx : vx + 92, y: ry, width: 28, height: 28)
            let hov = hit(r, "step.\(label).\(i)") { [weak self] _ in set(value + delta); self?.onChange?(); self?.needsDisplay = true }
            fill(r, hov ? Theme.chart3 : Theme.raised, radius: 14)
            drawText(glyph, Theme.font(15, .medium), Theme.text, r.midX, r.minY + 4, align: .center)
        }
        drawText("\(Int(value))°C", Theme.font(14, .medium), Theme.text, vx + 60, ry + 5, align: .center)
    }
}
