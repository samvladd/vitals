import AppKit
import Foundation
import SystemConfiguration
import launch

// `serve`: the phone dashboard. launchd owns the listening socket on 127.0.0.1 and starts this only
// when a page connects; it samples only while a page is streaming and exits a minute after the last
// one leaves, so nobody looking costs nothing. `tailscale serve` puts the port on the tailnet over
// HTTPS. Each Mac serves itself: the page on one reads the other's address directly (CORS), and a fan
// moved off Auto goes back to Auto when the pages stop checking in.

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func json<T: Encodable>(_ v: T) -> String { (try? JSONEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null" }

/// Minute rows averaged into longer buckets, so a day of history stays small on a phone.
func coarse(_ h: History, every step: Double) -> History {
    var out: [LogRow] = [], group: [LogRow] = []
    func flush() {
        guard let first = group.first else { return }
        func mean(_ k: KeyPath<LogRow, Double>) -> Double { group.reduce(0) { $0 + $1[keyPath: k] } / Double(group.count) }
        out.append(LogRow(t: (first.t / step).rounded(.down) * step, w: mean(\.w), wMax: group.map(\.wMax).max() ?? 0,
                          cpu: mean(\.cpu), gpu: mean(\.gpu), temp: mean(\.temp), fan: mean(\.fan), mem: mean(\.mem), swap: mean(\.swap),
                          free: group.compactMap(\.free).last))
        group = []
    }
    for r in h.rows {
        if let f = group.first, Int(f.t / step) != Int(r.t / step) { flush() }
        group.append(r)
    }
    flush()
    return History(rows: out, days: h.days)
}

private var server: WebServer?     // lives for the whole process

func serve() -> Never {
    let port = option("--port").flatMap(UInt16.init) ?? 8787
    guard let fd = launchdSocket() ?? bindLocal(port) else { fail("cannot listen on 127.0.0.1:\(port)") }
    // --peer: one or more other Macs' addresses, as before discovery; Tailscale now finds them too.
    let peers = (option("--peer") ?? "").split(separator: ",").map { p in p.hasSuffix("/") ? String(p) : p + "/" }
    Fleet.extra = peers
    let peer = peers.first
    if let p = option("--screen-port").flatMap(UInt16.init) { Screen.port = p }     // for tests; always 127.0.0.1
    if let s = option("--screen-idle").flatMap(Double.init), s >= 5 { Screen.idleLimit = s }
    let origins = Set((option("--allow-origin") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " /")) })
    server = WebServer(listener: fd, peer: peer, origins: origins)
    server?.start()
    // Not dispatchMain: macOS keeps the list of running apps current only while the main run loop runs.
    while true { _ = RunLoop.main.run(mode: .default, before: .distantFuture) }
}

/// The socket launchd opened for us (see `install-serve`), or nil when started by hand.
private func launchdSocket() -> Int32? {
    let out = UnsafeMutablePointer<UnsafeMutablePointer<Int32>>.allocate(capacity: 1)
    defer { out.deallocate() }
    var count = 0
    guard launch_activate_socket("Listener", out, &count) == 0, count > 0 else { return nil }
    defer { free(out.pointee) }
    return out.pointee[0]
}

private func bindLocal(_ port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0, listen(fd, 16) == 0 else { close(fd); return nil }
    return fd
}

func installServe() {
    let port = option("--port").flatMap(UInt16.init) ?? 8787
    var a = ["serve", "--port", String(port)]
    // Your other Macs are found through Tailscale; --peer is only for one that isn't on your account.
    if let peer = option("--peer") {
        guard peer.split(separator: ",").allSatisfy({ URL(string: String($0))?.scheme == "https" }) else {
            fail("--peer takes https://other-mac.your-tailnet.ts.net (several, separated by commas)")
        }
        a += ["--peer", peer]
    }
    if let o = option("--allow-origin") { a += ["--allow-origin", o] }
    let listener: [String: Any] = ["SockNodeName": "127.0.0.1", "SockServiceName": String(port), "SockType": "stream", "SockFamily": "IPv4"]
    installLaunchAgent("com.vitals.serve", a, ["RunAtLoad": false, "KeepAlive": false, "Sockets": ["Listener": listener]])
    // Shows Tailscale's own output: the first time, it prints a link to enable Serve on the tailnet
    // and waits for it, so give up after a while rather than hang.
    let ts = tailscaleCLI
        .map { t -> Process in let p = Process(); p.executableURL = URL(fileURLWithPath: t); p.arguments = ["serve", "--bg", String(port)]; return p }
    if let ts, (try? ts.run()) != nil {
        let deadline = Date(timeIntervalSinceNow: 30)
        while ts.isRunning, Date() < deadline { usleep(200_000) }
        if ts.isRunning { ts.terminate(); print("Run `tailscale serve --bg \(port)` again once Serve is enabled.") }
    } else {
        print("Listening on 127.0.0.1:\(port). To reach it from your phone: tailscale serve --bg \(port)")
    }
}

