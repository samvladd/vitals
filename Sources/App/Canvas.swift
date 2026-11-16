import AppKit

/// A flipped view that draws everything itself and keeps a list of clickable regions per frame.
/// One view instead of hundreds keeps the app small and the redraw cheap.
class Canvas: NSView {
    struct Hit { let rect: NSRect; let id: String; let drag: Bool; let action: (NSPoint) -> Void }
    private var hits: [Hit] = []
    private(set) var hover: String?
    private var pressed: Hit?
    /// How far the content is scrolled up: Settings with many Macs can be taller than the screen.
    var scrollY: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    static var draws = 0, drawTime = 0.0
    override func draw(_ dirty: NSRect) {
        let t0 = CFAbsoluteTimeGetCurrent()
        hits.removeAll(keepingCapacity: true)
        now = CACurrentMediaTime()
        moving = false
        if scrollY != 0 { NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: -scrollY) }
        touched.removeAll(keepingCapacity: true)
        odoTouched.removeAll(keepingCapacity: true)
        render()
        // Forget values that were not drawn this time (a process that quit, a Mac switched away from).
        if tweens.count > touched.count { tweens = tweens.filter { touched.contains($0.key) } }
        if odos.count > odoTouched.count { odos = odos.filter { odoTouched.contains($0.key) } }
        revealing = false
        moving ? startFrames() : stopFrames()
        Canvas.draws += 1; Canvas.drawTime += CFAbsoluteTimeGetCurrent() - t0
    }

    func render() {}

    // MARK: motion (the Aegis kit's count, draw and glide)
    //
    // Values glide to each new reading instead of jumping; on open the cards arrive one after another,
    // numbers count up and the chart draws itself in. Frames run only while something is moving, so a
    // still panel costs nothing, and Reduce Motion turns all of it off.

    private struct Tween { var from, to: Double; var start: CFTimeInterval; var dur: Double; var bounce: Bool }
    private var tweens: [String: Tween] = [:]
    private var touched: Set<String> = []
    private var frameTimer: Timer?
    private var now: CFTimeInterval = 0
    private var moving = false
    /// True for the first draw after `reveal()`: every value starts from zero.
    private var revealing = false
    private var revealAt: CFTimeInterval = -10
    /// Off for Reduce Motion, and for `--render`, whose snapshots must show values at rest.
    static var still = false
    static let reduceMotion = { still || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Replays the arrival: cards rise in, numbers count up from zero, charts draw.
    func reveal() {
        tweens.removeAll()
        odos.removeAll()
        guard !Self.reduceMotion() else { return }
        revealing = true
        revealAt = CACurrentMediaTime()
        needsDisplay = true
    }

    /// The value to draw for `key` now, gliding to `target` whenever it changes. `bounce` adds the
    /// kit's soft spring overshoot (for things that slide, not for numbers).
    func glide(_ key: String, _ target: Double, dur: Double = 0.34, bounce: Bool = false) -> Double {
        if Self.reduceMotion() { return target }
        touched.insert(key)
        if var t = tweens[key] {
            let cur = value(t)
            if abs(t.to - target) > 1e-6 {
                t = Tween(from: cur, to: target, start: now, dur: dur, bounce: bounce)
                tweens[key] = t
                moving = true
                return cur
            }
            if now < t.start + t.dur { moving = true }
            return cur
        }
        let from = revealing ? 0 : target
        tweens[key] = Tween(from: from, to: target, start: now, dur: revealing ? 0.9 : dur, bounce: bounce)
        if from != target { moving = true }
        return from
    }

    // MARK: odometer (the kit's K2.odometer)
    //
    // A figure changes once a second, all together, like the plain panel; only the digits that changed
    // roll, each on its own strip of 0–9: up when the value rose, down when it fell, the last digit
    // first and each one to its left 45 ms later, over 800 ms on the kit's curve, faded at the strip's
    // top and bottom edges. When the panel opens the figures roll up from zeros (1.1 s, 55 ms apart).

    private struct Odo { var from: String; var to: String; var start: CFTimeInterval; var up: Bool; var dur: Double; var stagger: Double }
    private var odos: [String: Odo] = [:]
    private var odoTouched: Set<String> = []

    /// Draws `text` as an odometer under `key`; returns its width.
    @discardableResult
    func odometer(_ key: String, _ text: String, _ font: NSFont, _ color: NSColor, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        odoTouched.insert(key)
        if Self.reduceMotion() { return drawNumber(text, font, color, x, y) }
        var o: Odo
        if let old = odos[key] {
            o = old
            if old.to != text {
                func num(_ s: String) -> Double { Double(s.filter { $0.isNumber || $0 == "." || $0 == "-" }) ?? 0 }
                o = Odo(from: old.to, to: text, start: now, up: num(text) >= num(old.to), dur: 0.8, stagger: 0.045)
            }
        } else if revealing {
            o = Odo(from: String(text.map { $0.isNumber ? "0" : $0 }), to: text, start: now, up: true, dur: 1.1, stagger: 0.055)
        } else {
            o = Odo(from: text, to: text, start: now, up: true, dur: 0.8, stagger: 0.045)
        }
        odos[key] = o

        let kern = -0.02 * font.pointSize
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let lh = ceil(font.ascender - font.descender + font.leading)
        let to = Array(o.to), from = Array(o.from), pad = from.count - to.count
        // Lay out left to right, then roll right to left: the rightmost digit has no delay.
        var xs: [CGFloat] = [], cx = x
        for c in to { xs.append(cx); cx += (String(c) as NSString).size(withAttributes: attrs).width }
        var order = 0
        for i in stride(from: to.count - 1, through: 0, by: -1) {
            let c = to[i]
            guard let cd = c.wholeNumberValue else { (String(c) as NSString).draw(at: NSPoint(x: xs[i], y: y), withAttributes: attrs); continue }
            let pc: Character? = i + pad >= 0 && i + pad < from.count ? from[i + pad] : nil
            let pd = pc?.wholeNumberValue ?? (o.up ? 0 : 9)
            var s = 10 + pd
            let e = pc == c ? 10 + cd : o.up ? (cd >= pd ? 10 + cd : 20 + cd) : (cd <= pd ? 10 + cd : cd)
            if pc == c { s = e }
            let p = min(1, max(0, (now - o.start - Double(order) * o.stagger) / o.dur))
            order += 1
            if s == e || p >= 1 { (String(c) as NSString).draw(at: NSPoint(x: xs[i], y: y), withAttributes: attrs); continue }
            moving = true
            let off = Double(s) + Double(e - s) * Self.odoEase(p)
            let w = (i + 1 < xs.count ? xs[i + 1] : cx) - xs[i]
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: xs[i], y: y, width: w + 1, height: lh).clip()
            for k in [Int(off.rounded(.down)), Int(off.rounded(.down)) + 1] {
                let f = CGFloat(Double(k) - off)          // -1…1: where this digit sits in the window
                let a = max(0, 1 - abs(f) * 1.15)         // the kit's mask: faded toward the edges
                guard a > 0.01 else { continue }
                var da = attrs; da[.foregroundColor] = color.withAlphaComponent(color.alphaComponent * a)
                ("\(((k % 10) + 10) % 10)" as NSString).draw(at: NSPoint(x: xs[i], y: y + f * lh), withAttributes: da)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return cx - x
    }

    /// The kit's odometer curve, cubic-bezier(.3, .75, .1, 1).
    private static func odoEase(_ p: Double) -> Double {
        let (x1, y1, x2, y2) = (0.3, 0.75, 0.1, 1.0)
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        var t = p
        for _ in 0..<8 {
            let x = bez(t, x1, x2) - p
            let dx = 3 * (1 - t) * (1 - t) * x1 + 6 * (1 - t) * t * (x2 - x1) + 3 * t * t * (1 - x2)
            if abs(x) < 1e-5 || dx == 0 { break }
            t = min(1, max(0, t - x / dx))
        }
        return bez(t, y1, y2)
    }

    private func value(_ t: Tween) -> Double {
        let p = min(1, max(0, (now - t.start) / t.dur))
        // Ease out (the kit's --out), or a soft spring that settles past and back.
        let e = t.bounce ? 1 + 2.2 * pow(p - 1, 3) + 1.2 * pow(p - 1, 2) : 1 - pow(1 - p, 3)
        return t.from + (t.to - t.from) * e
    }

    /// How far the arrival has got for the `index`th card: 0 → 1 over 0.56 s, 60 ms apart.
    func arrival(_ index: Int) -> CGFloat {
        let p = (now - revealAt - Double(index) * 0.06) / 0.56
        if p < 1 { moving = true }
        return CGFloat(1 - pow(1 - min(1, max(0, p)), 3))
    }

    private var chartAt: CFTimeInterval = -10
    /// Draws the chart in again (a new range), without replaying the rest.
    func replayChart() { if !Self.reduceMotion() { chartAt = CACurrentMediaTime() - 0.12; needsDisplay = true } }

    /// The chart's draw-in: 0 → 1 over 0.9 s after the arrival.
    func drawIn() -> CGFloat {
        let p = (now - max(revealAt, chartAt) - 0.12) / 0.9
        if p < 1 { moving = true }
        return CGFloat(1 - pow(1 - min(1, max(0, p)), 3))
    }

    /// Draws `body` faded and lifted by how far its arrival has got.
    func arriving(_ index: Int, _ body: () -> Void) {
        let a = arrival(index)
        guard a < 1, let g = NSGraphicsContext.current?.cgContext else { body(); return }
        g.saveGState()
        g.setAlpha(a)
        g.translateBy(x: 0, y: (1 - a) * 10)
        body()
        g.restoreGState()
    }

    // MARK: kit parts

    /// A card: graphite with a hairline border and a lit top edge (the kit's --e1), never a hard shadow.
    func card(_ r: NSRect, radius: CGFloat = 16) {
        fill(r, Theme.card, radius: radius)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        fill(NSRect(x: r.minX, y: r.minY, width: r.width, height: 1), Theme.edge)
        NSGraphicsContext.restoreGraphicsState()
        stroke(r, Theme.line, radius: radius)
    }

    /// A rounded meter whose fill glides to `frac` (0…1).
    func meter(_ key: String, _ r: NSRect, _ frac: Double, _ color: NSColor, track: NSColor = Theme.raised) {
        fill(r, track, radius: r.height / 2)
        let f = min(1, max(0, glide(key, min(1, max(0, frac)))))
        guard f > 0.002 else { return }
        fill(NSRect(x: r.minX, y: r.minY, width: max(r.height, r.width * CGFloat(f)), height: r.height), color, radius: r.height / 2)
    }

    /// A segmented control whose selection slides to the choice (the kit's "every choice moves").
    /// `primary` makes the chosen one the kit's main action: off-white with dark text. Hit ids are
    /// "<id>.<item id>", which the self-test clicks by name.
    func segmented(_ id: String, _ items: [(id: String, label: String)], selected: Int, in track: NSRect,
                   enabled: Bool = true, primary: Bool = false, _ action: @escaping (Int) -> Void) {
        let rad = track.height / 2
        fill(track, Theme.sunk, radius: rad)
        stroke(track, Theme.line, radius: rad)
        let segW = (track.width - 4) / CGFloat(items.count)
        if items.indices.contains(selected) {
            let pos = glide("seg.\(id)", Double(selected), dur: 0.42, bounce: true)
            let knob = NSRect(x: track.minX + 2 + CGFloat(pos) * segW, y: track.minY + 2, width: segW, height: track.height - 4)
            fill(knob, primary ? (enabled ? Theme.text : Theme.chart3) : Theme.raisedHi, radius: knob.height / 2)
            if !primary { stroke(knob, Theme.line2, radius: knob.height / 2) }
        }
        let f = Theme.font(12, .medium)
        for (i, item) in items.enumerated() {
            let r = NSRect(x: track.minX + 2 + CGFloat(i) * segW, y: track.minY + 2, width: segW, height: track.height - 4)
            let hov = enabled && hit(r, "\(id).\(item.id)") { _ in action(i) }
            let on = i == selected
            let c: NSColor = on ? (primary ? Theme.ground : Theme.text) : !enabled ? Theme.faint : hov ? Theme.text : Theme.muted
            drawText(item.label, f, c, r.midX, r.midY - 8, align: .center)
        }
    }

    /// A button: `primary` is the kit's off-white main action, otherwise a raised graphite one.
    @discardableResult
    func button(_ id: String, _ label: String, at r: NSRect, primary: Bool = false, _ action: @escaping () -> Void) -> NSRect {
        let hov = hit(r, id) { _ in action() }
        let rad = r.height / 2
        if primary {
            fill(r, hov ? NSColor.white : Theme.text, radius: rad)
        } else {
            fill(r, hov ? Theme.raisedHi : Theme.raised, radius: rad)
            stroke(r, hov ? Theme.line3 : Theme.line2, radius: rad)
        }
        drawText(label, Theme.font(12, .semibold), primary ? Theme.ground : Theme.text, r.midX, r.midY - 8, align: .center)
        return r
    }

    private func startFrames() {
        guard frameTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }
    private func stopFrames() { frameTimer?.invalidate(); frameTimer = nil }

    /// Registers a clickable region; returns whether it is hovered (for hover styling).
    @discardableResult
    func hit(_ r: NSRect, _ id: String, drag: Bool = false, _ action: @escaping (NSPoint) -> Void) -> Bool {
        hits.append(Hit(rect: r, id: id, drag: drag, action: action))
        return hover == id || pressed?.id == id
    }

    /// Runs the click handler registered under `id` (used by the self-test).
    @discardableResult
    func perform(_ id: String) -> Bool {
        display()
        guard let h = hits.last(where: { $0.id == id }) else { return false }
        h.action(NSPoint(x: h.rect.midX, y: h.rect.midY)); display(); return true
    }

    private func hitAt(_ p: NSPoint) -> Hit? { hits.last { $0.rect.contains(p) } }
    /// The event's position in content coordinates (where the hit regions were registered).
    private func point(_ e: NSEvent) -> NSPoint { let p = convert(e.locationInWindow, from: nil); return NSPoint(x: p.x, y: p.y + scrollY) }

    override func mouseMoved(with e: NSEvent) {
        let id = hitAt(point(e))?.id
        if id != hover { hover = id; needsDisplay = true }
        (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }
    override func mouseExited(with e: NSEvent) { if hover != nil { hover = nil; needsDisplay = true }; NSCursor.arrow.set() }

    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        pressed = hitAt(p)
        if let h = pressed, h.drag { h.action(p) }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        if let h = pressed, h.drag { h.action(point(e)) }
    }
    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        if let h = pressed, !h.drag, h.rect.contains(p) { h.action(p) }
        pressed = nil
        needsDisplay = true
    }
}

