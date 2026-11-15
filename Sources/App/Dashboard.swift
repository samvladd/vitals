import AppKit

/// The dropdown. Two columns: power and fans on the left (what it costs, how it cools), pressure
/// and the processes behind it on the right. Everything is drawn here in one pass.
final class Dashboard: Canvas {
    static let width: CGFloat = 660
    var links: [HostLink] { didSet { needsDisplay = true } }
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSetup: ((HostLink) -> Void)?
    var onOpenLogs: (() -> Void)?
    var onHeight: ((CGFloat) -> Void)?

    private(set) var measured: CGFloat = 640
    private var dragRPM: Double?
    private var chartRect = NSRect.zero
    private var mouse: NSPoint?

    init(links: [HostLink]) {
        self.links = links
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 640))
    }
    required init?(coder: NSCoder) { fatalError() }

    var link: HostLink { links.first { $0.key == Prefs.selected } ?? links[0] }

    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        let p = convert(e.locationInWindow, from: nil)
        let was = mouse.map { chartRect.contains($0) } ?? false
        mouse = p
        if was || chartRect.contains(p) { needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { super.mouseExited(with: e); mouse = nil; needsDisplay = true }

    // MARK: layout

    private let pad: CGFloat = 16, gap: CGFloat = 12
    private var colW: CGFloat { (Self.width - pad * 2 - gap) / 2 }

    override func render() {
        fill(bounds, Theme.backdrop)
        let l = link, s = l.snap
        var y = header()
        arriving(0) { title(l, s, &y) }
        let top = y
        var left = top, right = top
        // The cards arrive left column first, then right, 60 ms apart.
        arriving(1) { powerCard(l, s, x: pad, y: &left) }
        left += gap
        arriving(3) { fanCard(l, s, x: pad, y: &left) }
        arriving(2) { pressureGrid(l, s, x: pad + colW + gap, y: &right) }
        right += gap
        arriving(4) { procCard(s, x: pad + colW + gap, y: &right, bottom: left) }
        let bottom = max(left, right)
        arriving(5) { footer(l, s, y: bottom + 10) }
        let h = bottom + 48
        measured = h
        if abs(h - frame.height) > 0.5 { DispatchQueue.main.async { self.onHeight?(h) } }
    }

    // MARK: header and title

    /// The mark and a tab per Mac; returns where the title starts. Up to three Macs sit beside the
    /// mark as today. More would overflow the row, so they get a row of chips of their own, every
    /// Mac still one click away, and the first row sums up the fleet instead.
    private func header() -> CGFloat {
        // The mark: the Mac mini seen from above, with its one status light.
        // The mark, in the kit's off-white (its one accent): the Mac mini from above, with its status light.
        let m = NSRect(x: pad, y: 17, width: 20, height: 20)
        fill(m, Theme.text, radius: 6)
        fill(NSRect(x: m.midX - 2.5, y: m.maxY - 6.5, width: 5, height: 2.5), Theme.ground, radius: 1.25)
        drawText("Vitals", Theme.font(14, .semibold), Theme.text, pad + 28, 18)
        let current = link
        func dot(_ l: HostLink) -> NSColor { switch l.state { case .live: return Theme.good; case .offline: return Theme.negative; default: return Theme.warning } }

        guard links.count > 3 else {
            var x = Self.width - pad
            for l in links.reversed() {
                let name = l.name(among: links), active = l === current
                let f = Theme.font(13, active ? .medium : .regular)
                let w = textWidth(name, f)
                let r = NSRect(x: x - w - 14, y: 10, width: w + 14, height: 34)
                let hovered = hit(r, "tab.\(l.key)") { [weak self] _ in Prefs.selected = l.key; self?.selectionChanged() }
                drawText(name, f, active || hovered ? Theme.text : Theme.faint, x, 18, align: .right)
                fill(NSRect(x: x - w - 12, y: 24, width: 6, height: 6), dot(l), radius: 3)
                x -= w + 30
            }
            hline(0, 52, Self.width, Theme.line)
            return 60
        }

        let live = links.filter { $0.state == .live }
        let total = live.compactMap { $0.snap?.wSystem }.reduce(0, +)
        drawText("\(live.count) of \(links.count) Macs live · \(Fmt.wattsUnit(live.isEmpty ? nil : total)) in all",
                 Theme.font(12), Theme.faint, Self.width - pad, 20, align: .right)
        let f = Theme.font(12, .medium), inner: CGFloat = 32, spacing: CGFloat = 6
        let names = links.map { $0.name(among: links) }
        let natural = names.map { textWidth($0, f) }
        let cap = labelCap(natural, fitting: Self.width - pad * 2 - CGFloat(links.count) * inner - CGFloat(links.count - 1) * spacing)
        var x = pad
        for (i, l) in links.enumerated() {
            let r = NSRect(x: x, y: 48, width: min(natural[i], cap) + inner, height: 26)
            let active = l === current
            let hovered = hit(r, "tab.\(l.key)") { [weak self] _ in Prefs.selected = l.key; self?.selectionChanged() }
            fill(r, active ? Theme.raisedHi : hovered ? Theme.raised : Theme.sunk, radius: 13)
            stroke(r, active ? Theme.line3 : hovered ? Theme.line2 : Theme.line, radius: 13)
            fill(NSRect(x: r.minX + 12, y: r.midY - 3, width: 6, height: 6), dot(l), radius: 3)
            drawText(names[i], f, active || hovered ? Theme.text : Theme.muted, r.minX + 22, r.minY + 5, maxWidth: cap)
            x = r.maxX + spacing
        }
        hline(0, 86, Self.width, Theme.line)
        return 94
    }

    var selectionChanged: () -> Void = {}

    private func title(_ l: HostLink, _ s: Snapshot?, _ y: inout CGFloat) {
        let name = l.info?.name.replacingOccurrences(of: "’s ", with: "’s\u{00a0}") ?? l.shortName
        drawText(l.shortName, Theme.font(20, .semibold), Theme.text, pad, y)
        // Straight to this Mac's screen or its phone dashboard, in the browser, when it has them.
        var px = pad + textWidth(l.shortName, Theme.font(20, .semibold)) + 14
        for (id, label, url, primary) in [("screen", "Screen", l.info?.screen, true), ("web", "Dashboard", l.info?.dashboard, false)] {
            guard let url = url.flatMap(URL.init(string:)) else { continue }
            let w = textWidth(label + " ›", Theme.font(12, .semibold)) + 26
            button("title.\(id)", label + " ›", at: NSRect(x: px, y: y + 2, width: w, height: 26), primary: primary) { NSWorkspace.shared.open(url) }
            px += w + 8
        }
        if let i = l.info {
            let spec = "\(i.chip.replacingOccurrences(of: "Apple ", with: "")) · \(i.cores) cores · \(Fmt.gb(i.memory, 0)) GB · \(i.os)"
            drawText(spec, Theme.font(12), Theme.faint, Self.width - pad, y + 7, align: .right)
        } else {
            drawText(name, Theme.font(12), Theme.faint, Self.width - pad, y + 7, align: .right)
        }
        y += 30
        // The finding, led by a status light in its colour: green when all is easy.
        let (line, tone) = finding(l, s)
        let light = tone == Theme.muted ? (l.state == .live ? Theme.good : Theme.faint) : tone == Theme.text ? Theme.accent : tone
        fill(NSRect(x: pad, y: y + 5, width: 8, height: 8), light, radius: 4)
        fill(NSRect(x: pad - 3, y: y + 2, width: 14, height: 14), light.withAlphaComponent(0.18), radius: 7)
        drawText(line, Theme.font(13), tone == Theme.muted ? Theme.soft : tone, pad + 18, y, maxWidth: Self.width - pad * 2 - 148)
        let stamp: String
        switch l.state {
        case .live: stamp = "Live · " + Fmt.clock(s?.t ?? 0, seconds: true)
        case .connecting: stamp = "Connecting…"
        case .installing: stamp = "Installing agent…"
        case .offline: stamp = l.nextRetry.map { "Retry in \(max(1, Int($0.timeIntervalSinceNow))) s" } ?? "Offline"
        }
        drawText(stamp, Theme.font(12), Theme.faint, Self.width - pad, y + 1, align: .right)
        y += 30
    }

    /// The one fact that most needs attention, in words.
    private func finding(_ l: HostLink, _ s: Snapshot?) -> (String, NSColor) {
        if case .offline(let why) = l.state { return (why, Theme.negative) }
        guard let s else { return (l.isLocal ? "Starting the agent on this Mac…" : "Connecting to \(l.sshHost ?? "")…", Theme.muted) }
        let topProc = s.procs.first?.name
        if s.thermal >= 2 { return ("Thermal pressure is \(s.thermal == 2 ? "serious" : "critical"): macOS is slowing the chip to cool it.", Theme.negative) }
        if let b = s.volumes.first(where: \.boot), b.free < 8e9 || b.free / max(1, b.total) < 0.05 {
            return ("Storage is almost full: \(Fmt.size(b.free)) free of \(Fmt.size(b.total)) on \(b.name).", Theme.negative)
        }
        if s.pressure >= 4 { return ("Memory pressure is critical: \(Fmt.gb(s.swapUsed)) GB is in swap and apps are being squeezed.", Theme.negative) }
        if let t = s.tCPU, t >= 90 {
            let fans = s.fans.isEmpty ? "" : " with fans at \(Fmt.rpm(s.fans.map(\.rpm).max() ?? 0)) rpm"
            return ("CPU at \(Fmt.temp(t))\(fans)" + (topProc.map { "; \($0) is the main load." } ?? "."), Theme.warning)
        }
        if s.pressure >= 2 { return ("Memory is the pressure point: \(Fmt.gb(s.memUsed)) of \(Fmt.gb(s.memTotal, 0)) GB used, \(Fmt.gb(s.swapUsed)) GB in swap.", Theme.warning) }
        if let c = s.cpu, c >= 70 { return ("CPU is busy at \(Fmt.pct(c))" + (topProc.map { "; \($0) is using the most." } ?? "."), Theme.text) }
        if let b = s.battery, !b.external {
            let left = b.minutesLeft.map { " · \(Fmt.duration(Double($0) * 60)) left at this rate" } ?? ""
            return ("On battery at \(Int(b.percent))%\(left).", Theme.text)
        }
        let fan = s.fans.first.map { ", fan at \(Fmt.rpm($0.rpm)) rpm" } ?? ""
        return ("Running easy: \(Fmt.wattsUnit(s.wSystem)), CPU \(Fmt.temp(s.tCPU))\(fan).", Theme.muted)
    }

    // MARK: power

    private let ranges = ["10 m", "1 h", "24 h", "14 d"]

    private func powerCard(_ l: HostLink, _ s: Snapshot?, x: CGFloat, y: inout CGFloat) {
        let w = colW, top = y
        let isBattery = s?.battery != nil
        let h: CGFloat = isBattery ? 328 : 306
        card(NSRect(x: x, y: top, width: w, height: h))
        let ix = x + 16, iw = w - 32
        drawText("Power", Theme.font(13, .semibold), Theme.text, ix, top + 15)
        let track = NSRect(x: ix + iw - 196, y: top + 10, width: 196, height: 28)
        segmented("range", ranges.enumerated().map { (id: "\($0.offset)", label: $0.element) }, selected: Prefs.range, in: track) { [weak self] i in
            Prefs.range = i; self?.replayChart(); self?.needsDisplay = true
        }

        // The answer: watts now, counting to each new reading.
        let fy = top + 48
        let big = Theme.mono(34, .medium)
        let ws = Fmt.watts(s?.wSystem)
        let bw = odometer("watts", ws, big, Theme.text, ix, fy)
        drawText("W", Theme.font(15, .medium), Theme.muted, ix + bw + 5, fy + 17)

        let days = l.history?.days ?? []
        let today = days.last { $0.day == Self.dayString(Date()) }
        let todayText = today.map { Fmt.energy($0.wh) } ?? "—"
        let price = Prefs.price
        let cost = (price > 0 && today != nil) ? " · " + Fmt.money(today!.wh / 1000 * price) : ""
        stat("Today", todayText + cost, right: ix + iw, y: fy + 4)
        let (pts, domain) = series(l)
        if Prefs.range == 3 {
            let total = days.reduce(0) { $0 + $1.wh }
            stat("14 days", Fmt.energy(total) + (price > 0 ? " · " + Fmt.money(total / 1000 * price) : ""), right: ix + iw, y: fy + 24)
        } else {
            let peak = pts.map(\.w).max()
            stat("Peak · \(ranges[Prefs.range])", Fmt.wattsUnit(peak), right: ix + iw, y: fy + 24)
        }

        let chart = NSRect(x: ix, y: fy + 58, width: iw, height: 112)
        chartRect = chart
        if Prefs.range == 3 { dayBars(days, in: chart) } else { line(pts, domain: domain, in: chart) }

        // Where the watts go: one bar split by part, each part gliding to its share.
        var by = chart.maxY + 30
        let parts: [(String, Double?, NSColor)] = [("CPU", s?.wCPU, Theme.accent), ("GPU", s?.wGPU, Theme.chart2),
                                                   ("Memory", s?.wDRAM, Theme.series3)]
        let known = parts.compactMap(\.1).reduce(0, +) + (s?.wANE ?? 0)
        let total = s?.wSystem ?? 0
        let rest = max(0, total - known)
        let bar = NSRect(x: ix, y: by, width: iw, height: 8)
        fill(bar, Theme.raised, radius: 4)
        if total > 0 {
            var bx = bar.minX
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).addClip()
            for (name, v, c) in parts {
                let share = glide("split.\(name)", min(1, max(0, (v ?? 0) / total)))
                let pw = bar.width * CGFloat(share)
                guard pw > 0.5 else { continue }
                fill(NSRect(x: bx, y: bar.minY, width: pw, height: bar.height), c); bx += pw + 2
            }
            fill(NSRect(x: bx, y: bar.minY, width: max(0, bar.maxX - bx), height: bar.height), Theme.chart4)
            NSGraphicsContext.restoreGraphicsState()
        }
        by += 18
        let legend: [(String, Double?, NSColor)] = parts + [("Other", s?.wSystem == nil ? nil : rest, Theme.chart4)]
        for (i, (name, v, c)) in legend.enumerated() {
            let cx = ix + CGFloat(i % 2) * (iw / 2 + 6), cy = by + CGFloat(i / 2) * 20
            fill(NSRect(x: cx, y: cy + 4, width: 8, height: 8), c, radius: 4)
            drawText(name, Theme.font(12), Theme.muted, cx + 14, cy)
            drawText(Fmt.wattsUnit(v), Theme.font(12, .medium), Theme.text, cx + iw / 2 - 12, cy, align: .right)
        }
        if let b = s?.battery {
            let src: String
            if b.external, let inW = b.inWatts {
                src = "Adapter \(Fmt.watts(inW))\(b.adapterWatts.map { " of \(Int($0))" } ?? "") W · battery \(Int(b.percent))%\(b.charging ? ", charging" : "")"
            } else {
                src = "On battery · \(Int(b.percent))% · \(Fmt.watts(abs(b.batteryWatts ?? 0))) W from it"
            }
            drawText(src, Theme.font(12), Theme.muted, ix, by + 46, maxWidth: iw)
        }
        y = top + h
    }

    private func stat(_ label: String, _ value: String, right: CGFloat, y: CGFloat) {
        let vf = Theme.font(13, .medium)
        let vw = drawText(value, vf, Theme.text, right, y, align: .right).width
        drawText(label, Theme.font(12), Theme.faint, right - vw - 8, y + 1, align: .right)
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }

    /// The points for the chosen range, oldest first, with the time window they fill.
    private func series(_ l: HostLink) -> ([(t: Double, w: Double)], ClosedRange<Double>) {
        let now = l.snap?.t ?? Date().timeIntervalSince1970
        let span: Double = [600, 3600, 86400, 86400 * 14][Prefs.range]
        let from = now - span
        if Prefs.range == 0 { return (l.live.filter { $0.t >= from }, from...now) }
        var pts = (l.history?.rows ?? []).filter { $0.t >= from }.map { (t: $0.t + 30, w: $0.w) }
        if Prefs.range == 2 {      // five-minute means keep 24 h to 288 points
            var buckets: [Int: (Double, Int)] = [:]
            for p in pts { let k = Int(p.t / 300); buckets[k, default: (0, 0)].0 += p.w; buckets[k, default: (0, 0)].1 += 1 }
            pts = buckets.keys.sorted().map { (t: Double($0 * 300 + 150), w: buckets[$0]!.0 / Double(buckets[$0]!.1)) }
        }
        let lastLogged = pts.last?.t ?? from
        pts += l.live.filter { $0.t > lastLogged + 30 }
        return (pts, from...now)
    }

    private func axis(_ maxV: Double, in r: NSRect, unit: String, format: (Double) -> String) -> (top: Double, plot: NSRect) {
        let (topV, step) = niceCeiling(maxV)
        let labelW: CGFloat = unit.count > 3 ? 54 : 42
        let plot = NSRect(x: r.minX, y: r.minY, width: r.width - labelW, height: r.height)
        var v = 0.0
        while v <= topV + 0.001 {
            let yy = plot.maxY - CGFloat(v / topV) * plot.height
            hline(plot.minX, yy, plot.width, v == 0 ? Theme.line2 : Theme.grid, dash: v != 0)
            drawText(format(v) + unit, Theme.font(11), Theme.faint, r.maxX, yy - 7, align: .right)
            v += step
        }
        return (topV, plot)
    }

    private func line(_ pts: [(t: Double, w: Double)], domain: ClosedRange<Double>, in r: NSRect) {
        let maxW = pts.map(\.w).max() ?? 0
        let (topV, plot) = axis(maxW, in: r, unit: " W") { $0 >= 10 || $0 == 0 ? String(format: "%.0f", $0) : String(format: "%.1f", $0) }
        let span = domain.upperBound - domain.lowerBound
        func px(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - domain.lowerBound) / span) * plot.width }
        func py(_ w: Double) -> CGFloat { plot.maxY - CGFloat(min(w, topV) / topV) * plot.height }

        // X labels on one step: the window's start, its thirds and now.
        for i in 0...3 {
            let t = domain.lowerBound + span * Double(i) / 3
            let label = i == 3 ? "now" : Prefs.range == 0 ? "−\(Int((domain.upperBound - t) / 60)) m" : Fmt.clock(t)
            drawText(label, Theme.font(11), Theme.faint, px(t), plot.maxY + 6, align: i == 0 ? .left : i == 3 ? .right : .center)
        }
        guard pts.count > 1 else {
            let msg = Prefs.range == 0 ? "Collecting the first readings…" : "Nothing logged yet for this range."
            drawText(msg, Theme.font(12), Theme.faint, plot.midX, plot.midY - 20, align: .center, maxWidth: plot.width)
            return
        }
        // Break the line where readings are missing rather than drawing across the gap.
        let maxGap: Double = [20, 180, 900][Prefs.range]
        var runs: [[NSPoint]] = [[]]
        var prevT = pts[0].t
        for p in pts where p.t >= domain.lowerBound {
            if p.t - prevT > maxGap, !(runs.last!.isEmpty) { runs.append([]) }
            runs[runs.count - 1].append(NSPoint(x: px(p.t), y: py(p.w)))
            prevT = p.t
        }
        // The line draws itself in from the left (the kit's "draw"), over a fill that fades to nothing.
        let reveal = drawIn()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: plot.minX - 2, y: plot.minY - 4, width: (plot.width + 4) * reveal, height: plot.height + 8).clip()
        let gradient = NSGradient(starting: Theme.accent.withAlphaComponent(0.28), ending: Theme.accent.withAlphaComponent(0))
        for run in runs where run.count > 1 {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: run[0].x, y: plot.maxY))
            run.forEach { area.line(to: $0) }
            area.line(to: NSPoint(x: run.last!.x, y: plot.maxY)); area.close()
            gradient?.draw(in: area, angle: 90)
            let path = NSBezierPath(); path.move(to: run[0]); run.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = 2; path.lineJoinStyle = .round; path.lineCapStyle = .round
            Theme.accent.setStroke(); path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        // The newest reading, ringed, once the line has reached it.
        if reveal >= 1, let last = runs.last?.last, mouse.map({ !plot.contains($0) }) ?? true {
            fill(NSRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12), Theme.accent.withAlphaComponent(0.22), radius: 6)
            fill(NSRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6), Theme.accent, radius: 3)
        }
        // Read a value under the pointer.
        if let m = mouse, plot.contains(m) {
            let t = domain.lowerBound + Double((m.x - plot.minX) / plot.width) * span
            if let near = pts.min(by: { abs($0.t - t) < abs($1.t - t) }) {
                let x = px(near.t)
                vline(x, plot.minY, plot.height, Theme.line3)
                fill(NSRect(x: x - 5, y: py(near.w) - 5, width: 10, height: 10), Theme.ground, radius: 5)
                fill(NSRect(x: x - 3.5, y: py(near.w) - 3.5, width: 7, height: 7), Theme.accent, radius: 3.5)
                let label = "\(Fmt.clock(near.t, seconds: Prefs.range == 0)) · \(Fmt.watts(near.w)) W"
                let f = Theme.font(12, .medium), lw = textWidth(label, f) + 16
                let lx = min(max(x - lw / 2, plot.minX), plot.maxX - lw)
                let tip = NSRect(x: lx, y: plot.minY - 6, width: lw, height: 22)
                fill(tip, Theme.raised, radius: 7)
                stroke(tip, Theme.line2, radius: 7)
                drawText(label, f, Theme.text, lx + 8, tip.minY + 3)
            }
        }
    }

    private func dayBars(_ days: [DayTotal], in r: NSRect) {
        let shown = Array(days.suffix(14))
        let maxWh = shown.map(\.wh).max() ?? 0
        let kilo = maxWh >= 1000
        let (topV0, plot) = axis(kilo ? maxWh / 1000 : maxWh, in: r, unit: kilo ? " kWh" : " Wh") { $0 == 0 ? "0" : String(format: kilo ? "%.1f" : "%.0f", $0) }
        let topV = kilo ? topV0 * 1000 : topV0
        guard !shown.isEmpty else {
            drawText("Daily totals appear after the first day of logging.", Theme.font(12), Theme.faint, plot.midX, plot.midY - 20, align: .center)
            return
        }
        let slots = 14, bw = (plot.width - CGFloat(slots - 1) * 4) / CGFloat(slots)
        let todayKey = Self.dayString(Date())
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"
        let show = DateFormatter(); show.dateFormat = "d MMM"
        for (i, d) in shown.enumerated() {
            let slot = slots - shown.count + i
            let bx = plot.minX + CGFloat(slot) * (bw + 4)
            // Bars grow up from the axis, one after another, as the chart draws in.
            let grow = min(1, max(0, drawIn() * 1.6 - CGFloat(i) / CGFloat(max(1, shown.count)) * 0.6))
            let bh = max(1.5, CGFloat(d.wh / topV) * plot.height * grow)
            let rect = NSRect(x: bx, y: plot.maxY - bh, width: bw, height: bh)
            let hov = hit(NSRect(x: bx, y: plot.minY, width: bw + 4, height: plot.height), "day.\(d.day)") { _ in }
            fill(rect, d.day == todayKey ? Theme.accent : (hov ? Theme.soft : Theme.raisedHi), radius: min(4, bw / 2))
            if hov || (d.day == todayKey && hover?.hasPrefix("day.") != true) {
                let date = parse.date(from: d.day).map { show.string(from: $0) } ?? d.day
                let label = "\(d.day == todayKey ? "Today so far" : date) · \(Fmt.energy(d.wh)) · peak \(Fmt.watts(d.peak)) W"
                let f = Theme.font(12, .medium), lw = textWidth(label, f) + 16
                let lx = min(max(bx + bw / 2 - lw / 2, plot.minX), plot.maxX - lw)
                let tip = NSRect(x: lx, y: plot.minY - 6, width: lw, height: 22)
                fill(tip, Theme.raised, radius: 7)
                stroke(tip, Theme.line2, radius: 7)
                drawText(label, f, Theme.text, lx + 8, tip.minY + 3)
            }
        }
        if let first = shown.first, shown.count > 3, let fd = parse.date(from: first.day) {
            let slot = slots - shown.count
            drawText(show.string(from: fd), Theme.font(11), Theme.faint, plot.minX + CGFloat(slot) * (bw + 4), plot.maxY + 6)
        }
        drawText("today", Theme.font(11), Theme.faint, plot.maxX, plot.maxY + 6, align: .right)
    }

    // MARK: fans

    private func currentPolicy(_ l: HostLink, _ s: Snapshot?) -> [String] {
        ((s?.root ?? false) ? s!.fanPolicy : Prefs.fanPolicy(l.key)).split(separator: " ").map(String.init)
    }

    private func fanCard(_ l: HostLink, _ s: Snapshot?, x: CGFloat, y: inout CGFloat) {
        let fans = s?.fans ?? []
        let w = colW, top = y, ix = x + 16, iw = w - 32
        let canControl = s?.root ?? false
        let outdated = false     // an older fan helper still works; Settings offers the update
        let h: CGFloat = 70 + CGFloat(max(1, fans.count)) * 62 + 34
        card(NSRect(x: x, y: top, width: w, height: h))
        drawText(fans.count > 1 ? "Fans" : "Fan", Theme.font(13, .semibold), Theme.text, ix, top + 15)

        // Mode control: Auto, Fixed, Curve. The chosen one is the kit's primary, and slides there.
        let policy = currentPolicy(l, s)
        let mode = policy.first ?? "auto"
        let modes = [(id: "auto", label: "Auto"), (id: "fixed", label: "Fixed"), (id: "curve", label: "Curve")]
        let track = NSRect(x: ix + iw - 182, y: top + 10, width: 182, height: 28)
        segmented("fan", modes, selected: modes.firstIndex { $0.id == mode } ?? 0, in: track, enabled: canControl, primary: true) { [weak self] i in
            self?.choose(modes[i].id, l, s)
        }

        var fy = top + 54
        if fans.isEmpty {
            drawText(s == nil ? "—" : "This Mac has no fans.", Theme.font(13), Theme.muted, ix, fy + 8)
            fy += 62
        }
        for (n, fan) in fans.enumerated() {
            let rpmF = Theme.mono(22, .medium)
            let rs = Fmt.rpm(fan.rpm)
            let rw = odometer("fan.rpm\(n)", rs, rpmF, Theme.text, ix, fy - 1)
            drawText(fans.count > 1 ? "rpm · \(n == 0 ? "left" : "right")" : "rpm", Theme.font(12), Theme.muted, ix + rw + 5, fy + 7)
            let tgt = fan.manual ? "target \(Fmt.rpm(fan.target))" : "\(Int(((fan.rpm - fan.min) / max(1, fan.max - fan.min) * 100).rounded()))% of range"
            drawText(tgt, Theme.font(12), Theme.faint, ix + iw, fy + 7, align: .right)

            let tr = NSRect(x: ix, y: fy + 31, width: iw, height: 8)
            meter("fan.bar\(n)", tr, (fan.rpm - fan.min) / max(1, fan.max - fan.min), Theme.soft)
            drawText(Fmt.rpm(fan.min), Theme.font(11), Theme.faint, ix, fy + 43)
            drawText(Fmt.rpm(fan.max), Theme.font(11), Theme.faint, ix + iw, fy + 43, align: .right)

            if mode == "fixed", canControl {
                let target = dragRPM ?? Double(policy.dropFirst().first ?? "") ?? fan.target
                let kx = tr.minX + tr.width * CGFloat((target - fan.min) / max(1, fan.max - fan.min))
                hit(tr.insetBy(dx: -8, dy: -10), "fan.drag\(n)", drag: true) { [weak self] p in
                    let v = fan.min + Double((p.x - tr.minX) / tr.width) * (fan.max - fan.min)
                    let rpm = (min(fan.max, max(fan.min, v)) / 50).rounded() * 50
                    self?.dragRPM = rpm
                    l.setFan("fixed \(Int(rpm))")
                    self?.needsDisplay = true
                }
                let gx = CGFloat(glide("fan.knob\(n)", Double(kx), dur: 0.2))
                fill(NSRect(x: gx - 9, y: tr.midY - 9, width: 18, height: 18), NSColor(white: 0, alpha: 0.35), radius: 9)
                fill(NSRect(x: gx - 8, y: tr.midY - 8, width: 16, height: 16), Theme.text, radius: 8)
            }
            fy += 62
        }

        // What will happen, or what is needed.
        let ny = top + h - 34
        if !canControl || outdated {
            let note = outdated ? "The fan helper here is out of date." : "Needs a one-time setup first."
            drawText(note, Theme.font(12), Theme.muted, ix, ny + 6, maxWidth: iw - 86)
            button("fan.setup", outdated ? "Update" : "Set up", at: NSRect(x: ix + iw - 76, y: ny, width: 76, height: 28)) { [weak self] in self?.onSetup?(l) }
        } else {
            let note: String
            switch mode {
            case "fixed": note = "Holds the speed you set; full speed above \(Int(FanControl.safetyCeiling))°. Back to Auto when Vitals quits."
            case "curve": note = "Follows the CPU: minimum at \(Int(Prefs.curveLow))°, full at \(Int(Prefs.curveHigh))°. Back to Auto when Vitals quits."
            default: note = "macOS is choosing the speed."
            }
            drawText(note, Theme.font(12), Theme.muted, ix, ny + 6, maxWidth: iw)
        }
        y = top + h
    }

    private func hit(_ r: NSRect, _ action: @escaping (NSPoint) -> Void) -> Bool { hit(r, "btn.\(r.minX).\(r.minY)", action) }

    private func choose(_ mode: String, _ l: HostLink, _ s: Snapshot?) {
        dragRPM = nil
        switch mode {
        case "fixed":
            let f = s?.fans.first
            let rpm = f.map { max($0.min, min($0.max, ($0.rpm / 50).rounded() * 50)) } ?? 2000
            l.setFan("fixed \(Int(rpm))")
        case "curve": l.setFan("curve \(Int(Prefs.curveLow)) \(Int(Prefs.curveHigh))")
        default: l.setFan("auto")
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) { super.mouseUp(with: e); dragRPM = nil }

    // MARK: pressure

    /// Six stat tiles, the kit's KPI cards: a swatch and label, a monospaced number, and below it the
    /// detail that explains the number (per-core bars, a two-minute sparkline, a meter or rates).
    private func pressureGrid(_ l: HostLink, _ s: Snapshot?, x: CGFloat, y: inout CGFloat) {
        let tg: CGFloat = 10, tw = (colW - tg) / 2, th: CGFloat = 112, top = y
        func tileRect(_ i: Int) -> NSRect { NSRect(x: x + CGFloat(i % 2) * (tw + tg), y: top + CGFloat(i / 2) * (th + tg), width: tw, height: th) }
        let inner = tw - 28

        // CPU: one bar per core, the chip drawn as itself; each bar glides to its core's load.
        var r = tileRect(0)
        tile(r, "CPU", swatch: Theme.accent, value: s?.cpu.map { Fmt.pct($0) } ?? "—",
             note: s.map { "load " + String(format: "%.1f", $0.load.first ?? 0) })
        if let s, !s.cores.isEmpty {
            let n = CGFloat(s.cores.count), bx = r.minX + 14
            let clusterGap: CGFloat = s.eCores > 0 ? 4 : 0
            let bw = (inner - (n - 1) * 2 - clusterGap) / n
            let by = r.minY + 66, bh: CGFloat = 26
            for (i, c) in s.cores.enumerated() {
                let cx = bx + CGFloat(i) * (bw + 2) + (i >= s.eCores && s.eCores > 0 ? clusterGap : 0)
                fill(NSRect(x: cx, y: by, width: bw, height: bh), Theme.raised, radius: min(2, bw / 2))
                let load = glide("core.\(i)", min(100, max(0, c)) / 100)
                let fh = max(2, bh * CGFloat(load))
                fill(NSRect(x: cx, y: by + bh - fh, width: bw, height: fh), Theme.accent.withAlphaComponent(0.45 + 0.55 * CGFloat(load)), radius: min(2, bw / 2))
            }
            let legend = s.eCores > 0 ? "\(s.eCores) E · \(s.cores.count - s.eCores) P cores" : "\(s.cores.count) cores"
            drawText(legend, Theme.font(11), Theme.faint, bx, by + bh + 4, maxWidth: inner)
        }

        // Memory: used of total, the pressure macOS reports, and the last two minutes.
        r = tileRect(1)
        if let s {
            let p = s.pressure >= 4 ? ("Critical", Theme.pillBad) : s.pressure >= 2 ? ("Warning", Theme.pillWarn) : ("Normal", Theme.pillGood)
            tile(r, "Memory", swatch: Theme.series3, value: Fmt.gb(s.memUsed), unit: "/ \(Fmt.gb(s.memTotal, 0)) GB", pill: p)
            spark(l.trend["mem"], in: NSRect(x: r.minX + 14, y: r.minY + 64, width: inner, height: 24), color: Theme.series3, minSpan: 4)
            let swap = s.swapUsed > 0 ? "\(Fmt.gb(s.swapUsed)) GB in swap" : "\(Fmt.gb(s.memCompressed)) GB compressed"
            drawText(swap, Theme.font(11), s.swapUsed > 1_073_741_824 ? Theme.warning : Theme.faint,
                     r.minX + 14, r.minY + 92, maxWidth: inner)
        } else { tile(r, "Memory", swatch: Theme.series3, value: "—") }

        // Thermal: the hottest CPU sensor, macOS's thermal state, and the last two minutes.
        r = tileRect(2)
        if let s {
            let states = [("Nominal", Theme.pillGood), ("Fair", Theme.pillWarn), ("Serious", Theme.pillBad), ("Critical", Theme.pillBad)]
            let hot = s.tCPU ?? 0
            let tone = hot >= 90 ? Theme.negative : hot >= 80 ? Theme.warning : Theme.soft
            tile(r, "Thermal", swatch: tone, value: s.tCPU.map { Fmt.temp($0) } ?? "—", unit: s.tCPU == nil ? nil : "CPU",
                 pill: states[min(3, max(0, s.thermal))])
            spark(l.trend["temp"], in: NSRect(x: r.minX + 14, y: r.minY + 64, width: inner, height: 24), color: tone, minSpan: 6)
            var parts: [String] = []
            if let g = s.tGPU { parts.append("GPU \(Fmt.temp(g))") }
            if let d = s.tSSD { parts.append("SSD \(Fmt.temp(d))") }
            if parts.count < 2, let b = s.battery?.temp { parts.append("battery \(Fmt.temp(b))") }
            drawText(parts.joined(separator: " · "), Theme.font(11), Theme.faint, r.minX + 14, r.minY + 92, maxWidth: inner)
        } else { tile(r, "Thermal", swatch: Theme.soft, value: "—") }

        // GPU: busy share, what it draws, and the last two minutes.
        r = tileRect(3)
        tile(r, "GPU", swatch: Theme.chart2, value: s?.gpu.map { Fmt.pct($0) } ?? "—")
        if let s {
            spark(l.trend["gpu"], in: NSRect(x: r.minX + 14, y: r.minY + 64, width: inner, height: 24), color: Theme.chart2, minSpan: 10)
            drawText("drawing \(Fmt.wattsUnit(s.wGPU))", Theme.font(11), Theme.faint, r.minX + 14, r.minY + 92, maxWidth: inner)
        }

        // Storage: the boot drive free, then any other local drive.
        r = tileRect(4)
        if let s, let boot = s.volumes.first(where: \.boot) ?? s.volumes.first {
            let freeShare = boot.free / max(1, boot.total)
            let p = freeShare < 0.05 || boot.free < 8e9 ? ("Almost full", Theme.pillBad) : freeShare < 0.12 ? ("Low", Theme.pillWarn) : nil
            let size = Fmt.size(boot.free).split(separator: " ").map(String.init)
            tile(r, "Storage free", swatch: Theme.soft, value: size.first ?? "—", unit: size.count > 1 ? size[1] : nil, pill: p)
            let usedColor = freeShare < 0.05 ? Theme.negative : freeShare < 0.12 ? Theme.warning : Theme.soft
            meter("disk.bar", NSRect(x: r.minX + 14, y: r.minY + 70, width: inner, height: 6), 1 - freeShare, usedColor, track: Theme.raisedHi)
            drawText("\(Fmt.size(boot.total - boot.free)) of \(Fmt.size(boot.total)) used", Theme.font(11), Theme.faint, r.minX + 14, r.minY + 86, maxWidth: inner)
        } else { tile(r, "Storage free", swatch: Theme.soft, value: "—") }

        // Network and disk throughput.
        r = tileRect(5)
        card(r, radius: 14)
        drawText("Network · disk", Theme.font(12, .medium), Theme.muted, r.minX + 14, r.minY + 13)
        let rows: [(String, Double?)] = [("in", s?.netIn), ("out", s?.netOut), ("read", s?.diskRead), ("write", s?.diskWrite)]
        for (j, (name, v)) in rows.enumerated() {
            let ry = r.minY + 36 + CGFloat(j) * 17
            drawText(name, Theme.font(12), Theme.muted, r.minX + 14, ry)
            drawText(Fmt.rate(v), Theme.font(12, .medium), Theme.text, r.maxX - 14, ry, align: .right)
        }
        y = top + th * 3 + tg * 2
    }

    /// One stat tile: a swatch and label (a state pill or a note at the right), then the number.
    private func tile(_ r: NSRect, _ label: String, swatch: NSColor, value: String, unit: String? = nil,
                      pill p: (String, (NSColor, NSColor))? = nil, note: String? = nil) {
        card(r, radius: 14)
        fill(NSRect(x: r.minX + 14, y: r.minY + 17, width: 8, height: 8), swatch, radius: 3)
        drawText(label, Theme.font(12, .medium), Theme.muted, r.minX + 28, r.minY + 13)
        if let p { pill(p.0, p.1, right: r.maxX - 12, r.minY + 12) }
        else if let note { drawText(note, Theme.font(11), Theme.faint, r.maxX - 14, r.minY + 14, align: .right) }
        let vf = Theme.mono(22, .medium)
        let vw = odometer("tile.\(label)", value, vf, Theme.text, r.minX + 14, r.minY + 33)
        if let unit { drawText(unit, Theme.font(12), Theme.muted, r.minX + 14 + vw + 4, r.minY + 42, maxWidth: r.width - 32 - vw) }
    }

    /// A two-minute sparkline in a series colour, with the kit's faint area under it and the newest
    /// reading marked. Scaled to its own range (at least `minSpan`), so small movements still show.
    private func spark(_ values: [Double]?, in r: NSRect, color: NSColor, minSpan: Double) {
        guard let v = values, v.count > 1 else {
            hline(r.minX, r.midY, r.width, Theme.line2, dash: true); return
        }
        var lo = v.min()!, hi = v.max()!
        if hi - lo < minSpan { let mid = (hi + lo) / 2; lo = mid - minSpan / 2; hi = mid + minSpan / 2 }
        let slots = Double(max(v.count - 1, 30))
        func pt(_ i: Int) -> NSPoint {
            NSPoint(x: r.maxX - CGFloat(Double(v.count - 1 - i) / slots) * r.width,
                    y: r.maxY - CGFloat((v[i] - lo) / (hi - lo)) * r.height)
        }
        let line = NSBezierPath(); line.move(to: pt(0))
        for i in 1..<v.count { line.line(to: pt(i)) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: pt(v.count - 1).x, y: r.maxY)); area.line(to: NSPoint(x: pt(0).x, y: r.maxY)); area.close()
        let reveal = drawIn()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: r.minX - 2, y: r.minY - 3, width: (r.width + 4) * reveal, height: r.height + 6).clip()
        color.withAlphaComponent(0.16).setFill(); area.fill()
        line.lineWidth = 1.75; line.lineJoinStyle = .round; line.lineCapStyle = .round
        color.setStroke(); line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if reveal >= 1 { let p = pt(v.count - 1); fill(NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5), color, radius: 2.5) }
    }

    // MARK: network and disk

    // MARK: processes

    private func procCard(_ s: Snapshot?, x: CGFloat, y: inout CGFloat, bottom: CGFloat) {
        let w = colW, top = y, h = max(120, bottom - top), ix = x + 14, iw = w - 28
        card(NSRect(x: x, y: top, width: w, height: h))
        drawText("Using the CPU now", Theme.font(13, .semibold), Theme.text, ix, top + 15)
        let memX = ix + iw, cpuX = memX - 74
        drawText("CPU", Theme.font(11), Theme.faint, cpuX, top + 16, align: .right)
        drawText("Memory", Theme.font(11), Theme.faint, memX, top + 16, align: .right)
        let rows = Int((h - 44) / 27)
        let procs = Array((s?.procs ?? []).prefix(max(0, rows)))
        if procs.isEmpty {
            drawText(s == nil ? "—" : "Measuring…", Theme.font(12), Theme.faint, ix, top + 44)
        }
        let maxCPU = max(100, procs.first?.cpu ?? 100)
        for (i, p) in procs.enumerated() {
            let ry = top + 40 + CGFloat(i) * 27
            if i > 0 { hline(ix, ry - 4, iw, Theme.line) }
            drawText(p.name, Theme.font(13), Theme.text, ix, ry, maxWidth: cpuX - ix - 48)
            drawText(String(format: "%.1f%%", p.cpu), Theme.mono(12.5, .medium), Theme.text, cpuX, ry + 1, align: .right)
            drawText("\(Fmt.gb(p.mem)) GB", Theme.font(13), Theme.muted, memX, ry, align: .right)
            // A share bar under the name, gliding; the top process in the CPU's colour. Keyed by
            // name so a process keeps its bar when the order changes.
            let share = glide("proc.\(p.name)", min(1, p.cpu / maxCPU))
            let track = NSRect(x: ix, y: ry + 20, width: cpuX - ix - 48, height: 3)
            fill(track, Theme.raised, radius: 1.5)
            fill(NSRect(x: ix, y: track.minY, width: max(3, track.width * CGFloat(share)), height: 3), i == 0 ? Theme.accent : Theme.line3, radius: 1.5)
        }
        y = top + h
    }

    // MARK: footer

    private func footer(_ l: HostLink, _ s: Snapshot?, y: CGFloat) {
        hline(0, y - 2, Self.width, Theme.line)
        var info = s.map { "Up \(Fmt.duration($0.uptime))" } ?? ""
        if let s, s.load.count == 3 { info += " · load " + s.load.map { String(format: "%.1f", $0) }.joined(separator: " / ") }
        drawText(info.isEmpty ? "Logging every minute on each Mac" : info + " · logging every minute", Theme.font(12), Theme.faint, pad, y + 10)
        var x = Self.width - pad
        // Screen: that Mac's screen in the browser, when it has `vitals-agent screen on`.
        let screen = l.info?.screen.flatMap(URL.init(string:)).map { url in { NSWorkspace.shared.open(url); () } }
        let buttons: [(String, String, (() -> Void)?)] = [("quit", "Quit", onQuit), ("settings", "Settings", onSettings),
                                                          ("logs", "Log files", onOpenLogs)] + (screen.map { [("screen", "Screen", $0)] } ?? [])
        for (id, name, action) in buttons {
            let f = Theme.font(12, .medium), w = textWidth(name, f)
            let r = NSRect(x: x - w - 10, y: y + 4, width: w + 20, height: 26)
            let hov = hit(r, "foot.\(id)") { _ in action?() }
            if hov { fill(r, Theme.raised, radius: 13); stroke(r, Theme.line2, radius: 13) }
            drawText(name, f, hov || id == "screen" ? Theme.text : Theme.muted, x, y + 10, align: .right)
            x -= w + 22
        }
    }
}
