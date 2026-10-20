import Foundation

/// One Mac being watched. The agent runs there (over one SSH connection) or here (as a child
/// process) and streams a JSON line per tick; this object keeps the latest values and a short
/// live history, reconnects on its own, and installs the agent when it is missing or old.
final class HostLink {
    enum State: Equatable { case connecting, installing, live, offline(String) }

    let key: String                 // "remote" or "local"
    var sshHost: String?            // nil means this Mac
    private(set) var info: MachineInfo?
    private(set) var snap: Snapshot?
    private(set) var live: [(t: Double, w: Double)] = []
    private(set) var history: History?
    private(set) var state: State = .connecting
    private(set) var nextRetry: Date?
    var onUpdate: (() -> Void)?

    var interval: Double = 5 { didSet { if oldValue != interval { send("interval \(interval)") } } }
    /// The process list costs the agent the most, so it is only gathered while someone is looking.
    var wantsProcs = false { didSet { if oldValue != wantsProcs { send("procs \(wantsProcs ? "on" : "off")") } } }

    private var proc: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var backoff = 2.0
    private var retryItem: DispatchWorkItem?
    private var fetchingHistory = false
    private var installed = false

    static let agentInBundle = Bundle.main.url(forResource: "vitals-agent", withExtension: nil)!
    static let localAgent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vitals/bin/vitals-agent")
    private static let controlDir: String = {
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Vitals").path
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }()

    init(key: String, sshHost: String?) { self.key = key; self.sshHost = sshHost }

    var isLocal: Bool { sshHost == nil }
    var shortName: String {
        guard let m = info?.model else { return isLocal ? "This Mac" : "Mac mini" }
        return m.components(separatedBy: " (").first ?? m
    }

