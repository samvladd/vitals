import AppKit
import Foundation

// App control: the phone dashboard lists this Mac's apps and can quit and open them. It is off until
// `vitals-agent control on --from DEVICE,...` names the devices allowed to use it, and then every
// request has to pass all of these, checked here on each call:
//  - it came through `tailscale serve` under this Mac's own tailnet name. That is the Host header,
//    which a browser cannot forge, so a web page that points its DNS at 127.0.0.1 is refused;
//  - from this Mac's own Tailscale account (Tailscale sets Tailscale-User-Login and drops any copy
//    the client sent);
//  - from one of the named devices (Tailscale sets X-Forwarded-For to the device's tailnet address),
//    so another machine on the same account, a server say, cannot;
//  - and, for a change, from this Mac's own page (Origin, Sec-Fetch-Site and the X-Vitals header).
// It can only quit or open apps: no shell, no paths, no arguments. Tailscale itself cannot be quit
// from here, so the page cannot cut itself off. Each change, and each refused request, is logged.

let supportDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Vitals")

enum Control {
    static let file = supportDir.appendingPathComponent("control.json")
    static let logFile = supportDir.appendingPathComponent("control.log")
    /// Quitting these from the page would make the page unreachable.
    static let locked: Set<String> = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]

    struct Config: Codable {
        var login: String                 // the Tailscale account, e.g. you@example.com
        var host: String                  // this Mac's tailnet name, e.g. mac-mini.tail1234.ts.net
        var devices: [String: String]     // tailnet address -> device name
        var screen: Bool? = nil           // the Screen page (Screen.swift), off unless `screen on`
    }

    /// The Screen page's address, for the menu bar app's Screen button; nil while Screen is off.
    static func screenURL() -> String? { load().flatMap { $0.screen == true ? "https://\($0.host)/screen/" : nil } }

    static func load() -> Config? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } }

    enum Gate { case off, refused(String), allowed(device: String) }

    static func gate(_ r: Request, change: Bool) -> Gate {
        guard let c = load() else { return .off }
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map { $0.lowercased() } ?? ""
        guard host == c.host else { return .refused("not opened through this Mac's tailnet address") }
        guard r.headers["tailscale-user-login"] == c.login else { return .refused("not this Mac's Tailscale account") }
        guard let device = c.devices[r.headers["x-forwarded-for"] ?? ""] else { return .refused("device not on the allowed list") }
        let site = r.headers["sec-fetch-site"]
        if change {
            guard r.headers["origin"] == "https://" + c.host, site == nil || site == "same-origin" else { return .refused("not from this Mac's own page") }
        } else if let site, site != "same-origin", site != "none" {
            return .refused("not from this Mac's own page")
        }
        return .allowed(device: device)
    }

    // MARK: actions

    /// Every running copy of the app. By bundle ID, not pid: macOS reports some apps' pid as -1.
    static func running(_ id: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id && $0.activationPolicy == .regular && !$0.isTerminated }
    }

    static func quit(id: String, force: Bool) -> String? {
        let copies = running(id)
        guard let first = copies.first else { return "That app is no longer running." }
        if locked.contains(id) { return "Tailscale keeps this page reachable, so it can't be quit from here." }
        let asked = copies.filter { force ? $0.forceTerminate() : $0.terminate() }.count
        return asked > 0 ? nil : "macOS would not quit \(first.localizedName ?? id)."
    }

    static func open(id: String, done: @escaping (String?) -> Void) {
        guard let app = installed().first(where: { $0.id == id }) else { return done("That app isn't installed in Applications.") }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: cfg) { _, err in
            DispatchQueue.main.async { done(err.map { _ in "macOS could not open \(app.name)." }) }
        }
    }

    // MARK: installed apps and icons

    struct Installed: Encodable {
        var id: String, name: String
        let url: URL
        enum CodingKeys: CodingKey { case id, name }
    }

    private static var installedCache: (Date, [Installed])?

    /// The apps in the usual Applications folders, by bundle ID. Opening is limited to these.
    static func installed() -> [Installed] {
        if let (t, list) = installedCache, Date().timeIntervalSince(t) < 300 { return list }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var seen = Set<String>(), list: [Installed] = []
        for d in dirs {
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".app") {
                let url = URL(fileURLWithPath: d).appendingPathComponent(f)
                guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                list.append(Installed(id: id, name: String(fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")), url: url))
            }
        }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        installedCache = (Date(), list)
        return list
    }

    private static var icons: [String: Data] = [:]

    /// A 64-pixel PNG of a running or installed app's icon, looked up by bundle ID only.
    static func icon(id: String) -> Data? {
        if let d = icons[id] { return d }
        let url = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.bundleURL
            ?? installed().first { $0.id == id }?.url
        guard let url, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])
        icons[id] = png
        return png
    }

    // MARK: the log

    /// done, failed (allowed, but macOS said no) or refused (didn't pass the checks).
    struct Entry: Encodable { var t: Double, kind: String, text: String }

    static func record(_ text: String, _ kind: String = "done") {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let line = "\(Int(Date().timeIntervalSince1970))\t\(kind)\t\(text.replacingOccurrences(of: "\n", with: " "))\n"
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: logFile.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
        // Keep it small: past 256 KB, drop the older half.
        if let d = try? Data(contentsOf: logFile), d.count > 262_144, let cut = d.dropFirst(d.count / 2).firstIndex(of: 10) {
            try? d[(cut + 1)...].write(to: logFile)
        }
    }

    static func recent(_ n: Int) -> [Entry] {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).reversed().compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let t = Double(f[0]) else { return nil }
            return Entry(t: t, kind: f[1], text: f[2])
        }
    }
}