// MARK: HTTP

struct Request {
    var method = "", path = "", query: [String: String] = [:], headers: [String: String] = [:], body = ""

    /// nil while the request is still arriving.
    init?(_ d: Data) {
        guard let end = d.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: d[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let rest = d[end.upperBound...]
        guard rest.count >= length else { return nil }
        body = String(decoding: rest.prefix(length), as: UTF8.self)
        guard first.count >= 2, let u = URLComponents(string: first[1]) else { return }
        method = first[0]; path = u.path
        for q in u.queryItems ?? [] { query[q.name] = q.value ?? "" }
    }
}

/// One accepted connection. Blocking writes with a send timeout: a page that stops reading is dropped.
final class Conn {
    let fd: Int32
    var buf = Data()
    var streaming = false
    var origin: String?
    var parsed = false                  // its request has fully arrived
    let born = Date()
    private let source: DispatchSourceRead

    init(_ fd: Int32, onRead: @escaping (Conn, Data?) -> Void) {
        self.fd = fd
        var on: Int32 = 1, timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let n = read(fd, &chunk, chunk.count)
            onRead(self, n > 0 ? Data(chunk.prefix(n)) : nil)
        }
        source.resume()
    }

    @discardableResult func write(_ d: Data) -> Bool {
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    func close() { source.cancel() }
}

final class WebServer {
    /// A fan stays off Auto only while an open page keeps checking in...
    static let lease = 90.0
    /// ...and goes back to Auto this long after the last page closes.
    static let grace = 30.0
    /// The process exits this long after the last page leaves; launchd starts it again for the next one.
    static let linger = 60.0

    private let listenFD: Int32
    private let peer: String?
    private let origins: Set<String>
    private var acceptSource: DispatchSourceRead?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var watchers: [Conn] { conns.values.filter(\.streaming) }
    private var sampler: Sampler?
    private lazy var driver = FanDriver()
    private let ticker = DispatchSource.makeTimerSource(queue: .main)
    private let chores = DispatchSource.makeTimerSource(queue: .main)
    private var ticking = false
    private var lastLine: String?
    private var lastAlive = Date.distantPast
    private var lastBusy = Date()
    private var emptySince: Date?
    private lazy var info = json(machineInfo())
    private lazy var meter = AppMeter()
    private var refusals: [String: Date] = [:]

    init(listener: Int32, peer: String?, origins: Set<String>) { listenFD = listener; self.peer = peer; self.origins = origins }

    func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        s.setEventHandler { [weak self] in self?.accept() }
        s.resume()
        acceptSource = s
        ticker.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        ticker.setEventHandler { [weak self] in self?.tick() }
        chores.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        chores.setEventHandler { [weak self] in self?.housekeeping() }
        chores.resume()
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        lastBusy = Date()
        let c = Conn(fd) { [weak self] c, d in self?.received(c, d) }
        conns[ObjectIdentifier(c)] = c
    }

    private func received(_ c: Conn, _ d: Data?) {
        guard let d else { return drop(c) }          // closed by the other end
        if c.streaming { return }
        c.buf.append(d)
        if let r = Request(c.buf) { c.buf = Data(); c.parsed = true; route(r, c) }
        else if c.buf.count > 65536 { drop(c) }
    }

    private func drop(_ c: Conn) {
        guard conns.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        c.close()
        lastBusy = Date()
        guard c.streaming, watchers.isEmpty else { return }
        emptySince = Date()
        lastLine = nil
        if ticking { ticker.suspend(); ticking = false }
    }