// MARK: drawing helpers

enum Align { case left, right, center }

@discardableResult
func drawText(_ s: String, _ font: NSFont, _ color: NSColor, _ x: CGFloat, _ y: CGFloat,
              align: Align = .left, maxWidth: CGFloat? = nil) -> CGSize {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    var str = s
    var size = (str as NSString).size(withAttributes: attrs)
    if let mw = maxWidth, size.width > mw {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = p
        while size.width > mw, str.count > 1 { str.removeLast(); size = ((str + "…") as NSString).size(withAttributes: attrs) }
        str += "…"
    }
    let ox: CGFloat = align == .left ? x : align == .right ? x - size.width : x - size.width / 2
    (str as NSString).draw(at: NSPoint(x: ox, y: y), withAttributes: attrs)
    return size
}

func textWidth(_ s: String, _ font: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }

/// A large number, tightened as the kit sets its figures (−0.02 em); returns its width.
@discardableResult
func drawNumber(_ s: String, _ font: NSFont, _ color: NSColor, _ x: CGFloat, _ y: CGFloat, align: Align = .left) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: -0.02 * font.pointSize]
    let w = (s as NSString).size(withAttributes: attrs).width
    let ox = align == .left ? x : align == .right ? x - w : x - w / 2
    (s as NSString).draw(at: NSPoint(x: ox, y: y), withAttributes: attrs)
    return w
}

