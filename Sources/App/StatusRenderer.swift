import AppKit

/// The menu bar item: for each Mac shown, a small outline of the machine, then watts over the CPU
/// temperature. Three Macs or more fold into one reading (a stack, the fleet's total watts over its
/// hottest CPU), since N blocks would crowd the menu bar. Drawn as a template image so it follows
/// the menu bar's light or dark look.
enum StatusRenderer {
    enum Icon { case laptop, box, stack }
    typealias Reading = (icon: Icon, top: String, bottom: String)

    /// Whole watts: steadier in the menu bar, and fewer redraws.
    static func watts(_ w: Double?) -> String { w.map { String(format: "%.0f W", $0) } ?? "—" }

    /// What the menu bar shows for these Macs; also the key that decides whether it needs a redraw.
    static func readings(for links: [HostLink]) -> [Reading] {
        if links.count >= 3 {
            let snaps = links.compactMap { $0.state == .live ? $0.snap : nil }
            guard !snaps.isEmpty else { return [(.stack, "—", "")] }
            let total = snaps.compactMap(\.wSystem).reduce(0, +)
            return [(.stack, watts(total), Fmt.temp(snaps.compactMap(\.tCPU).max()))]
        }
        return links.map { l in
            let icon: Icon = l.isLocal ? .laptop : .box
            guard l.state == .live, let s = l.snap else { return (icon, "—", "") }
            return (icon, watts(s.wSystem), Fmt.temp(s.tCPU))
        }
    }

    /// One line per Mac, with the fleet's total first when the menu bar shows the folded reading.
    static func tooltip(for links: [HostLink]) -> String {
        var lines = links.map { l -> String in
            let name = l.name(among: links)
            switch l.state {
            case .live: return "\(name): \(Fmt.wattsUnit(l.snap?.wSystem)), CPU \(Fmt.temp(l.snap?.tCPU))"
            case .offline: return "\(name): offline"
            default: return "\(name): connecting…"
            }
        }
        if links.count >= 3, let r = readings(for: links).first, !r.bottom.isEmpty {
            let live = links.filter { $0.state == .live }.count
            lines.insert("\(live) of \(links.count) Macs: \(r.top) in all, hottest CPU \(r.bottom)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func image(for links: [HostLink]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let blocks = readings(for: links)
        let widths = blocks.map { b in 15 + max((b.top as NSString).size(withAttributes: attrs).width, (b.bottom as NSString).size(withAttributes: attrs).width) }
        let size = NSSize(width: widths.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * 8, height: 22)
        let img = NSImage(size: size, flipped: true) { _ in
            var x: CGFloat = 0
            for (i, b) in blocks.enumerated() {
                NSColor.black.setStroke(); NSColor.black.setFill()
                switch b.icon {
                case .laptop:
                    let screen = NSBezierPath(roundedRect: NSRect(x: x + 1.5, y: 6, width: 10, height: 7.5), xRadius: 1.2, yRadius: 1.2)
                    screen.lineWidth = 1.2; screen.stroke()
                    NSBezierPath(roundedRect: NSRect(x: x, y: 14.6, width: 13, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
                case .box:
                    let box = NSBezierPath(roundedRect: NSRect(x: x + 1, y: 5.5, width: 11, height: 11), xRadius: 2.6, yRadius: 2.6)
                    box.lineWidth = 1.2; box.stroke()
                    NSBezierPath(roundedRect: NSRect(x: x + 5.5, y: 12.6, width: 2, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
                case .stack:
                    // Three Mac minis seen from the side, stacked: the fleet.
                    for sy in [4.6, 9.0, 13.4] as [CGFloat] {
                        let slab = NSBezierPath(roundedRect: NSRect(x: x + 0.6, y: sy, width: 11.8, height: 3.4), xRadius: 1.2, yRadius: 1.2)
                        slab.lineWidth = 1.1; slab.stroke()
                    }
                }
                if b.bottom.isEmpty {
                    (b.top as NSString).draw(at: NSPoint(x: x + 15, y: 5), withAttributes: attrs)
                } else {
                    (b.top as NSString).draw(at: NSPoint(x: x + 15, y: 0), withAttributes: attrs)
                    (b.bottom as NSString).draw(at: NSPoint(x: x + 15, y: 10), withAttributes: attrs)
                }
                x += widths[i] + 8
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
