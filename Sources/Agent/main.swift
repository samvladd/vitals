import Foundation

// vitals-agent: runs on each Mac. The menu bar app starts `stream` over SSH (or locally) and reads
// one JSON line per tick; `log` runs under launchd and keeps a per-minute record on disk; `serve`
// is started by launchd when a phone opens the dashboard (Serve.swift).

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
let rootPath = "/usr/local/libexec/vitals-agent"
let logDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Vitals/Logs")
let encoder = JSONEncoder()
let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

func emit<T: Encodable>(_ v: T) {
    guard let d = try? encoder.encode(v), let s = String(data: d, encoding: .utf8) else { return }
    if fputs(s + "\n", stdout) < 0 || fflush(stdout) != 0 { exit(0) }
}

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

// MARK: stream

var signalSources: [DispatchSourceSignal] = []

/// Fan writes need root. The streaming agent runs as you; when a fan leaves Auto it starts the
/// root-owned copy (allowed by the sudo rule from `setup-root`) as a driver and passes it the policy.
/// Closing the driver's input hands the fans back to macOS, also if this agent dies.
final class FanDriver {
    static let path = rootPath
    let available: Bool
    private(set) var policy = "auto"
    private var proc: Process?
    private var input: FileHandle?

    init() {
        available = FileManager.default.isExecutableFile(atPath: Self.path) && run("/usr/bin/sudo", ["-n", "-l", Self.path, "stream"]) == 0
    }

    func set(_ p: String) {
        policy = p
        guard available else { return }
        if p == "auto" { stop(); return }
        if proc?.isRunning != true { start() }
        send("fan \(p)")
    }

    private func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", Self.path, "stream"]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        proc = p; input = pipe.fileHandleForWriting
        send("interval 2")
    }

    func stop() {
        try? input?.close()
        input = nil; proc = nil
    }

    private func send(_ line: String) { try? input?.write(contentsOf: Data((line + "\n").utf8)) }
}

func stream() -> Never {
    let sampler = Sampler(procs: false)
    let fans = (geteuid() == 0) ? sampler.smc.map { FanControl(smc: $0) } : nil
    let driver = fans == nil ? FanDriver() : nil
    var interval = 2.0
    let timer = DispatchSource.makeTimerSource(queue: .main)

    func tick() {
        var s = sampler.sample()
        fans?.apply(cpuTemp: s.tCPU)
        s.fanPolicy = fans?.policy.text ?? driver?.policy ?? "auto"
        if let driver { s.root = driver.available }
        emit(s)
    }
    func schedule() { timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100))) }
    func quit() -> Never { fans?.release(); driver?.stop(); usleep(300_000); exit(0) }

    timer.setEventHandler(handler: tick)
    _ = sampler.sample()                        // prime the counters so the first line has rates
    usleep(250_000)
    var info = machineInfo()
    info.screen = Control.screenURL()
    emit(info)
    tick()
    schedule()
    timer.resume()

    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { quit() }
        src.resume()
        signalSources.append(src)
    }

    Thread.detachNewThread {
        while let line = readLine() {
            let w = line.split(separator: " ").map(String.init)
            DispatchQueue.main.async {
                switch w.first {
                case "interval": if let v = w.dropFirst().first.flatMap(Double.init), v >= 0.5, v <= 60 { interval = v; schedule() }
                case "fan":
                    if let p = FanControl.Policy(Array(w.dropFirst())) { fans?.set(p); driver?.set(p.text); tick() }
                case "now": tick()
                case "procs": sampler.withProcs = w.dropFirst().first == "on"
                default: break
                }
            }
        }
        DispatchQueue.main.async { quit() }    // the app went away: hand the fans back
    }
    dispatchMain()
}

// MARK: log

func logForever() -> Never {
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let sampler = Sampler(procs: false)
    var bucket: [Snapshot] = []
    var minute = Int(Date().timeIntervalSince1970 / 60)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
    _ = sampler.sample()
    timer.setEventHandler {
        let s = sampler.sample()
        let m = Int(s.t / 60)
        if m != minute, !bucket.isEmpty { write(bucket, minute: minute); bucket = [] }
        minute = m
        bucket.append(s)
    }
    timer.resume()
    dispatchMain()
}

func write(_ b: [Snapshot], minute: Int) {
    func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    let w = b.compactMap(\.wSystem)
    let t = Double(minute * 60)
    let cols: [Double] = [t, mean(w), w.max() ?? 0, mean(b.compactMap(\.cpu)), mean(b.compactMap(\.gpu)),
                          mean(b.compactMap(\.tCPU)), mean(b.compactMap { $0.fans.first?.rpm }),
                          mean(b.map(\.memUsed)), mean(b.map(\.swapUsed)), Double(b.count * 10),
                          b.last?.volumes.first(where: \.boot)?.free ?? 0]
        + BatteryCare.logColumns(b)     // battery %, power state (0 battery, 1 on power, 2 charging); -1 without a battery
    let line = cols.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.2f", $0) }.joined(separator: ",") + "\n"
    let file = logDir.appendingPathComponent(dayFormat.string(from: Date(timeIntervalSince1970: t)) + ".csv")
    if let h = try? FileHandle(forWritingTo: file) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? ("t,watts,watts_max,cpu,gpu,cpu_temp,fan_rpm,mem_used,swap_used,seconds,free,battery,power\n" + line).write(to: file, atomically: true, encoding: .utf8)
    }
    // Keep a year.
    if minute % 1440 == 0, let files = try? FileManager.default.contentsOfDirectory(atPath: logDir.path) {
        let cutoff = dayFormat.string(from: Date(timeIntervalSinceNow: -366 * 86400))
        for f in files where f < cutoff { try? FileManager.default.removeItem(at: logDir.appendingPathComponent(f)) }
    }
}