// MARK: running apps, with their helpers' CPU and memory

struct AppRow: Encodable {
    var id: String, name: String
    var copies: Int                       // running copies, shown as one row and quit together
    var cpu: Double                       // % of one core, the app and its helpers
    var mem: Double                       // bytes, memory footprint as Activity Monitor counts it
    var active: Bool, hidden: Bool, locked: Bool
}

final class AppMeter {
    private var prev: [pid_t: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var paths: [pid_t: String] = [:]     // a process's executable doesn't change; looked up once
    private let timebase: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()

    /// The apps in the Dock, one row per bundle ID, largest first. A process counts toward the app whose
    /// bundle it runs from (the innermost one), which takes in its helpers. CPU is since the previous call.
    func list() -> [AppRow] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != nil }
        let ids = apps.reduce(into: [String]()) { if !$0.contains($1.bundleIdentifier!) { $0.append($1.bundleIdentifier!) } }
        // Both spellings of each bundle: the kernel reports a process's path with symlinks resolved.
        let roots = apps.flatMap { a in [a.bundleURL, a.bundleURL?.resolvingSymlinksInPath()].compactMap { $0.map { ($0.path + "/", a.bundleIdentifier!) } } }
            .sorted { $0.0.count > $1.0.count }
        var cpu: [String: Double] = [:], mem: [String: Double] = [:], next: [pid_t: UInt64] = [:]
        let now = mach_absolute_time()
        let elapsed = Double(now &- prevTime) * timebase
        let n = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(max(n, 0)) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4096), known: [pid_t: String] = [:]
        for pid in pids.prefix(max(got, 0)) where pid > 0 {
            if paths[pid] == nil { paths[pid] = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : "" }
            let p = paths[pid]!
            known[pid] = p
            guard let owner = roots.first(where: { p.hasPrefix($0.0) })?.1 else { continue }
            var ti = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { continue }
            let total = ti.pti_total_user + ti.pti_total_system
            next[pid] = total
            if prevTime > 0, let was = prev[pid], total >= was, elapsed > 0 { cpu[owner, default: 0] += Double(total - was) * timebase / elapsed * 100 }
            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
            mem[owner, default: 0] += ok == 0 ? Double(ru.ri_phys_footprint) : Double(ti.pti_resident_size)
        }
        prev = next; prevTime = now; paths = known
        return ids.map { id in
            let copies = apps.filter { $0.bundleIdentifier == id }
            return AppRow(id: id, name: copies[0].localizedName ?? id, copies: copies.count, cpu: cpu[id] ?? 0, mem: mem[id] ?? 0,
                          active: copies.contains(where: \.isActive), hidden: copies.allSatisfy(\.isHidden), locked: Control.locked.contains(id))
        }.sorted { $0.mem > $1.mem }
    }
}

// MARK: setup