    private var sshOptions: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
         "-o", "ControlMaster=auto", "-o", "ControlPath=\(Self.controlDir)/ssh-%C", "-o", "ControlPersist=120"]
    }

    private func agentPath() -> String { isLocal ? Self.localAgent.path : "$HOME/.vitals/vitals-agent" }

    private var streamScript: String {
        """
        A="\(agentPath())"
        [ "$("$A" version 2>/dev/null)" = "\(vitalsVersion)" ] || { echo NEEDS_AGENT; exit 3; }
        exec "$A" stream
        """
    }

    // MARK: streaming

    func start() {
        stop()
        retryItem?.cancel(); nextRetry = nil
        state = .connecting
        if isLocal { installLocalAgent() }
        let p = Process()
        if let host = sshHost {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = sshOptions + [host, streamScript]
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", streamScript]
        }
        let out = Pipe(), inp = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.consume(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.stderrTail = String((self?.stderrTail ?? "") + s).suffix(400).description }
        }
        p.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            DispatchQueue.main.async { self?.ended(p, status: status) }
        }
        do { try p.run() } catch { state = .offline("Could not start ssh."); scheduleRetry(); return }
        proc = p; input = inp.fileHandleForWriting
        send("interval \(interval)")
        if wantsProcs { send("procs on") }
        onUpdate?()
    }

    func stop() {
        guard let p = proc else { return }
        proc = nil
        try? input?.close()             // EOF tells the agent to hand the fans back and exit
        input = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }

    func send(_ line: String) {
        guard let input else { return }
        try? input.write(contentsOf: (line + "\n").data(using: .utf8)!)
    }

    private func consume(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(Data(line))
        }
    }

    private func handle(_ line: Data) {
        if line.starts(with: Array("NEEDS_AGENT".utf8)) { installRemoteAgent(); return }
        let dec = JSONDecoder()
        if let s = try? dec.decode(Snapshot.self, from: line), s.t > 0 {
            snap = s
            if let w = s.wSystem { live.append((s.t, w)) }
            if let first = live.first, s.t - first.t > 900 { live.removeFirst(live.count / 4) }
            if state != .live {
                state = .live; backoff = 2
                let p = Prefs.fanPolicy(key)
                if s.root, p != "auto" { send("fan \(p)") }
            }
            onUpdate?()
        } else if let i = try? dec.decode(MachineInfo.self, from: line) {
            info = i
            onUpdate?()
        }
    }

    private func ended(_ p: Process, status: Int32) {
        guard proc === p || proc == nil else { return }
        proc = nil; input = nil
        if state == .installing { return }
        let e = stderrTail.lowercased()
        let why: String
        if e.contains("could not resolve") { why = "Can't find \(sshHost ?? "") on the network." }
        else if e.contains("timed out") || e.contains("no route") { why = "\(sshHost ?? "This Mac") isn't answering. It may be asleep or off Tailscale." }
        else if e.contains("permission denied") { why = "SSH refused the key for \(sshHost ?? "")." }
        else if proc == nil && status == 0 && state == .connecting { why = "The connection closed." }
        else { why = isLocal ? "The local agent stopped." : "Lost the connection to \(sshHost ?? "")." }
        stderrTail = ""
        state = .offline(why)
        onUpdate?()
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.start() }
        retryItem = item
        nextRetry = Date(timeIntervalSinceNow: backoff)
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: item)
        backoff = min(backoff * 2, 60)
    }

    // MARK: agent install

    private func installLocalAgent() {
        guard !installed else { return }
        installed = true
        let fm = FileManager.default
        let bundled = try? Data(contentsOf: Self.agentInBundle)
        guard let bundled, (try? Data(contentsOf: Self.localAgent)) != bundled else { return }
        try? fm.createDirectory(at: Self.localAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = Self.localAgent.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        try? bundled.write(to: tmp)
        chmod(tmp.path, 0o755)
        _ = try? fm.replaceItemAt(Self.localAgent, withItemAt: tmp)
        run(Self.localAgent.path, ["install-logger"])
    }

    private func installRemoteAgent() {
        guard let host = sshHost else { return }
        state = .installing
        onUpdate?()
        let opts = sshOptions
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = self?.run("/usr/bin/ssh", opts + [host, "mkdir -p ~/.vitals"]) == 0
                && self?.run("/usr/bin/scp", opts + ["-q", Self.agentInBundle.path, "\(host):.vitals/vitals-agent.new"]) == 0
                && self?.run("/usr/bin/ssh", opts + [host, "chmod +x ~/.vitals/vitals-agent.new && mv ~/.vitals/vitals-agent.new ~/.vitals/vitals-agent && ~/.vitals/vitals-agent install-logger"]) == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = ok ? .connecting : .offline("Couldn't install the agent on \(host).")
                if ok { self.start() } else { self.onUpdate?(); self.scheduleRetry() }
            }
        }
    }

    @discardableResult
    private func run(_ path: String, _ args: [String], output: UnsafeMutablePointer<Data>? = nil) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        output?.pointee = data
        return p.terminationStatus
    }

    // MARK: history and fans

    func fetchHistory() {
        guard !fetchingHistory, state == .live else { return }
        fetchingHistory = true
        let (path, args): (String, [String]) = isLocal
            ? (Self.localAgent.path, ["history", "24"])
            : ("/usr/bin/ssh", sshOptions + [sshHost!, "~/.vitals/vitals-agent history 24"])
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var data = Data()
            _ = self?.run(path, args, output: &data)
            let h = try? JSONDecoder().decode(History.self, from: data)
            DispatchQueue.main.async {
                self?.fetchingHistory = false
                if let h { self?.history = h; self?.onUpdate?() }
            }
        }
    }

    func setFan(_ policy: String) {
        Prefs.setFanPolicy(key, policy)
        send("fan \(policy)")
    }

    /// The command that enables fan control (asks for the admin password once).
    var setupCommand: String {
        isLocal ? "sudo \"\(Self.localAgent.path)\" setup-root"
                : "ssh -t \(sshHost ?? "") 'sudo ~/.vitals/vitals-agent setup-root'"
    }
}