// MARK: history

func loadHistory(hours: Double) -> History {
    let since = Date().timeIntervalSince1970 - hours * 3600
    var rows: [LogRow] = [], days: [DayTotal] = []
    for back in (0..<14).reversed() {
        let day = dayFormat.string(from: Date(timeIntervalSinceNow: -Double(back) * 86400))
        guard let text = try? String(contentsOf: logDir.appendingPathComponent(day + ".csv"), encoding: .utf8) else { continue }
        var wh = 0.0, peak = 0.0, n = 0
        for line in text.split(separator: "\n").dropFirst() {
            let c = line.split(separator: ",").compactMap { Double($0) }
            guard c.count >= 10 else { continue }
            wh += c[1] * c[9] / 3600; peak = max(peak, c[2]); n += 1
            if c[0] >= since {
                rows.append(LogRow(t: c[0], w: c[1], wMax: c[2], cpu: c[3], gpu: c[4], temp: c[5], fan: c[6], mem: c[7], swap: c[8],
                                   free: c.count > 10 && c[10] > 0 ? c[10] : nil))
            }
        }
        days.append(DayTotal(day: day, wh: wh, peak: peak, minutes: n))
    }
    return History(rows: rows, days: days)
}

// MARK: setup

func installLogger() {
    installLaunchAgent("com.vitals.logger", ["log"], ["ProcessType": "Background", "LowPriorityIO": true, "Nice": 10])
}

func installLaunchAgent(_ label: String, _ arguments: [String], _ extra: [String: Any] = [:]) {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let plist = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    let dict = ["Label": label, "ProgramArguments": [me] + arguments, "RunAtLoad": true, "KeepAlive": true]
        .merging(extra) { _, b in b }
    try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try! data.write(to: plist)
    let uid = getuid()
    for domain in ["gui/\(uid)", "user/\(uid)"] {
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if run("/bin/launchctl", ["bootstrap", domain, plist.path]) == 0 { print("\(label) running in \(domain)"); return }
    }
    fail("could not start \(label) with launchctl")
}

@discardableResult func run(_ path: String, _ a: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = a
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit(); return p.terminationStatus
}

/// Run once with sudo: installs a root-owned copy and a sudoers rule that lets this user start
/// exactly that copy, so fan control needs no password afterwards.
func setupRoot() {
    guard geteuid() == 0 else { fail("run with sudo") }
    let named = args.count > 2 && args[1] == "--user" ? args[2] : nil
    guard let user = named ?? ProcessInfo.processInfo.environment["SUDO_USER"], user != "root",
          user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { fail("run with sudo from your own account") }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let fm = FileManager.default
    try? fm.createDirectory(atPath: "/usr/local/libexec", withIntermediateDirectories: true)
    if me != rootPath {
        try? fm.removeItem(atPath: rootPath)
        do { try fm.copyItem(atPath: me, toPath: rootPath) } catch { fail("copy failed: \(error)") }
    }
    chown(rootPath, 0, 0); chmod(rootPath, 0o755)
    let rule = "\(user) ALL=(root) NOPASSWD: \(rootPath) stream\n"
    let tmp = "/etc/sudoers.d/.vitals.tmp"
    try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)
    chown(tmp, 0, 0); chmod(tmp, 0o440)
    guard run("/usr/sbin/visudo", ["-cf", tmp]) == 0 else { try? fm.removeItem(atPath: tmp); fail("sudoers check failed") }
    try? fm.removeItem(atPath: "/etc/sudoers.d/vitals")
    do { try fm.moveItem(atPath: tmp, toPath: "/etc/sudoers.d/vitals") } catch { fail("could not install the rule: \(error)") }
    print("Fan control enabled for \(user).")
}

func removeRoot() {
    guard geteuid() == 0 else { fail("run with sudo") }
    BatteryCare.uninstall(quiet: true)      // its daemon runs from the copy removed below
    try? FileManager.default.removeItem(atPath: "/etc/sudoers.d/vitals")
    try? FileManager.default.removeItem(atPath: rootPath)
    print("Fan control removed.")
}

// MARK: commands

switch args.first ?? "" {
case "stream": stream()
case "log": logForever()
case "history": emit(loadHistory(hours: args.dropFirst().first.flatMap(Double.init) ?? 24))
case "serve": serve()
case "install-serve": installServe()
case "control": controlCommand()
case "screen": screenCommand()
case "info": emit(machineInfo())
case "once":
    let s = Sampler(procs: true); _ = s.sample(); usleep(1_000_000); emit(s.sample())
case "fan":
    guard geteuid() == 0, let smc = SMC() else { fail("fan control needs root") }
    let f = FanControl(smc: smc)
    if args.dropFirst().first == "auto" { f.release() } else { fail("only `fan auto` is available outside stream") }
case "install-logger": installLogger()
case "setup-root": setupRoot()
case "battery": BatteryCare.command()
case "battery-daemon": BatteryCare.daemon()
case "remove-root": removeRoot()
case "version": print(vitalsVersion)
case "energy-channels": print(EnergyReport()?.channelNames().joined(separator: "\n") ?? "no IOReport")
default:
    print("vitals-agent \(vitalsVersion): stream | log | history [hours] | info | once | serve [--port N] [--peer URL] [--allow-origin URL] | install-serve [same] | control [on --from DEVICE,... | off] | screen [on | off] | install-logger | setup-root | remove-root | battery [limit N|off | keys | install | uninstall] | fan auto | version")
}