func fill(_ r: NSRect, _ c: NSColor, radius: CGFloat = 0) {
    c.setFill()
    radius > 0 ? NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() : r.fill()
}

func stroke(_ r: NSRect, _ c: NSColor, radius: CGFloat = 0, width: CGFloat = 1) {
    c.setStroke()
    let p = NSBezierPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
    p.lineWidth = width; p.stroke()
}

func hline(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: NSColor, dash: Bool = false) {
    c.setStroke()
    let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: y + 0.5)); p.line(to: NSPoint(x: x + w, y: y + 0.5))
    p.lineWidth = 1
    if dash { p.setLineDash([3, 3], count: 2, phase: 0) }
    p.stroke()
}

func vline(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat, _ c: NSColor) {
    c.setStroke()
    let p = NSBezierPath(); p.move(to: NSPoint(x: x + 0.5, y: y)); p.line(to: NSPoint(x: x + 0.5, y: y + h))
    p.lineWidth = 1; p.stroke()
}

/// The widest any one label may be so that all of them fit in `total`: short labels keep their width
/// and the long ones share what is left (and are truncated to it).
func labelCap(_ natural: [CGFloat], fitting total: CGFloat) -> CGFloat {
    guard natural.reduce(0, +) > total else { return .greatestFiniteMagnitude }
    var rest = total
    for (i, w) in natural.sorted().enumerated() {
        let share = rest / CGFloat(natural.count - i)
        if w > share { return max(24, share) }
        rest -= w
    }
    return .greatestFiniteMagnitude
}

/// A pale pill with dark text of the same hue; returns its width.
@discardableResult
func pill(_ s: String, _ colors: (NSColor, NSColor), right x: CGFloat, _ y: CGFloat) -> CGFloat {
    let f = Theme.font(11, .medium)
    let w = textWidth(s, f) + 14
    fill(NSRect(x: x - w, y: y, width: w, height: 18), colors.0, radius: 9)
    drawText(s, f, colors.1, x - w + 7, y + 2)
    return w
}

/// Nice round axis steps above the maximum.
func niceCeiling(_ v: Double) -> (top: Double, step: Double) {
    let v = max(v, 1)
    let mag = pow(10, floor(log10(v)))
    for m in [1.0, 2, 2.5, 5, 10] where m * mag * 4 >= v * 1.08 {
        let step = m * mag
        let top = (v * 1.08 / step).rounded(.up) * step
        return (top, step)
    }
    return (v * 1.2, v * 0.3)
}
