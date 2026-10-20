import AppKit
import ServiceManagement

/// Settings, in the same panel: a label column with what each setting does, the control beside it.
final class SettingsView: Canvas, NSTextFieldDelegate {
    let links: [HostLink]
    var onDone: (() -> Void)?
    var onSetup: ((HostLink, Bool) -> Void)?      // link, remove
    var onHostChanged: ((String) -> Void)?
    var onChange: (() -> Void)?

    private let hostField = NSTextField()
    private let priceField = NSTextField()
    private let pad: CGFloat = 16, labelW: CGFloat = 232

    init(links: [HostLink], height: CGFloat) {
        self.links = links
        super.init(frame: NSRect(x: 0, y: 0, width: Dashboard.width, height: height))
        for f in [hostField, priceField] {
            f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
            f.font = Theme.font(13); f.textColor = Theme.text; f.delegate = self
            f.cell?.usesSingleLineMode = true; f.cell?.isScrollable = true
            addSubview(f)
        }
        hostField.stringValue = Prefs.remoteHost
        priceField.placeholderAttributedString = NSAttributedString(string: "0.00", attributes: [.foregroundColor: Theme.faint, .font: Theme.font(13)])
        priceField.stringValue = Prefs.price > 0 ? String(format: "%.2f", Prefs.price) : ""
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidEndEditing(_ n: Notification) {
        if (n.object as? NSTextField) === hostField {
            let h = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            if !h.isEmpty, h != Prefs.remoteHost { Prefs.remoteHost = h; onHostChanged?(h) }
        } else {
            Prefs.price = Double(priceField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0
            onChange?()
        }
        needsDisplay = true
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

        let remote = links.first { !$0.isLocal }!
        section("Mac mini address", "An SSH host or alias from ~/.ssh/config. Vitals keeps one connection open and installs its agent there.") { x, w in
            field(hostField, x, w)
            let st: String
            switch remote.state {
            case .live: st = "Connected to \(remote.info?.model ?? remote.shortName)"
            case .connecting: st = "Connecting…"
            case .installing: st = "Installing the agent…"
            case .offline(let why): st = why
            }
            drawText(st, Theme.font(12), remote.state == .live ? Theme.muted : Theme.warning, x, y + 42, maxWidth: w)
            return 64
        }

        section("Menu bar", "What sits beside the clock: watts on top, the CPU temperature under it.") { x, _ in
            segmented(["remote": remote.shortName, "local": "This Mac", "both": "Both"], order: ["remote", "local", "both"],
                      value: Prefs.menuBar, x: x) { [weak self] v in Prefs.menuBar = v; self?.onChange?() }
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
                drawText(l.shortName, Theme.font(13, .medium), Theme.text, x, ry + 6)
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
            field(priceField, x + 14, 90)
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

    private func field(_ f: NSTextField, _ x: CGFloat, _ w: CGFloat) {
        let r = NSRect(x: x, y: y, width: w, height: 32)
        fill(r, Theme.surface, radius: 8)
        stroke(r, f.currentEditor() != nil ? Theme.chart3 : Theme.line, radius: 8)
        let fr = NSRect(x: x + 10, y: y + 7, width: w - 20, height: 18)
        if f.frame != fr { f.frame = fr }
    }

    private func segmented(_ names: [String: String], order: [String], value: String, x: CGFloat, set: @escaping (String) -> Void) {
        let f = Theme.font(12, .medium)
        let widths = order.map { textWidth(names[$0]!, f) + 28 }
        let track = NSRect(x: x, y: y, width: widths.reduce(0, +) + 4, height: 30)
        fill(track, Theme.raised, radius: 15)
        var sx = track.minX + 2
        for (i, k) in order.enumerated() {
            let r = NSRect(x: sx, y: track.minY + 2, width: widths[i], height: 26)
            let hov = hit(r, "seg.\(k)") { [weak self] _ in set(k); self?.needsDisplay = true }
            if k == value { fill(r, Theme.text, radius: 13) }
            drawText(names[k]!, f, k == value ? Theme.ground : (hov ? Theme.text : Theme.muted), r.midX, r.minY + 5, align: .center)
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