    /// Lets the page on the other Mac read this one. GET only: no preflight is ever granted, so a page
    /// elsewhere can watch these fans but never post to them.
    private func cors(_ c: Conn) -> String {
        guard let o = c.origin, origins.contains(o) || Fleet.allows(origin: o) else { return "" }
        return "Access-Control-Allow-Origin: \(o)\r\nVary: Origin\r\n"
    }

    private func send(_ c: Conn, _ status: Int, _ type: String, _ body: Data, cache: String = "no-store", extra: String = "") {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                      503: "Service Unavailable"][status] ?? ""
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: \(cache)\r\n\(cors(c))\(extra)Connection: close\r\n\r\n"
        c.write(Data(head.utf8) + body)
        drop(c)
    }

    private func send(_ c: Conn, _ status: Int, json body: String) { send(c, status, "application/json", Data(body.utf8)) }

    private func route(_ r: Request, _ c: Conn) {
        c.origin = r.headers["origin"]
        // Only ever reached through `tailscale serve` (a *.ts.net name) or on this Mac itself. A web page
        // that points its own domain at 127.0.0.1 (DNS rebinding) arrives under that domain and stops here.
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map { $0.lowercased() } ?? ""
        guard host.hasSuffix(".ts.net") || host == "127.0.0.1" || host == "localhost" else {
            return send(c, 403, json: #"{"error":"forbidden"}"#)
        }
        // A page on another site can post here from a tailnet browser, but it cannot add this header
        // without a CORS preflight, which this server never grants.
        if r.method == "POST", r.headers["x-vitals"] != "1" { return send(c, 403, json: #"{"error":"forbidden"}"#) }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            // Revalidated on each open so an update shows at once; it is small and only on the tailnet.
            send(c, 200, "text/html; charset=utf-8", WebAssets.page, cache: "no-cache")
        case ("GET", "/manifest.webmanifest"): send(c, 200, "application/manifest+json", Data(Self.manifest.utf8), cache: "max-age=604800")
        case ("GET", "/icon.png"), ("GET", "/apple-touch-icon.png"): send(c, 200, "image/png", WebAssets.icon, cache: "max-age=604800")
        // "apps" lets the other Mac's page point to this one's Apps card; it says only whether it is on.
        case ("GET", "/config"): send(c, 200, json: "{\"peer\":\(peer.map { "\"\($0)\"" } ?? "null"),\"info\":\(info),\"apps\":\(Control.load() != nil),\"screen\":\(Control.load()?.screen == true)}")
        case ("GET", "/events"): watch(c)
        case ("GET", "/fleet"):
            struct Reply: Encodable { var members: [Fleet.Member] }
            send(c, 200, json: json(Reply(members: Fleet.membersNow())))
            Wake.learn(Fleet.members())         // keep how to wake each one, for when it sleeps
        case ("GET", "/summary"):
            guard let i = try? JSONDecoder().decode(MachineInfo.self, from: Data(info.utf8)) else { return send(c, 500, json: "null") }
            send(c, 200, json: json(Fleet.summary(info: i)))
        case ("GET", "/history"): history(r, c)
        case ("GET", "/timeline"):          // Timeline.swift: one day of the log, read off the main queue
            DispatchQueue.global(qos: .utility).async {
                let body = json(Timeline.day(r.query["day"]))
                DispatchQueue.main.async { [weak self] in self?.send(c, 200, json: body) }
            }
        case ("GET", "/energy"):            // a year of daily totals (Energy.swift); off the main queue, as the first one builds the cache
            DispatchQueue.global(qos: .utility).async {
                let body = json(Energy.report())
                DispatchQueue.main.async { [weak self] in self?.send(c, 200, json: body) }
            }
        case ("GET", "/ssd"):
            DispatchQueue.global(qos: .utility).async {
                let body = ssdHealth().map(json) ?? "null"
                DispatchQueue.main.async { [weak self] in self?.send(c, 200, json: body) }
            }
        case ("GET", "/space"): send(c, 200, json: SpaceScanner.shared.current(fresh: r.query["fresh"] == "1").map(json) ?? "null")
        case ("POST", "/fan"): fan(r, c)
        case ("GET", "/battery"), ("GET", "/battery/history"), ("POST", "/battery"):     // BatteryCare.swift
            BatteryCare.handle(r) { [weak self] code, body in self?.send(c, code, json: body) }
        case ("GET", "/apps"), ("GET", "/apps/installed"), ("GET", "/apps/icon"), ("POST", "/apps/quit"), ("POST", "/apps/open"): apps(r, c)
        case ("GET", "/screen"), ("GET", "/screen/"), ("GET", "/screen/info"), ("GET", "/screen/manifest.webmanifest"), ("GET", "/screen/" + Self.novnc), ("GET", "/screen/ws"), ("POST", "/screen/alive"),
             ("POST", "/screen/resolution"):
            screen(r, c)
        // Actions (Actions.swift): the count is all another Mac's page may read; the rest is gated there.
        case ("GET", "/actions/count"): send(c, 200, json: "{\"count\":\(Control.load() == nil ? 0 : Actions.load().count)}")
        case ("GET", "/actions"), ("POST", "/actions/run"), ("POST", "/actions/stop"): c.origin = nil; let (code, body) = Actions.handle(r); send(c, code, json: body)
        case ("POST", "/wake"): c.origin = nil; let (code, body) = Wake.request(r); send(c, code, json: body)
        case ("POST", "/alive"): lastAlive = Date(); send(c, 204, "text/plain", Data())
        default: send(c, 404, "text/plain", Data("not found".utf8))
        }
    }

    static let manifest = """
    {"name":"Vitals","short_name":"Vitals","start_url":"./","scope":"./","display":"standalone",\
    "background_color":"#0c0d0f","theme_color":"#0c0d0f","icons":[{"src":"icon.png","sizes":"180x180","type":"image/png"}]}
    """

    // MARK: live readings

    private func watch(_ c: Conn) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\(cors(c))\r\n"
        guard c.write(Data((head + "retry: 3000\n\nevent: info\ndata: \(info)\n\n" + (lastLine ?? "")).utf8)) else { return drop(c) }
        c.streaming = true
        emptySince = nil
        if !ticking {
            if sampler == nil { sampler = Sampler(procs: true) }
            _ = sampler?.sample()            // restart the rate counters after an idle spell
            ticking = true
            ticker.resume()
        }
    }

    private func tick() {
        let ws = watchers
        guard let sampler, !ws.isEmpty else { return }
        var s = sampler.sample()
        s.fanPolicy = driver.policy
        s.root = driver.available
        let line = "data: \(json(s))\n\n"
        lastLine = line
        let data = Data(line.utf8)
        for c in ws where !c.write(data) { drop(c) }
    }

    private func housekeeping() {
        let now = Date()
        if !watchers.isEmpty || SpaceScanner.shared.busy || !Screen.relays.isEmpty { lastBusy = now }
        if Actions.busy { lastBusy = now }
        Screen.housekeeping()
        // A request still not complete after 10 s is someone holding a connection open: let it go.
        for c in conns.values where !c.parsed && !c.streaming && now.timeIntervalSince(c.born) > 10 { drop(c) }
        if driver.policy != "auto",
           now.timeIntervalSince(lastAlive) > Self.lease || emptySince.map({ now.timeIntervalSince($0) > Self.grace }) == true {
            driver.set("auto")
        }
        // Nobody looking: leave. launchd keeps the socket and starts this again for the next page.
        if conns.isEmpty, driver.policy == "auto", now.timeIntervalSince(lastBusy) > Self.linger { exit(0) }
    }

    // MARK: history and fans

    private func history(_ r: Request, _ c: Conn) {
        let hours: Double = ["10m": 1, "1h": 1, "24h": 24, "14d": 336][r.query["range"] ?? ""] ?? 1
        DispatchQueue.global(qos: .utility).async {
            let h = loadHistory(hours: hours)
            // About 300 points whatever the range: five-minute means for a day, hourly for two weeks.
            let body = json(hours > 24 ? coarse(h, every: 3600) : hours > 1 ? coarse(h, every: 300) : h)
            DispatchQueue.main.async { [weak self] in self?.send(c, 200, json: body) }
        }
    }

    private func fan(_ r: Request, _ c: Conn) {
        let words = r.body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let p = FanControl.Policy(words) else { return send(c, 400, json: #"{"error":"auto, fixed RPM or curve LOW HIGH"}"#) }
        guard driver.available else {
            return send(c, 409, json: #"{"error":"Fan control needs a one-time setup on this Mac (vitals-agent setup-root)."}"#)
        }
        lastAlive = Date()
        driver.set(p.text)
        tick()
        send(c, 200, json: "{\"policy\":\"\(p.text)\"}")
    }

    // MARK: apps (Control.swift)

    private func apps(_ r: Request, _ c: Conn) {
        c.origin = nil                      // never readable from the other Mac's page
        let change = r.method == "POST"
        let device: String
        switch Control.gate(r, change: change) {
        case .off: return send(c, 404, json: #"{"error":"off"}"#)
        case .refused(let why):
            // Logged once per address and reason every ten minutes, so a polling page doesn't flood it.
            let from = r.headers["x-forwarded-for"] ?? "this Mac", key = from + why
            if refusals[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                refusals[key] = Date()
                Control.record("Blocked a request from \(from) (\(r.headers["tailscale-user-login"] ?? "no account")): \(why)", "refused")
            }
            return send(c, 403, json: json(["error": "This device isn't allowed to control apps on this Mac."]))
        case .allowed(let d): device = d
        }
        switch r.path {
        case "/apps":
            struct Reply: Encodable { var device: String, apps: [AppRow], recent: [Control.Entry], screen: Bool }
            send(c, 200, json: json(Reply(device: device, apps: meter.list(), recent: Control.recent(5), screen: Control.load()?.screen == true)))
        case "/apps/installed": send(c, 200, json: json(Control.installed()))
        case "/apps/icon":
            guard let png = Control.icon(id: r.query["id"] ?? "") else { return send(c, 404, "text/plain", Data()) }
            send(c, 200, "image/png", png, cache: "private, max-age=86400")
        case "/apps/quit":
            // "quit BUNDLE-ID" or "force BUNDLE-ID": every running copy of that app.
            let w = r.body.split(separator: " ").map(String.init)
            guard w.count == 2, w[0] == "quit" || w[0] == "force" else { return send(c, 400, json: #"{"error":"quit|force BUNDLE-ID"}"#) }
            let name = Control.running(w[1]).first?.localizedName ?? w[1]
            let err = Control.quit(id: w[1], force: w[0] == "force")
            Control.record("\(w[0] == "force" ? "Force quit" : "Quit") \(name) from \(device)" + (err.map { ": \($0)" } ?? ""), err == nil ? "done" : "failed")
            send(c, err == nil ? 200 : 409, json: json(["error": err]))
        default:                            // /apps/open, body: a bundle ID from /apps/installed
            let id = r.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = Control.installed().first { $0.id == id }?.name ?? id
            Control.open(id: id) { [weak self] err in
                Control.record("Open \(name) from \(device)" + (err.map { ": \($0)" } ?? ""), err == nil ? "done" : "failed")
                self?.send(c, err == nil ? 200 : 409, json: json(["error": err]))
            }
        }
    }

    // MARK: screen (Screen.swift)

    /// The viewer's file name carries its version, so a phone can keep it for good.
    static let novnc = "novnc-1.7.0.js"

    private func screen(_ r: Request, _ c: Conn) {
        c.origin = nil
        let ws = r.path == "/screen/ws"
        let device: String
        switch Control.gate(r, change: ws || r.method == "POST") {
        case .off: return send(c, 404, "text/plain", Data("not found".utf8))
        case .refused(let why):
            let from = r.headers["x-forwarded-for"] ?? "this Mac", key = from + why
            if refusals[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                refusals[key] = Date()
                Control.record("Blocked a screen request from \(from) (\(r.headers["tailscale-user-login"] ?? "no account")): \(why)", "refused")
            }
            return send(c, 403, "text/plain", Data("This device isn't allowed to see this Mac's screen.".utf8))
        case .allowed(let d): device = d
        }
        guard Control.load()?.screen == true else { return send(c, 404, "text/plain", Data("not found".utf8)) }
        switch r.path {
        case "/screen":                     // the page's relative links need the trailing slash
            c.write(Data("HTTP/1.1 308 Permanent Redirect\r\nLocation: /screen/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            drop(c)
        case "/screen/": send(c, 200, "text/html; charset=utf-8", WebAssets.screen, cache: "no-cache", extra: "X-Frame-Options: DENY\r\n")
        case "/screen/manifest.webmanifest":
            // Add to Dock (Safari on a Mac) or to the Home Screen: an app that opens straight on this screen.
            let name = (try? JSONDecoder().decode(MachineInfo.self, from: Data(info.utf8)))?.model.components(separatedBy: " (").first ?? "Mac"
            let m: [String: Any] = ["name": "\(name) Screen", "short_name": name, "start_url": "./", "scope": "./", "display": "standalone",
                                    "background_color": "#000000", "theme_color": "#0c0d0f",
                                    "icons": [["src": "../icon.png", "sizes": "180x180", "type": "image/png"]]]
            send(c, 200, "application/manifest+json", (try? JSONSerialization.data(withJSONObject: m)) ?? Data())
        case "/screen/info":
            // The login name to suggest (the Mac's signed-in user) and what to call this Mac.
            let model = (try? JSONDecoder().decode(MachineInfo.self, from: Data(info.utf8)))?.model.components(separatedBy: " (").first
            send(c, 200, json: json(["user": consoleUser() ?? NSUserName(), "mac": model ?? "Mac"]))
        case "/screen/alive": Screen.touched(by: device); send(c, 204, "text/plain", Data())
        case "/screen/resolution":
            // "fast" before connecting (or reconnecting) for the lighter 1x picture; "full" for Retina.
            let fast = r.body.trimmingCharacters(in: .whitespacesAndNewlines) == "fast"
            let mode = fast ? Display.fast() : { Display.restore(); return nil }()
            send(c, 200, json: json(["fast": mode]))
        case "/screen/ws": upgrade(r, c, device: device)
        default:
            // Sent compressed when the browser takes it (all do): 57 KB rather than 189 KB on a phone.
            let gz = (r.headers["accept-encoding"] ?? "").contains("gzip")
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\nContent-Length: \((gz ? WebAssets.novncGz : WebAssets.novnc).count)\r\n"
                + (gz ? "Content-Encoding: gzip\r\n" : "") + "Cache-Control: private, max-age=31536000, immutable\r\nConnection: close\r\n\r\n"
            c.write(Data(head.utf8) + (gz ? WebAssets.novncGz : WebAssets.novnc))
            drop(c)
        }
    }

    private func upgrade(_ r: Request, _ c: Conn, device: String) {
        guard r.headers["upgrade"]?.lowercased() == "websocket", r.headers["sec-websocket-version"] == "13",
              let key = r.headers["sec-websocket-key"], !key.isEmpty else { return send(c, 400, "text/plain", Data("WebSocket only".utf8)) }
        guard Screen.relays.count < Screen.maxSessions else {
            return send(c, 503, "text/plain", Data("This Mac's screen is already open in \(Screen.maxSessions) places.".utf8))
        }
        guard let vnc = Screen.connectLocal(Screen.port) else {
            return send(c, 503, "text/plain", Data("Screen Sharing is off on this Mac.".utf8))
        }
        // noVNC asks for the "binary" subprotocol; a browser drops the socket unless it is echoed.
        let wantsBinary = (r.headers["sec-websocket-protocol"] ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "binary" }
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(Screen.accept(key))\r\n" + (wantsBinary ? "Sec-WebSocket-Protocol: binary\r\n" : "") + "\r\n"
        guard c.write(Data(head.utf8)) else { close(vnc); return drop(c) }
        // The relay takes its own copy of the socket; dropping the connection here closes only ours.
        let fd = dup(c.fd)
        drop(c)
        Control.record("Screen opened from \(device)")
        let relay = ScreenRelay(client: fd, vnc: vnc, device: device) { relay, why, seconds in
            Screen.remove(relay)
            // What it moved, as the real-world benchmark: sizes and rates only, never what was on screen.
            let mb = Double(relay.fromMac) / 1e6, avg = seconds > 0 ? mb / seconds : 0, peak = Double(relay.peakPerSecond) / 1e6
            Control.record("Screen closed from \(relay.device) after \(F.duration(seconds)): \(why) · "
                + String(format: "%.1f MB from the Mac, %.2f MB/s on average, %.2f MB/s at most", mb, avg, peak))
        }
        Screen.add(relay)
        relay.start()
    }
}

/// "45 s", "3 min", "1 h 5 min".
enum F {
    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return s < 60 ? "\(Int(s)) s" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}

/// The short name of whoever is signed in at the Mac's screen, which is who Screen Sharing will show.
func consoleUser() -> String? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, name != "loginwindow" else { return nil }
    return name
}
