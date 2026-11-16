import AppKit
import IOKit.ps

/// The menu bar item: for each Mac shown, a small outline of the machine, a thin heat gauge for its
/// CPU, then watts over the CPU temperature. Three Macs or more fold into one reading (a stack, the
/// fleet's total watts over its hottest CPU), since N blocks would crowd the menu bar. Drawn as a
/// template image so it follows the menu bar's light or dark look; hierarchy comes from alpha
/// (numbers solid, units and tracks faded), which a template image keeps.
enum StatusRenderer {
    enum Icon { case laptop, box, tower, macpro, imac, stack }

    /// The outline for a Mac, from the model name its agent reports ("Mac Studio", "MacBook Pro"…).
    /// Until that arrives, this Mac is guessed from whether it has a battery, and others are a box.
    static func icon(for l: HostLink) -> Icon {
        let m = l.info?.model ?? ""
        if m.contains("MacBook") { return .laptop }
        if m.contains("iMac") { return .imac }
        if m.contains("Mac Pro") { return .macpro }
        if m.contains("Studio") { return .tower }
        if m.contains("mini") { return .box }
        if l.isLocal, l.info == nil { return hasBattery ? .laptop : .box }
        return .box
    }
    private static let hasBattery: Bool = {
        let ps = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(ps).takeRetainedValue() as [CFTypeRef]
        return list.contains { src in
            let d = IOPSGetPowerSourceDescription(ps, src).takeUnretainedValue() as? [String: Any]
            return d?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
    /// `top` is the watts figure, `bottom` the temperature, `heat` the gauge fill (0…1, nil when unknown).
    typealias Reading = (icon: Icon, top: String, bottom: String, heat: Double?)

    /// Whole watts: steadier in the menu bar, and fewer redraws.
    static func watts(_ w: Double?) -> String { w.map { String(format: "%.0f", $0) } ?? "—" }

    /// Where the gauge sits for a CPU temperature: empty at 35°, full at 100°, rounded to tenths so
    /// it only redraws when the bar visibly moves.
    static func heat(_ t: Double?) -> Double? {
        t.map { (min(max(($0 - 35) / 65, 0), 1) * 10).rounded() / 10 }
    }

    /// What the menu bar shows for these Macs; also the key that decides whether it needs a redraw.
    static func readings(for links: [HostLink]) -> [Reading] {
        if links.count >= 3 {
            let snaps = links.compactMap { $0.state == .live ? $0.snap : nil }
            guard !snaps.isEmpty else { return [(.stack, "—", "", nil)] }
            let total = snaps.compactMap(\.wSystem).reduce(0, +)
            let hottest = snaps.compactMap(\.tCPU).max()
            return [(.stack, watts(total), Fmt.temp(hottest), heat(hottest))]
        }
        return links.map { l in
            let icon = icon(for: l)
            guard l.state == .live, let s = l.snap else { return (icon, "—", "", nil) }
            return (icon, watts(s.wSystem), Fmt.temp(s.tCPU), heat(s.tCPU))
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
            lines.insert("\(live) of \(links.count) Macs: \(r.top) W in all, hottest CPU \(r.bottom)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func image(for links: [HostLink]) -> NSImage { image(blocks: readings(for: links)) }

    // MARK: Drawing

    private static let height: CGFloat = 22
    private static let iconWidth: CGFloat = 19
    private static let gaugeGap: CGFloat = 4, gaugeWidth: CGFloat = 2.5, textGap: CGFloat = 4
    private static let dividerPad: CGFloat = 7
    private static let number = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let unit = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static func ink(_ alpha: CGFloat) -> NSColor { NSColor.black.withAlphaComponent(alpha) }

    /// "82" solid, then " W" small and faded; the temperature's "°" stays with its number.
    private static func label(_ value: String, unit u: String?) -> NSAttributedString {
        let s = NSMutableAttributedString(string: value, attributes: [.font: number, .foregroundColor: ink(1)])
        if let u, value != "—" {
            s.append(NSAttributedString(string: "\u{2009}" + u, attributes: [.font: unit, .foregroundColor: ink(0.6)]))
        }
        return s
    }

    /// The text column is as wide as "88 W" at least (most Macs idle under 100 W), so the item does
    /// not shuffle the menu bar every time a reading gains or loses a digit.
    private static let minTextWidth: CGFloat = label("88", unit: "W").size().width

    static func image(blocks: [Reading]) -> NSImage {
        let lines = blocks.map { b in (label(b.top, unit: b.bottom.isEmpty ? nil : "W"), label(b.bottom, unit: nil)) }
        let textWidths = lines.map { max(minTextWidth, $0.0.size().width, $0.1.size().width) }
        let blockWidths = textWidths.map { iconWidth + gaugeGap + gaugeWidth + textGap + $0 }
        let width = blockWidths.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * (dividerPad * 2 + 1)
        let img = NSImage(size: NSSize(width: ceil(width), height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for (i, b) in blocks.enumerated() {
                let live = !b.bottom.isEmpty
                drawIcon(b.icon, at: x, alpha: live ? 1 : 0.45)

                // The gauge: a faded track with the heat filled in from the bottom.
                let gx = x + iconWidth + gaugeGap
                let track = NSRect(x: gx, y: 4.5, width: gaugeWidth, height: 13)
                ink(0.22).setFill()
                NSBezierPath(roundedRect: track, xRadius: gaugeWidth / 2, yRadius: gaugeWidth / 2).fill()
                if let h = b.heat, h > 0 {
                    let fh = max(gaugeWidth, track.height * h)
                    ink(1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: gx, y: track.maxY - fh, width: gaugeWidth, height: fh),
                                 xRadius: gaugeWidth / 2, yRadius: gaugeWidth / 2).fill()
                }

                // Numbers, right-aligned in their column so digits stay put as they change.
                let tx = gx + gaugeWidth + textGap, tw = textWidths[i]
                func draw(_ s: NSAttributedString, baseline: CGFloat) {
                    let w = s.size().width
                    s.draw(at: NSPoint(x: tx + tw - w, y: baseline - number.ascender))
                }
                if live {
                    draw(lines[i].0, baseline: 9.5)
                    draw(lines[i].1, baseline: 19.5)
                } else {
                    let dash = label("—", unit: nil).mutableCopy() as! NSMutableAttributedString
                    dash.addAttribute(.foregroundColor, value: ink(0.45), range: NSRange(location: 0, length: dash.length))
                    dash.draw(at: NSPoint(x: tx + (tw - dash.size().width) / 2, y: 14.5 - number.ascender))
                }

                x += blockWidths[i]
                if i < blocks.count - 1 {
                    ink(0.25).setFill()
                    NSRect(x: x + dividerPad, y: 5, width: 1, height: 12).fill()
                    x += dividerPad * 2 + 1
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Apple's own SF Symbol for each kind of Mac; the hand-drawn outlines below are the fallback.
    private static func symbol(_ icon: Icon) -> NSImage? {
        let name: String
        switch icon {
        case .laptop: name = "laptopcomputer"
        case .box: name = "macmini"
        case .tower: name = "macstudio"
        case .macpro: name = "macpro.gen3"
        case .imac: name = "desktopcomputer"
        case .stack: return nil
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    private static func drawIcon(_ icon: Icon, at x: CGFloat, alpha: CGFloat) {
        if let s = symbol(icon) {
            // Fit the symbol into the icon box, centred on the menu bar's midline.
            let box = NSRect(x: x, y: 3.5, width: iconWidth, height: 15)
            let k = min(box.width / s.size.width, box.height / s.size.height, 1)
            let w = s.size.width * k, h = s.size.height * k
            s.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            return
        }
        ink(alpha).setStroke(); ink(alpha).setFill()
        switch icon {
        case .macpro: fallthrough
        case .laptop:
            let screen = NSBezierPath(roundedRect: NSRect(x: x + 2, y: 5.5, width: 10, height: 8), xRadius: 1.5, yRadius: 1.5)
            screen.lineWidth = 1.25; screen.stroke()
            NSBezierPath(roundedRect: NSRect(x: x, y: 14.8, width: 14, height: 1.7), xRadius: 0.85, yRadius: 0.85).fill()
        case .box:
            let box = NSBezierPath(roundedRect: NSRect(x: x + 1.25, y: 4.75, width: 11.5, height: 11.5), xRadius: 3, yRadius: 3)
            box.lineWidth = 1.25; box.stroke()
            NSBezierPath(ovalIn: NSRect(x: x + 6.1, y: 12.2, width: 1.8, height: 1.8)).fill()
        case .tower:
            // Mac Studio / Mac Pro: taller than a mini, with a row of front ports.
            let body = NSBezierPath(roundedRect: NSRect(x: x + 1.75, y: 3.75, width: 10.5, height: 13.5), xRadius: 2.6, yRadius: 2.6)
            body.lineWidth = 1.25; body.stroke()
            for px in [4.6, 6.5, 8.4] as [CGFloat] {
                NSBezierPath(roundedRect: NSRect(x: x + px, y: 13.2, width: 1.1, height: 1.6), xRadius: 0.5, yRadius: 0.5).fill()
            }
        case .imac:
            let screen = NSBezierPath(roundedRect: NSRect(x: x + 0.75, y: 4.25, width: 12.5, height: 9), xRadius: 1.5, yRadius: 1.5)
            screen.lineWidth = 1.25; screen.stroke()
            NSRect(x: x + 6.25, y: 13.25, width: 1.5, height: 2.5).fill()
            NSBezierPath(roundedRect: NSRect(x: x + 4, y: 15.6, width: 6, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
        case .stack:
            // Three Mac minis seen from the side, stacked: the fleet.
            for sy in [4.5, 9.0, 13.5] as [CGFloat] {
                let slab = NSBezierPath(roundedRect: NSRect(x: x + 1, y: sy, width: 12, height: 3.5), xRadius: 1.4, yRadius: 1.4)
                slab.lineWidth = 1.1; slab.stroke()
            }
        }
    }
}
