import Foundation
import Network

// `serve`: the phone dashboard. A tiny HTTP server bound to 127.0.0.1 only; `tailscale serve` puts it
// on the tailnet over HTTPS, so nothing listens on a network interface. It samples only while a page
// is open, and a fan it moved off Auto goes back to Auto when the pages stop checking in.

let peerKey = NSHomeDirectory() + "/.vitals/peer_key"

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func validPeer(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "@._-".contains($0) } }

func json<T: Encodable>(_ v: T) -> String { (try? JSONEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null" }

/// Minute rows averaged into longer buckets, so a day of history stays small on a phone.
func coarse(_ h: History, every step: Double) -> History {
    var out: [LogRow] = [], group: [LogRow] = []
    func flush() {
        guard let first = group.first else { return }
        func mean(_ k: KeyPath<LogRow, Double>) -> Double { group.reduce(0) { $0 + $1[keyPath: k] } / Double(group.count) }
        out.append(LogRow(t: (first.t / step).rounded(.down) * step, w: mean(\.w), wMax: group.map(\.wMax).max() ?? 0,
                          cpu: mean(\.cpu), gpu: mean(\.gpu), temp: mean(\.temp), fan: mean(\.fan), mem: mean(\.mem), swap: mean(\.swap)))
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
    let peer = option("--peer").flatMap { validPeer($0) ? Peer($0) : nil }
    server = WebServer(port: port, peer: peer)
    server?.start()
    dispatchMain()
}

func installServe() {
    let port = option("--port").flatMap(UInt16.init) ?? 8787
    var a = ["serve", "--port", String(port)]
    let peer = option("--peer")
    if let peer {
        guard validPeer(peer) else { fail("--peer takes user@host") }
        a += ["--peer", peer]
        if !FileManager.default.fileExists(atPath: peerKey) {
            run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "vitals-peer", "-f", peerKey])
        }
    }
    installLaunchAgent("com.vitals.serve", a)
    let tailscale = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    // Shows Tailscale's own output: the first time, it prints a link to enable Serve on the tailnet
    // and waits for it, so give up after a while rather than hang.
    let ts = tailscale.map { t -> Process in
        let p = Process(); p.executableURL = URL(fileURLWithPath: t); p.arguments = ["serve", "--bg", String(port)]; return p
    }
    if let ts, (try? ts.run()) != nil {
        let deadline = Date(timeIntervalSinceNow: 30)
        while ts.isRunning, Date() < deadline { usleep(200_000) }
        if ts.isRunning { ts.terminate(); print("Run `tailscale serve --bg \(port)` again once Serve is enabled.") }
    } else {
        print("Serving on 127.0.0.1:\(port). To reach it from your phone: tailscale serve --bg \(port)")
    }
    if let peer, let pub = try? String(contentsOfFile: peerKey + ".pub", encoding: .utf8) {
        print("To show \(peer) too, add this line to ~/.ssh/authorized_keys on it (it can only read readings):")
        print("restrict,command=\"exec \\\"$HOME/Library/Application Support/Vitals/bin/vitals-agent\\\" gate\" " + pub.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The forced command for the dashboard's key on a peer Mac: it may stream and read history, and
/// it cannot touch the fans.
func gate() -> Never {
    let w = (ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"] ?? "").split(separator: " ").map(String.init)
    switch w.first {
    case "stream": fanCommandsAllowed = false; stream()
    case "history": emit(loadHistory(hours: min(336, max(0, w.dropFirst().first.flatMap(Double.init) ?? 24)))); exit(0)
    case "info": emit(machineInfo()); exit(0)
    default: fail("vitals gate: only stream, history and info")
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

final class WebServer {
    /// A fan stays off Auto only while an open page keeps checking in...
    static let lease = 90.0
    /// ...and goes back to Auto this long after the last page closes.
    static let grace = 30.0

    private let port: UInt16
    private let peer: Peer?
    private var listener: NWListener?
    private var watchers: [ObjectIdentifier: NWConnection] = [:]
    private var sampler: Sampler?
    private let driver = FanDriver()
    private let ticker = DispatchSource.makeTimerSource(queue: .main)
    private let chores = DispatchSource.makeTimerSource(queue: .main)
    private var ticking = false
    private var lastLine: String?
    private var lastAlive = Date.distantPast
    private var emptySince: Date?
    private let info = json(machineInfo())
    private let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    private lazy var built = modified(binary)

    init(port: UInt16, peer: Peer?) { self.port = port; self.peer = peer }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: params) else { fail("cannot listen on 127.0.0.1:\(port)") }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { if case .failed(let e) = $0 { fail("listener failed: \(e)") } }
        l.start(queue: .main)
        listener = l
        _ = built
        ticker.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        ticker.setEventHandler { [weak self] in self?.tick() }
        chores.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        chores.setEventHandler { [weak self] in self?.housekeeping() }
        chores.resume()
    }

    private func accept(_ c: NWConnection) {
        c.stateUpdateHandler = { if case .failed = $0 { c.cancel() } }
        c.start(queue: .main)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] d, _, done, err in
            guard let self else { return }
            var buf = buf
            if let d { buf.append(d) }
            if let r = Request(buf) { self.route(r, c) }
            else if done || err != nil || buf.count > 65536 { c.cancel() }
            else { self.read(c, buf) }
        }
    }

    private func send(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, cache: Bool = false) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 504: "Gateway Timeout"][status] ?? ""
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: \(cache ? "max-age=86400" : "no-store")\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in c.cancel() })
    }

    private func send(_ c: NWConnection, _ status: Int, json body: String) {
        send(c, status, "application/json", Data(body.utf8))
    }

    private func route(_ r: Request, _ c: NWConnection) {
        // A page on another site can post here from a tailnet browser, but it cannot add this header
        // without a CORS preflight, which this server never grants.
        if r.method == "POST", r.headers["x-vitals"] != "1" { return send(c, 403, json: #"{"error":"forbidden"}"#) }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"): send(c, 200, "text/html; charset=utf-8", WebAssets.page)
        case ("GET", "/manifest.webmanifest"): send(c, 200, "application/manifest+json", Data(Self.manifest.utf8), cache: true)
        case ("GET", "/icon.png"), ("GET", "/apple-touch-icon.png"): send(c, 200, "image/png", WebAssets.icon, cache: true)
        case ("GET", "/events"): watch(c)
        case ("GET", "/info"): send(c, 200, json: info)
        case ("GET", "/history"): history(r, c)
        case ("GET", "/peer"):
            guard let peer else { return send(c, 200, json: #"{"state":"none"}"#) }
            send(c, 200, json: peer.status())
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

    private func watch(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Accel-Buffering: no\r\n\r\n"
        c.send(content: Data((head + "retry: 2000\n\nevent: info\ndata: \(info)\n\n" + (lastLine ?? "")).utf8), completion: .contentProcessed { _ in })
        watchers[ObjectIdentifier(c)] = c
        emptySince = nil
        c.stateUpdateHandler = { [weak self] st in
            switch st { case .failed, .cancelled: self?.drop(c); default: break }
        }
        awaitClose(c)
        if !ticking {
            if sampler == nil { sampler = Sampler(procs: true) }
            _ = sampler?.sample()            // restart the rate counters after an idle spell
            ticking = true
            ticker.resume()
        }
    }

    /// The page sends nothing on this connection, so a read that ends means it went away.
    private func awaitClose(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            if done || err != nil { self?.drop(c) } else { self?.awaitClose(c) }
        }
    }

    private func drop(_ c: NWConnection) {
        guard watchers.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        c.cancel()
        guard watchers.isEmpty else { return }
        emptySince = Date()
        lastLine = nil
        if ticking { ticker.suspend(); ticking = false }
    }

    private func tick() {
        guard let sampler, !watchers.isEmpty else { return }
        var s = sampler.sample()
        s.fanPolicy = driver.policy
        s.root = driver.available
        let line = "data: \(json(s))\n\n"
        lastLine = line
        let data = Data(line.utf8)
        for c in watchers.values {
            c.send(content: data, completion: .contentProcessed { [weak self] e in if e != nil { self?.drop(c) } })
        }
    }

    private func housekeeping() {
        let now = Date()
        if driver.policy != "auto",
           now.timeIntervalSince(lastAlive) > Self.lease || emptySince.map({ now.timeIntervalSince($0) > Self.grace }) == true {
            driver.set("auto")
        }
        peer?.idle()
        // The app replaced this binary with a newer one: let launchd start that instead.
        if watchers.isEmpty, driver.policy == "auto", modified(binary) != built { exit(0) }
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: history and fans

    private func history(_ r: Request, _ c: NWConnection) {
        let hours: Double = ["10m": 1, "1h": 1, "24h": 24, "14d": 0][r.query["range"] ?? ""] ?? 1
        let done: (History?) -> Void = { [weak self] h in
            guard let h else { self?.send(c, 504, json: #"{"error":"unreachable"}"#); return }
            self?.send(c, 200, json: json(hours >= 24 ? coarse(h, every: 300) : h))
        }
        if r.query["host"] == "peer" {
            guard let peer else { return send(c, 404, json: #"{"error":"no peer"}"#) }
            peer.history(hours: hours, done)
        } else {
            DispatchQueue.global(qos: .utility).async {
                let h = loadHistory(hours: hours)
                DispatchQueue.main.async { done(h) }
            }
        }
    }

    private func fan(_ r: Request, _ c: NWConnection) {
        let words = r.body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let p = FanControl.Policy(words) else { return send(c, 400, json: #"{"error":"auto, fixed RPM or curve LOW HIGH"}"#) }
        guard driver.available else {
            return send(c, 409, json: #"{"error":"Fan control needs a one-time setup on this Mac: sudo ~/.vitals/vitals-agent setup-root"}"#)
        }
        lastAlive = Date()
        driver.set(p.text)
        tick()
        send(c, 200, json: "{\"policy\":\"\(p.text)\"}")
    }
}

// MARK: peer

/// The other Mac, read over SSH with a key that its authorized_keys pins to `vitals-agent gate`.
/// Connected only while a page is looking at it.
final class Peer {
    let host: String
    private var proc: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var info: String?
    private var snap: String?
    private var seen: Double
    private var gotData = false
    private var asked = Date.distantPast
    private var retryAt = Date.distantPast
    private static let seenFile = NSHomeDirectory() + "/.vitals/peer-seen"

    init(_ host: String) {
        self.host = host
        seen = (try? String(contentsOfFile: Self.seenFile, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    private var ssh: [String] {
        ["-i", peerKey, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=accept-new",
         "-o", "UserKnownHostsFile=\(NSHomeDirectory())/.vitals/known_hosts", host]
    }

    /// The latest reading for the page, or why there is none and when it was last seen.
    func status() -> String {
        asked = Date()
        if proc == nil, Date() >= retryAt { start() }
        let live = snap != nil && Date().timeIntervalSince1970 - seen < 6
        let state = live ? "live" : (proc != nil && !gotData) ? "connecting" : "asleep"
        return "{\"state\":\"\(state)\",\"host\":\"\(host)\",\"seen\":\(seen),\"info\":\(info ?? "null"),\"snap\":\(live ? snap! : "null")}"
    }

    private func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ssh + ["stream"]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] p in DispatchQueue.main.async { self?.ended(p) } }
        guard (try? p.run()) != nil else { retryAt = Date(timeIntervalSinceNow: 15); return }
        proc = p; input = inp.fileHandleForWriting; gotData = false; buffer = Data()
        try? input?.write(contentsOf: Data("interval 1\nprocs on\n".utf8))
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            let text = String(decoding: line, as: UTF8.self)
            if (try? JSONDecoder().decode(MachineInfo.self, from: line)) != nil { info = text }
            else if text.hasPrefix("{") { snap = text; seen = Date().timeIntervalSince1970; gotData = true }
        }
    }

    private func ended(_ p: Process) {
        guard proc === p else { return }
        proc = nil; input = nil
        retryAt = Date(timeIntervalSinceNow: gotData ? 2 : 15)    // asleep or off the tailnet: try again later
        try? String(seen).write(toFile: Self.seenFile, atomically: true, encoding: .utf8)
    }

    /// Called every few seconds: hang up once no page has asked for a while.
    func idle() {
        guard let p = proc, Date().timeIntervalSince(asked) > 20 else { return }
        try? input?.close()
        input = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
    }

    func history(hours: Double, _ done: @escaping (History?) -> Void) {
        let a = ssh + ["history \(Int(hours))"]
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = a
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            var h: History?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                h = try? JSONDecoder().decode(History.self, from: data)
            }
            DispatchQueue.main.async { done(h) }
        }
    }
}
