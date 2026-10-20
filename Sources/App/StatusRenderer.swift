import AppKit

/// The menu bar item: for each Mac shown, a small outline of the machine, then watts over the CPU
/// temperature. Drawn as a template image so it follows the menu bar's light or dark look.
enum StatusRenderer {
    /// Whole watts: steadier in the menu bar, and fewer redraws.
    static func watts(_ w: Double?) -> String { w.map { String(format: "%.0f W", $0) } ?? "—" }

    static func image(for links: [HostLink]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let blocks: [(HostLink, String, String)] = links.map { l in
            guard l.state == .live, let s = l.snap else { return (l, "—", "") }
            return (l, watts(s.wSystem), Fmt.temp(s.tCPU))
        }
        let widths = blocks.map { b in 15 + max((b.1 as NSString).size(withAttributes: attrs).width, (b.2 as NSString).size(withAttributes: attrs).width) }
        let size = NSSize(width: widths.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * 8, height: 22)
        let img = NSImage(size: size, flipped: true) { _ in
            var x: CGFloat = 0
            for (i, (l, top, bottom)) in blocks.enumerated() {
                NSColor.black.setStroke(); NSColor.black.setFill()
                if l.isLocal {
                    let screen = NSBezierPath(roundedRect: NSRect(x: x + 1.5, y: 6, width: 10, height: 7.5), xRadius: 1.2, yRadius: 1.2)
                    screen.lineWidth = 1.2; screen.stroke()
                    NSBezierPath(roundedRect: NSRect(x: x, y: 14.6, width: 13, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
                } else {
                    let box = NSBezierPath(roundedRect: NSRect(x: x + 1, y: 5.5, width: 11, height: 11), xRadius: 2.6, yRadius: 2.6)
                    box.lineWidth = 1.2; box.stroke()
                    NSBezierPath(roundedRect: NSRect(x: x + 5.5, y: 12.6, width: 2, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
                }
                if bottom.isEmpty {
                    (top as NSString).draw(at: NSPoint(x: x + 15, y: 5), withAttributes: attrs)
                } else {
                    (top as NSString).draw(at: NSPoint(x: x + 15, y: 0), withAttributes: attrs)
                    (bottom as NSString).draw(at: NSPoint(x: x + 15, y: 10), withAttributes: attrs)
                }
                x += widths[i] + 8
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
