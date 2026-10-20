import AppKit

// True-black flat, cooled for a monitor: depth is a lightness step, colour lives on data only.
enum Theme {
    static let ground   = NSColor(hex: 0x0c0d0f)
    static let surface  = NSColor(hex: 0x15171a)
    static let raised   = NSColor(hex: 0x24272c)   // tracks, nested panels, controls
    static let line     = NSColor(hex: 0x202328)
    static let grid     = NSColor(hex: 0x23262b)
    static let text     = NSColor.white
    static let muted    = NSColor(hex: 0xb4b4b4)
    static let faint    = NSColor(hex: 0x8f9296)
    static let accent   = NSColor(hex: 0xc6f24e)   // the one data hue; also "good"
    static let warning  = NSColor(hex: 0xe5a93b)
    static let negative = NSColor(hex: 0xe5566f)
    static let chart2   = NSColor(hex: 0xe6e6e6)
    static let chart3   = NSColor(hex: 0x6b6b6b)
    static let chart4   = NSColor(hex: 0x34383e)

    static let pillGood = (NSColor(hex: 0x222a10), accent)
    static let pillWarn = (NSColor(hex: 0x2b2414), warning)
    static let pillBad  = (NSColor(hex: 0x2c1a20), negative)
    static let pillNeutral = (NSColor(hex: 0x24272c), NSColor.white)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

enum Fmt {
    static func watts(_ w: Double?) -> String {
        guard let w else { return "—" }
        return w < 100 ? String(format: "%.1f", w) : String(format: "%.0f", w)
    }
    static func wattsUnit(_ w: Double?) -> String { w == nil ? "—" : watts(w) + " W" }
    static func energy(_ wh: Double) -> String {
        wh < 1000 ? String(format: "%.0f Wh", wh) : String(format: "%.2f kWh", wh / 1000)
    }
    static func gb(_ b: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", b / 1_073_741_824) }
    static func rate(_ bps: Double?) -> String {
        guard let b = bps else { return "—" }
        if b < 1000 { return String(format: "%.0f B/s", b) }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1000) }
        if b < 1_000_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        return String(format: "%.2f GB/s", b / 1_000_000_000)
    }
    /// Drive sizes in decimal units, as Finder shows them.
    static func size(_ b: Double) -> String {
        if b >= 1e12 { return String(format: "%.2f TB", b / 1e12) }
        return b >= 1e11 ? String(format: "%.0f GB", b / 1e9) : String(format: "%.1f GB", b / 1e9)
    }
    static func temp(_ t: Double?) -> String { t.map { String(format: "%.0f°", $0) } ?? "—" }
    static func pct(_ p: Double?) -> String { p.map { String(format: "%.0f%%", $0) } ?? "—" }
    static let grouped: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f }()
    static func rpm(_ r: Double) -> String { grouped.string(from: NSNumber(value: r.rounded())) ?? "\(Int(r))" }
    static func duration(_ s: Double) -> String {
        let m = Int(s / 60), d = m / 1440, h = m / 60 % 24
        if d > 0 { return "\(d) d \(h) h" }
        return h > 0 ? "\(h) h \(m % 60) m" : "\(m) m"
    }
    static func clock(_ t: Double, seconds: Bool = false) -> String {
        let f = DateFormatter(); f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
    static func money(_ v: Double) -> String { String(format: v < 1 ? "$%.2f" : "$%.2f", v) }
}

/// Settings, stored in UserDefaults.
enum Prefs {
    private static let d = UserDefaults.standard
    static var remoteHost: String { get { d.string(forKey: "remoteHost") ?? "mac-mini" } set { d.set(newValue, forKey: "remoteHost") } }
    static var menuBar: String { get { d.string(forKey: "menuBar") ?? "both" } set { d.set(newValue, forKey: "menuBar") } }
    static var selected: String { get { d.string(forKey: "selected") ?? "remote" } set { d.set(newValue, forKey: "selected") } }
    static var range: Int { get { d.object(forKey: "range") as? Int ?? 1 } set { d.set(newValue, forKey: "range") } }
    static var price: Double { get { d.double(forKey: "price") } set { d.set(newValue, forKey: "price") } }
    static var curveLow: Double { get { d.object(forKey: "curveLow") as? Double ?? 50 } set { d.set(newValue, forKey: "curveLow") } }
    static var curveHigh: Double { get { d.object(forKey: "curveHigh") as? Double ?? 85 } set { d.set(newValue, forKey: "curveHigh") } }
    static func fanPolicy(_ host: String) -> String { d.string(forKey: "fan.\(host)") ?? "auto" }
    static func setFanPolicy(_ host: String, _ v: String) { d.set(v, forKey: "fan.\(host)") }
}
