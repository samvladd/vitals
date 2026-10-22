import Foundation

// Fleet: every Mac of yours on the tailnet, found by Tailscale rather than listed by hand. Set up the
// dashboard on another Mac and it appears on all of them. The members are your own macOS devices
// (same Tailscale account, not tagged); which of them run Vitals is for the page to find out, by
// asking each for /summary. Each Mac's page may read the others' dashboards (CORS, reads only): the
// same owner on both ends, and posts are never allowed across Macs.

enum Fleet {
    struct Member: Encodable { var name: String, host: String, url: String, online: Bool, me: Bool }

    private static var cache: (Date, [Member])?
    private static var refreshing = false
    static var extra: [String] = []            // --peer addresses, from before discovery

    /// The last list known, refreshed in the background once it is a minute old: never waits.
    static func members() -> [Member] {
        if cache.map({ Date().timeIntervalSince($0.0) > 60 }) ?? true, !refreshing {
            refreshing = true
            DispatchQueue.global(qos: .utility).async {
                let list = discover()
                DispatchQueue.main.async { cache = (Date(), list); refreshing = false }
            }
        }
        return cache?.1 ?? []
    }

    /// Blocking: for the first request, so the page gets an answer rather than an empty list.
    static func membersNow() -> [Member] {
        if cache == nil { cache = (Date(), discover()) }
        return members()
    }

    private static func discover() -> [Member] {
        var out: [Member] = []
        if let t = tailnet() {
            for n in t.nodes where n.user == t.me.user && n.tags.isEmpty && n.os == "macOS" {
                out.append(Member(name: friendlyName(n, among: t.nodes), host: n.dns, url: "https://\(n.dns)/",
                                  online: n.online || n.dns == t.me.dns, me: n.dns == t.me.dns))
            }
        }
        for url in extra where !out.contains(where: { $0.url == url }) {
            let host = URL(string: url)?.host ?? url
            out.append(Member(name: String(host.split(separator: ".").first ?? ""), host: host, url: url, online: true, me: false))
        }
        return out.sorted { ($0.me ? 0 : 1, $0.name) < ($1.me ? 0 : 1, $1.name) }
    }

    /// An origin the page may read from: one of your Macs' dashboards.
    static func allows(origin: String) -> Bool { members().contains { "https://" + $0.host == origin } }

    // MARK: /summary: this Mac at a glance, from the logger's last minute (no sampling started)

    struct Summary: Encodable {
        var info: MachineInfo
        var t: Double?, w: Double?, cpu: Double?, temp: Double?, mem: Double?, free: Double?
        var uptime: Double
        var apps: Bool, screen: Bool
        var wake = Wake.mine()                 // how another Mac on its network can wake it (Wake.swift)
        var energy: Energy.Brief?               // today and this month in Wh, so the fleet card can add them up (Energy.swift)
    }

    static func summary(info: MachineInfo) -> Summary {
        var s = Summary(info: info, uptime: ProcessInfo.processInfo.systemUptime,
                        apps: Control.load() != nil, screen: Control.load()?.screen == true, energy: Energy.brief())
        let file = logDir.appendingPathComponent(dayFormat.string(from: Date()) + ".csv")
        // Only the end of today's file: the last full line.
        if let h = try? FileHandle(forReadingFrom: file) {
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 400 ? size - 400 : 0)
            let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            try? h.close()
            if let line = tail.split(separator: "\n").last {
                let c = line.split(separator: ",").compactMap { Double($0) }
                if c.count >= 9 {
                    s.t = c[0]; s.w = c[1]; s.cpu = c[3]; s.temp = c[5] > 0 ? c[5] : nil; s.mem = c[7]
                    s.free = c.count > 10 && c[10] > 0 ? c[10] : nil
                }
            }
        }
        return s
    }
}

/// This Mac's phone dashboard, for the menu bar app's links: its tailnet address, once `install-serve`
/// has set the dashboard up. Asked once, when the app connects.
func dashboardURL() -> String? {
    let plist = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/com.vitals.serve.plist")
    guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
    if let c = Control.load() { return "https://\(c.host)/" }
    return tailnet().map { "https://\($0.me.dns)/" }
}