/// `control on --from DEVICE,...`, `control off`, or `control` to show the state.
func controlCommand() {
    switch args.dropFirst().first {
    case "on":
        guard let t = tailnet() else { fail("Tailscale isn't running on this Mac, or its CLI wasn't found.") }
        let names = (option("--from") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let mine = t.nodes.filter { $0.user == t.me.user && $0.tags.isEmpty }
        guard !names.isEmpty else {
            fail("Name the devices allowed to control this Mac: vitals-agent control on --from iphone,macbook\nYour devices: "
                 + mine.map(\.name).joined(separator: ", "))
        }
        var devices: [String: String] = [:]
        for n in names {
            guard let node = t.nodes.first(where: { $0.name == n }) else { fail("No device called \(n) on your tailnet. Yours: \(mine.map(\.name).joined(separator: ", "))") }
            guard node.user == t.me.user else { fail("\(n) belongs to another Tailscale account; only your own devices can be allowed.") }
            guard node.tags.isEmpty else { fail("\(n) is a tagged device, so Tailscale doesn't say who is using it; it can't be allowed.") }
            for ip in node.ips { devices[ip] = friendlyName(node, among: mine) }
        }
        let c = Control.Config(login: t.login, host: t.me.dns, devices: devices, screen: Control.load()?.screen)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(c),
              FileManager.default.createFile(atPath: Control.file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            fail("Could not write \(Control.file.path)")
        }
        chmod(Control.file.path, 0o600)
        let allowed = Set(devices.values).sorted().joined(separator: ", ")
        Control.record("Turned on for \(allowed)")
        print("App control is on for \(t.me.dns), from \(allowed) (account \(t.login)).\nTurn it off: vitals-agent control off")
    case "off":
        try? FileManager.default.removeItem(at: Control.file)
        Control.record("Turned off")
        print("App control is off.")
    default:
        guard let c = Control.load() else { print("App control is off. Turn it on: vitals-agent control on --from iphone,macbook"); return }
        print("App control is on for \(c.host), from \(Set(c.devices.values).sorted().joined(separator: ", ")) (account \(c.login)).")
        print(c.screen == true ? "Screen is on: the dashboard can show and control this Mac's screen." : "Screen is off. Turn it on: vitals-agent screen on")
        for e in Control.recent(10) {
            print("  \(Date(timeIntervalSince1970: e.t).formatted(date: .abbreviated, time: .shortened))  \(e.kind == "done" ? "" : e.kind + ": ")\(e.text)")
        }
    }
}

let tailscaleCLI = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

struct TailnetNode {
    var name: String, dns: String, host: String, os: String
    var online: Bool
    var user: Int, ips: [String], tags: [String]
}

/// "iPhone" or "MacBook" rather than iphone182 or shmulis-macbook-pro-2, for the log and the page.
/// Falls back to the tailnet name when two of your devices would read the same.
func friendlyName(_ n: TailnetNode, among all: [TailnetNode]) -> String {
    func guess(_ n: TailnetNode) -> String {
        let k = n.name
        if n.os == "iOS" { return k.contains("ipad") ? "iPad" : "iPhone" }
        for (key, name) in [("macbook", "MacBook"), ("mini", "Mac mini"), ("studio", "Mac Studio"), ("imac", "iMac")] where k.contains(key) { return name }
        return n.host.isEmpty || n.host == "localhost" ? k : n.host
    }
    let g = guess(n)
    return all.filter { guess($0) == g }.count > 1 ? n.name : g
}

/// This Mac, its account and the devices it can see, from `tailscale status --json`.
func tailnet() -> (me: TailnetNode, login: String, nodes: [TailnetNode])? {
    guard let cli = tailscaleCLI else { return nil }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: cli); p.arguments = ["status", "--json"]
    // The Mac app's binary is also its CLI, and started from a background job it would try to open the
    // app instead ("The Tailscale GUI failed to start"); this tells it to behave as the CLI.
    p.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { _, b in b }
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let me = j["Self"] as? [String: Any] else { return nil }
    func node(_ d: [String: Any]) -> TailnetNode? {
        guard let dns = (d["DNSName"] as? String)?.lowercased(), !dns.isEmpty else { return nil }
        let host = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
        return TailnetNode(name: String(host.split(separator: ".").first ?? ""), dns: host, host: d["HostName"] as? String ?? "",
                           os: d["OS"] as? String ?? "", online: d["Online"] as? Bool ?? true, user: (d["UserID"] as? NSNumber)?.intValue ?? -1,
                           ips: d["TailscaleIPs"] as? [String] ?? [], tags: d["Tags"] as? [String] ?? [])
    }
    guard let self_ = node(me), let users = j["User"] as? [String: [String: Any]],
          let login = users[String(self_.user)]?["LoginName"] as? String else { return nil }
    let peers = (j["Peer"] as? [String: [String: Any]] ?? [:]).values.compactMap(node)
    return (self_, login, [self_] + peers)
}

/// `screen on` or `screen off`: the dashboard's Screen page, for the devices app control allows.
func screenCommand() {
    guard var c = Control.load() else { fail("Turn on app control first: vitals-agent control on --from iphone,macbook") }
    switch args.dropFirst().first {
    case "on":
        c.screen = true
        if !screenSharingListening() {
            print("Note: Screen Sharing doesn't seem to be on. Turn it on in System Settings > General > Sharing > Screen Sharing.")
        }
    case "off": c.screen = false
    default:
        print(c.screen == true ? "Screen is on." : "Screen is off."); return
    }
    guard let data = try? JSONEncoder().encode(c),
          FileManager.default.createFile(atPath: Control.file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        fail("Could not write \(Control.file.path)")
    }
    Control.record(c.screen == true ? "Screen turned on" : "Screen turned off")
    print(c.screen == true ? "Screen is on for \(Set(c.devices.values).sorted().joined(separator: ", ")). Turn it off: vitals-agent screen off" : "Screen is off.")
}

func screenSharingListening() -> Bool {
    guard let fd = Screen.connectLocal(5900) else { return false }
    close(fd)
    return true
}
