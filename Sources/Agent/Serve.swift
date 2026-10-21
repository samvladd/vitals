import Foundation
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
    let peer = option("--peer").map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    let origins = Set((option("--allow-origin") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " /")) })
    server = WebServer(listener: fd, peer: peer, origins: origins)
    server?.start()
    dispatchMain()
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
    if let peer = option("--peer") {
        guard URL(string: peer)?.scheme == "https" else { fail("--peer takes https://other-mac.your-tailnet.ts.net") }
        a += ["--peer", peer]
    }
    if let o = option("--allow-origin") { a += ["--allow-origin", o] }
    let listener: [String: Any] = ["SockNodeName": "127.0.0.1", "SockServiceName": String(port), "SockType": "stream", "SockFamily": "IPv4"]
    installLaunchAgent("com.vitals.serve", a, ["RunAtLoad": false, "KeepAlive": false, "Sockets": ["Listener": listener]])
    // Shows Tailscale's own output: the first time, it prints a link to enable Serve on the tailnet
    // and waits for it, so give up after a while rather than hang.
    let ts = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
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
        if let r = Request(c.buf) { c.buf = Data(); route(r, c) }
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
        guard let o = c.origin, origins.contains(o) else { return "" }
        return "Access-Control-Allow-Origin: \(o)\r\nVary: Origin\r\n"
    }

    private func send(_ c: Conn, _ status: Int, _ type: String, _ body: Data, cache: String = "no-store") {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict"][status] ?? ""
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: \(cache)\r\n\(cors(c))Connection: close\r\n\r\n"
        c.write(Data(head.utf8) + body)
        drop(c)
    }

    private func send(_ c: Conn, _ status: Int, json body: String) { send(c, status, "application/json", Data(body.utf8)) }

    private func route(_ r: Request, _ c: Conn) {
        c.origin = r.headers["origin"]
        // A page on another site can post here from a tailnet browser, but it cannot add this header
        // without a CORS preflight, which this server never grants.
        if r.method == "POST", r.headers["x-vitals"] != "1" { return send(c, 403, json: #"{"error":"forbidden"}"#) }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            // Revalidated on each open so an update shows at once; it is small and only on the tailnet.
            send(c, 200, "text/html; charset=utf-8", WebAssets.page, cache: "no-cache")
        case ("GET", "/manifest.webmanifest"): send(c, 200, "application/manifest+json", Data(Self.manifest.utf8), cache: "max-age=604800")
        case ("GET", "/icon.png"), ("GET", "/apple-touch-icon.png"): send(c, 200, "image/png", WebAssets.icon, cache: "max-age=604800")
        case ("GET", "/config"): send(c, 200, json: "{\"peer\":\(peer.map { "\"\($0)\"" } ?? "null"),\"info\":\(info)}")
        case ("GET", "/events"): watch(c)
        case ("GET", "/history"): history(r, c)
        case ("GET", "/ssd"):
            DispatchQueue.global(qos: .utility).async {
                let body = ssdHealth().map(json) ?? "null"
                DispatchQueue.main.async { [weak self] in self?.send(c, 200, json: body) }
            }
        case ("GET", "/space"): send(c, 200, json: SpaceScanner.shared.current(fresh: r.query["fresh"] == "1").map(json) ?? "null")
        case ("POST", "/fan"): fan(r, c)
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
        if !watchers.isEmpty || SpaceScanner.shared.busy { lastBusy = now }
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
}
