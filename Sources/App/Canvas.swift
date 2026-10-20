import AppKit

/// A flipped view that draws everything itself and keeps a list of clickable regions per frame.
/// One view instead of hundreds keeps the app small and the redraw cheap.
class Canvas: NSView {
    struct Hit { let rect: NSRect; let id: String; let drag: Bool; let action: (NSPoint) -> Void }
    private var hits: [Hit] = []
    private(set) var hover: String?
    private var pressed: Hit?

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
        render()
        Canvas.draws += 1; Canvas.drawTime += CFAbsoluteTimeGetCurrent() - t0
    }

    func render() {}

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

    override func mouseMoved(with e: NSEvent) {
        let id = hitAt(convert(e.locationInWindow, from: nil))?.id
        if id != hover { hover = id; needsDisplay = true }
        (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }
    override func mouseExited(with e: NSEvent) { if hover != nil { hover = nil; needsDisplay = true }; NSCursor.arrow.set() }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        pressed = hitAt(p)
        if let h = pressed, h.drag { h.action(p) }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        if let h = pressed, h.drag { h.action(convert(e.locationInWindow, from: nil)) }
    }
    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
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
