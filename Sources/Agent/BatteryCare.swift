import Foundation
import IOKit
import IOKit.pwr_mgt

// Battery care: insights for the dashboard, and a charge limit (stop charging at, say, 80%).
//
// Two ways to hold the limit, picked per Mac, never both:
//  1. macOS's own charge limit (macOS 26.4+, Apple silicon; 80-100%). Firmware enforces it, also
//     asleep and across restarts, and no root is needed. Vitals sets it through PowerUI, the private
//     framework behind System Settings › Battery › Charging, and reads it back.
//  2. Otherwise, on older firmware, an SMC switch (CHTE or CH0B/CH0C) held by a small root daemon,
//     `vitals-agent battery-daemon`, run by launchd as com.vitals.battery from the root-owned copy
//     at /usr/local/libexec/vitals-agent. It reads only one number, the limit, from a file you own
//     (~/Library/Application Support/Vitals/battery.json), so no new sudo rule is needed. Its safety
//     rules are in ChargeController (Core/Battery.swift); on top of them it turns charging back on
//     when it stops, is unloaded, crashes (and again when launchd restarts it), and before sleep.
// Both are off until you set a limit. Neither is installed or written unless you ask.

enum BatteryCare {
    static let label = "com.vitals.battery"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let statusFile = "/var/run/vitals-battery.json"
    static let logFile = "/var/log/vitals-battery.log"
    static let configFile = supportDir.appendingPathComponent("battery.json")
    /// For tests: the page and the CLI pretend to set the limit and change nothing on the Mac.
    static let dryRun = ProcessInfo.processInfo.environment["VITALS_BATTERY_DRY_RUN"] != nil
    private static var simulated: NativeLimit.State?
    private static let smc = SMC()

    struct Config: Codable { var limit: Int? }

    static func config() -> Int? {
        (try? Data(contentsOf: configFile)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }?.limit
    }

    static func saveConfig(_ limit: Int?) throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(Config(limit: limit)).write(to: configFile, options: .atomic)
    }

    static var daemonInstalled: Bool { FileManager.default.fileExists(atPath: plist) }

    static func daemonStatus() -> CareStatus? {
        (try? Data(contentsOf: URL(fileURLWithPath: statusFile))).flatMap { try? JSONDecoder().decode(CareStatus.self, from: $0) }
    }

    /// Read only: which SMC charge switch this Mac's firmware has, if any.
    static func smcKey() -> ChargeKey? { smc.flatMap { s in ChargeKey.detect { s.bytes($0)?.data } } }

    static func battery() -> Battery? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let d = props?.takeRetainedValue() as? [String: Any], var b = Battery(registry: d) else { return nil }
        if b.temp == nil, let t = smc?.value("TB0T"), t > 0, t < 90 { b.temp = t }
        return b
    }

    static func native() -> NativeLimit.State? { dryRun ? (simulated ?? NativeLimit.state()) : NativeLimit.state() }

    enum Mechanism: String, Encodable { case macos, smc, none }

    static func mechanism(_ n: NativeLimit.State?, _ key: ChargeKey?) -> Mechanism {
        n?.supported == true ? .macos : key != nil ? .smc : .none
    }

    /// Sets the limit the one way this Mac supports. nil turns it off. Returns what happened, for people.
    static func setLimit(_ limit: Int?) -> (ok: Bool, message: String) {
        guard battery() != nil else { return (false, "This Mac has no battery.") }
        let n = native(), key = smcKey()
        switch mechanism(n, key) {
        case .macos:
            if let l = limit, !ChargePolicy.nativeRange.contains(l) { return (false, "macOS's own charge limit takes 80 to 100%.") }
            let want = limit == 100 ? nil : limit
            if dryRun {
                simulated = NativeLimit.State(supported: true, enabled: want != nil, limit: want ?? 100, optimized: n?.optimized, holdingAt: n?.holdingAt)
            } else if let err = NativeLimit.set(want) {
                return (false, err)
            }
            if config() != nil { try? saveConfig(nil) }            // never two mechanisms at once
            return (true, want.map { "macOS will stop charging at \($0)%." } ?? "Charge limit off: macOS charges to 100%.")
        case .smc:
            if let l = limit, !ChargePolicy.smcRange.contains(l) { return (false, "The limit can be 50 to 100%.") }
            let want = limit == 100 ? nil : limit
            do { try saveConfig(want) } catch { return (false, "Could not save the limit: \(error.localizedDescription)") }
            guard want != nil else { return (true, "Charge limit off: charging is allowed again within 15 seconds.") }
            return daemonInstalled ? (true, "Charging stops at \(want!)% (applied within 15 seconds).")
                : (true, "Saved. It takes effect after a one-time setup: sudo vitals-agent battery install")
        case .none:
            return (false, "This Mac offers no charge limit Vitals can use: no macOS charge limit (needs macOS 26.4) and no known SMC switch.")
        }
    }

    // MARK: HTTP (route in Serve.swift: GET /battery, GET /battery/history, POST /battery)

    struct Reply: Encodable {
        var battery: Battery?
        var mechanism: Mechanism
        var native: NativeLimit.State?
        var smcKey: String?
        var daemon: Bool
        var limit: Int?             // the SMC path's limit
        var status: CareStatus?
        var canChange: Bool
        var dryRun: Bool
        var message: String?
    }

    static func handle(_ r: Request, done: @escaping (Int, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var code = 200, body: String
            if r.path == "/battery/history" {
                let hours: Double = ["1h": 1, "24h": 24, "14d": 336][r.query["range"] ?? ""] ?? 24
                body = json(batteryHistory(hours: hours))
            } else {
                var message: String?
                if r.method == "POST" {
                    // Persistent, unlike a fan setting, so only from this Mac's own page (and, with app
                    // control on, only from the devices named for it).
                    let words = r.body.split(whereSeparator: \.isWhitespace).map(String.init)
                    let limit: Int?? = words.count == 2 && words[0] == "limit" ? (words[1] == "off" ? .some(nil) : Int(words[1]).map { .some($0) }) : nil
                    if !mayChange(r) { code = 403; message = "Only this Mac's own page can change its charge limit." }
                    else if let limit { let res = setLimit(limit); code = res.ok ? 200 : 409; message = res.message }
                    else { code = 400; message = "limit N | limit off" }
                }
                let n = native(), key = smcKey()
                body = json(Reply(battery: battery(), mechanism: mechanism(n, key), native: n, smcKey: key?.name, daemon: daemonInstalled,
                                  limit: config(), status: daemonInstalled ? daemonStatus() : nil, canChange: mayChange(r), dryRun: dryRun, message: message))
            }
            DispatchQueue.main.async { done(code, body) }
        }
    }

    static func mayChange(_ r: Request) -> Bool {
        if Control.load() != nil {
            if case .allowed = Control.gate(r, change: r.method == "POST") { return true }
            return false
        }
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map { $0.lowercased() } ?? ""
        if r.method == "POST" {
            guard let o = r.headers["origin"], URL(string: o)?.host?.lowercased() == host else { return false }
        }
        if let site = r.headers["sec-fetch-site"], site != "same-origin", site != "none" { return false }
        return true
    }

    // MARK: history: battery % and power state, logged each minute (main.swift, write)

    struct HistoryReply: Encodable { var rows: [[Double]] }     // [t, percent, state: 0 battery, 1 on power, 2 charging]

    /// The two battery columns for one logged minute; -1 on a Mac without a battery.
    static func logColumns(_ b: [Snapshot]) -> [Double] {
        let bs = b.compactMap(\.battery)
        guard let last = bs.last else { return [-1, -1] }
        return [(bs.map(\.percent).reduce(0, +) / Double(bs.count) * 10).rounded() / 10, last.charging ? 2 : last.external ? 1 : 0]
    }

    /// Columns 11 and 12 of the minute log (after `free`); rows from before they were logged are skipped.
    static func batteryHistory(hours: Double) -> HistoryReply {
        let since = Date().timeIntervalSince1970 - hours * 3600
        let step: Double = hours > 24 ? 3600 : hours > 1 ? 300 : 60
        var rows: [[Double]] = [], group: [[Double]] = []
        func flush() {
            guard let first = group.first else { return }
            rows.append([(first[0] / step).rounded(.down) * step, (group.map { $0[1] }.reduce(0, +) / Double(group.count) * 10).rounded() / 10,
                         group.map { $0[2] }.max() ?? 0])
            group = []
        }
        for back in (0...Int(hours / 24)).reversed() {
            let day = dayFormat.string(from: Date(timeIntervalSinceNow: -Double(back) * 86400))
            guard let text = try? String(contentsOf: logDir.appendingPathComponent(day + ".csv"), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").dropFirst() {
                let c = line.split(separator: ",").compactMap { Double($0) }
                guard c.count >= 13, c[0] >= since, c[11] >= 0 else { continue }
                if let f = group.first, Int(f[0] / step) != Int(c[0] / step) { flush() }
                group.append([c[0], c[11], c[12]])
            }
        }
        flush()
        return HistoryReply(rows: rows)
    }

    // MARK: install (root)

    static func install() {
        guard geteuid() == 0 else { fail("run with sudo: sudo vitals-agent battery install") }
        guard battery() != nil else { fail("This Mac has no battery.") }
        if NativeLimit.state()?.supported == true {
            fail("This Mac has macOS's own charge limit, which needs no daemon: vitals-agent battery limit 80 (or System Settings › Battery › Charging).")
        }
        guard let key = smcKey() else {
            fail("This Mac's firmware has no SMC charge switch Vitals knows (CHTE, CH0B/CH0C), so nothing was installed.")
        }
        let user = option("--user") ?? ProcessInfo.processInfo.environment["SUDO_USER"] ?? ""
        guard user != "root", !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
              let pw = getpwnam(user) else { fail("run with sudo from your own account") }
        let uid = pw.pointee.pw_uid, home = String(cString: pw.pointee.pw_dir)
        // The daemon runs only from the root-owned copy, never from a file you can change.
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let fm = FileManager.default
        try? fm.createDirectory(atPath: "/usr/local/libexec", withIntermediateDirectories: true)
        if me != rootPath {
            try? fm.removeItem(atPath: rootPath)
            do { try fm.copyItem(atPath: me, toPath: rootPath) } catch { fail("copy failed: \(error)") }
        }
        chown(rootPath, 0, 0); chmod(rootPath, 0o755)
        let config = home + "/Library/Application Support/Vitals/battery.json"
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [rootPath, "battery-daemon", "--uid", String(uid), "--config", config],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],      // restarted after a crash; a clean stop stays stopped
            "ExitTimeOut": 10,
            "ProcessType": "Background",
            "StandardErrorPath": logFile,
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        _ = run("/bin/launchctl", ["bootout", "system/\(label)"])
        do { try data.write(to: URL(fileURLWithPath: plist)) } catch { fail("could not write \(plist): \(error)") }
        chown(plist, 0, 0); chmod(plist, 0o644)
        guard run("/bin/launchctl", ["bootstrap", "system", plist]) == 0 else { fail("launchctl could not start \(label)") }
        print("Battery daemon installed (\(key.name)). It is off until you set a limit: vitals-agent battery limit 80")
        print("Turn it off: vitals-agent battery limit off. Remove it: sudo vitals-agent battery uninstall")
    }

    /// Also called by `remove-root`, which deletes the binary the daemon runs from.
    static func uninstall(quiet: Bool = false) {
        guard geteuid() == 0 else { fail("run with sudo: sudo vitals-agent battery uninstall") }
        let had = daemonInstalled
        _ = run("/bin/launchctl", ["bootout", "system/\(label)"])     // the daemon turns charging back on as it stops
        try? FileManager.default.removeItem(atPath: plist)
        // And once more from here, in case it was killed rather than stopped.
        if let s = smc, let key = smcKey() {
            let c = ChargeController(key: key, read: { s.bytes($0)?.data }, write: { s.write($0, $1) })
            let ok = c.allow()
            if !quiet || !ok { print(ok ? "Charging is on (\(key.name) set to allow)." : "Could not confirm charging is on. Restart the Mac to be sure.") }
        }
        try? FileManager.default.removeItem(atPath: statusFile)
        if !quiet || had { print("Battery daemon removed.") }
    }

    // MARK: CLI

    static func command() {
        let sub = Array(args.dropFirst())
        switch sub.first ?? "" {
        case "limit":
            guard sub.count == 2, sub[1] == "off" || Int(sub[1]) != nil else { fail("vitals-agent battery limit 80 | off") }
            let res = setLimit(sub[1] == "off" ? nil : Int(sub[1]))
            print(res.message)
            if !res.ok { exit(1) }
        case "keys": keys()
        case "install": install()
        case "uninstall": uninstall()
        case "", "status": status()
        default: print("vitals-agent battery [status] | limit N|off | keys | install | uninstall")
        }
    }

    private static func status() {
        guard let b = battery() else { print("This Mac has no battery."); return }
        let f = { (x: Double?, unit: String) in x.map { String(format: "%.1f %@", $0, unit) } ?? "—" }
        print("Battery \(Int(b.percent.rounded()))%, " + (b.charging ? "charging" : b.external ? (b.held == true ? "on power, held (not charging)" : "on power") : "on battery"))
        print("Health \(b.health.map { String(format: "%.1f%%", $0) } ?? "—") of design" + (b.fullMah.map { " (\($0) of \(b.designMah ?? 0) mAh)" } ?? "")
              + ", \(b.cycles.map(String.init) ?? "—") cycles" + (b.designCycles.map { " of \($0)" } ?? ""))
        print("Battery \(f(b.batteryWatts, "W")) (+ charging, - draining), from the wall \(f(b.inWatts, "W")), adapter \(f(b.adapterWatts, "W")), \(f(b.temp, "°C"))")
        if let m = b.minutesToFull { print("Full in \(m) min") }
        if let m = b.minutesToEmpty { print("Empty in \(m) min") }
        let n = native(), key = smcKey()
        if let n, n.supported {
            print("macOS charge limit: " + (n.enabled ? "\(n.limit ?? 100)%" : "off") + ", Optimized Charging: " + (n.optimized == true ? "on" : "off")
                  + (n.optimized == true && (n.holdingAt ?? 100) < 100 ? " (holding at \(n.holdingAt!)%)" : ""))
        }
        print("SMC charge switch: \(key?.name ?? "none on this firmware")")
        print("Way to set a limit here: " + ["macos": "macOS's own charge limit (no root)", "smc": "SMC through the battery daemon",
                                              "none": "none"][mechanism(n, key).rawValue]!)
        if daemonInstalled {
            let s = daemonStatus()
            print("Battery daemon: installed, limit \(config().map { "\($0)%" } ?? "off"), \(s?.state ?? "no status yet")" + (s?.message.map { ": \($0)" } ?? ""))
        }
    }

    /// Read only: every charging-related SMC key this Mac has, as `battery keys` and the test plan show them.
    private static func keys() {
        guard let s = smc else { fail("no SMC") }
        let hex = { (d: [UInt8]) in d.map { String(format: "%02x", $0) }.joined() }
        for k in ["CHTE", "CH0B", "CH0C", "CH0I", "CH0J", "CH0K", "CHIE", "ACLC", "BCLM", "bfD0", "bfE0", "bfF0"] {
            if let b = s.bytes(k) { print(k, b.type.trimmingCharacters(in: .whitespaces), b.data.count, hex(b.data)) }
            else { print(k, s.info(k.fourCC) != nil ? "exists, not readable" : "absent") }
        }
        print("Switch Vitals would use: \(smcKey()?.name ?? "none")")
    }

    // MARK: the daemon

    static func daemon() -> Never {
        let dry = args.contains("--dry-run")
        guard dry || geteuid() == 0 else { fail("the battery daemon runs as root under launchd (sudo vitals-agent battery install), or with --dry-run") }
        guard let uidText = option("--uid"), let uid = uid_t(uidText), let config = option("--config") else {
            fail("battery-daemon --uid UID --config PATH [--status PATH] [--dry-run [--fake-key CHTE|CH0B+CH0C]]")
        }
        let d = BatteryDaemon(uid: uid, config: config, status: option("--status") ?? statusFile, dry: dry, fake: option("--fake-key"))
        d.run()
    }
}

/// The root process that holds the SMC switch. One instance, driven from the main queue.
final class BatteryDaemon {
    let uid: uid_t, config: String, statusPath: String, dry: Bool
    let ctl: ChargeController
    private var asleep = false
    private var last: CareStatus?
    private var lastWrite = Date.distantPast
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var sources: [DispatchSourceSignal] = []
    fileprivate static var current: BatteryDaemon?
    private static var rootPort: io_connect_t = 0

    init(uid: uid_t, config: String, status: String, dry: Bool, fake: String?) {
        self.uid = uid; self.config = config; statusPath = status; self.dry = dry
        let smc = SMC()
        if dry {
            // A pretend SMC: the real one is only read, to find the switch; writes go to memory.
            var mem: [String: [UInt8]] = [:]
            let key = fake.flatMap { f in ChargeKey.known.first { $0.name == f } } ?? smc.flatMap { s in ChargeKey.detect { s.bytes($0)?.data } }
            for k in key?.keys ?? [] { mem[k] = key!.allow }
            ctl = ChargeController(key: key, read: { mem[$0] }, write: { k, v in
                guard mem[k] != nil else { return false }
                FileHandle.standardError.write(Data("dry run: would write \(k) = \(v.map { String(format: "%02x", $0) }.joined())\n".utf8))
                mem[k] = v; return true
            })
        } else {
            let key = smc.flatMap { s in ChargeKey.detect { s.bytes($0)?.data } }
            ctl = ChargeController(key: key, read: { smc?.bytes($0)?.data }, write: { smc?.write($0, $1) ?? false })
        }
    }

    func log(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(s)\n".utf8))
    }

    func run() -> Never {
        BatteryDaemon.current = self
        log("start: \(dry ? "dry run, " : "")switch \(ctl.key?.name ?? "none")")
        if let m = ctl.recover() { log(m) }
        // Charging comes back on however this process ends.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.stop("signal \(sig)") }
            src.resume()
            sources.append(src)
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { s in
                // Best effort from a crash; launchd restarts the daemon and recover() checks again.
                _ = BatteryDaemon.current?.ctl.allow()
                signal(s, SIG_DFL); raise(s)
            }
        }
        atexit { _ = BatteryDaemon.current?.ctl.allow() }
        watchSleep()
        timer.schedule(deadline: .now(), repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        dispatchMain()
    }

    func stop(_ why: String) -> Never {
        let ok = ctl.allow()
        log("stop (\(why)): charging \(ok ? "on" : "NOT confirmed on")")
        var s = last ?? CareStatus()
        s.t = Date().timeIntervalSince1970; s.state = "off"; s.inhibited = !ok
        s.message = ok ? "The battery daemon stopped; charging is on." : "The daemon stopped but charging could not be confirmed on. Restart the Mac."
        save(s)
        exit(0)
    }

    /// The limit from your file: a regular file you own, under 4 KB, holding {"limit": N}. Anything else is "off".
    func limit() -> Int? {
        let fd = open(config, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == uid, st.st_size < 4096 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(st.st_size))
        guard read(fd, &buf, buf.count) == buf.count,
              let c = try? JSONDecoder().decode(BatteryCare.Config.self, from: Data(buf)), let l = c.limit,
              ChargePolicy.smcRange.contains(l), l < 100 else { return nil }
        return l
    }

    func tick() {
        var s = ctl.step(limit: limit(), battery: BatteryCare.battery(), asleep: asleep)
        s.dryRun = dry
        let changed = s.state != last?.state || s.inhibited != last?.inhibited || s.message != last?.message || s.limit != last?.limit
        if changed { log("\(s.state)\(s.inhibited ? " (charging stopped)" : "") limit \(s.limit.map(String.init) ?? "off") at \(s.percent.map { String(format: "%.0f%%", $0) } ?? "?")" + (s.message.map { ": \($0)" } ?? "")) }
        if changed || Date().timeIntervalSince(lastWrite) >= 60 { save(s) }
        last = s
    }

    private func save(_ s: CareStatus) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        let tmp = statusPath + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: d, attributes: [.posixPermissions: 0o644]), rename(tmp, statusPath) == 0 {
            lastWrite = Date()
        }
    }

    /// Before sleep, charging goes back on: asleep, nothing watches the floor. It may charge past the
    /// limit overnight; on waking the daemon stops it again at the next look.
    private func watchSleep() {
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        BatteryDaemon.rootPort = IORegisterForSystemPower(nil, &port, { _, _, type, arg in
            let id = Int(bitPattern: arg)
            switch type {
            case 0xe000_0270:                                   // kIOMessageCanSystemSleep
                IOAllowPowerChange(BatteryDaemon.rootPort, id)
            case 0xe000_0280:                                   // kIOMessageSystemWillSleep
                BatteryDaemon.current?.sleeping(true)
                IOAllowPowerChange(BatteryDaemon.rootPort, id)
            case 0xe000_0300:                                   // kIOMessageSystemHasPoweredOn
                BatteryDaemon.current?.sleeping(false)
            default: break
            }
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, .main) } else { log("no sleep notifications; the limit still works while awake") }
    }

    private func sleeping(_ yes: Bool) { asleep = yes; tick() }
}

// MARK: macOS's own charge limit, through PowerUI (the framework behind System Settings › Battery)

enum NativeLimit {
    struct State: Codable, Equatable {
        var supported: Bool
        var enabled: Bool
        var limit: Int?            // when enabled
        var optimized: Bool?       // Optimized Battery Charging
        var holdingAt: Int?        // what macOS is charging to right now (Optimized Charging may hold at 80)
    }

    private typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
    private typealias QErrFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt64
    private typealias CErrFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias BErrFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
    private typealias SetFn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              cls.instancesRespond(to: NSSelectorFromString("initWithClientName:")) else { return nil }
        let blank = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        return blank?.perform(NSSelectorFromString("initWithClientName:"), with: "vitals")?.takeUnretainedValue() as? NSObject
    }()

    /// The method, only if this macOS still has it: a renamed private API means "not supported", never a crash.
    private static func fn<T>(_ name: String, _ type: T.Type) -> (NSObject, Selector, T)? {
        let sel = NSSelectorFromString(name)
        guard let c = client, c.responds(to: sel) else { return nil }
        return (c, sel, unsafeBitCast(c.method(for: sel), to: type))
    }

    /// Reads only.
    static func state() -> State? {
        guard let (c, sel, supported) = fn("isMCLSupported", BoolFn.self) else { return nil }
        var s = State(supported: supported(c, sel), enabled: false)
        guard s.supported else { return s }
        var e: NSError?
        if let (c, sel, f) = fn("isMCLCurrentlyEnabled:", QErrFn.self) { s.enabled = f(c, sel, &e) != 0 }
        if s.enabled, let (c, sel, f) = fn("getMCLLimitWithError:", CErrFn.self) { s.limit = Int(f(c, sel, &e)) }
        if let (c, sel, f) = fn("isSmartChargingCurrentlyEnabled:", QErrFn.self) { s.optimized = f(c, sel, &e) != 0 }
        if let (c, sel, f) = fn("currentChargeLimit:", QErrFn.self) { s.holdingAt = Int(f(c, sel, &e)) }
        return s
    }

    /// Sets macOS's own limit (80-99) or turns it off (nil), then reads it back. Returns an error for people, or nil.
    static func set(_ limit: Int?) -> String? {
        guard state()?.supported == true else { return "macOS's own charge limit isn't available on this Mac." }
        var e: NSError?
        if let l = limit {
            guard (80...99).contains(l) else { return "macOS's own charge limit takes 80 to 100%." }   // PowerUI misbehaves below 80
            guard let (c, s1, setLimit) = fn("setMCLLimit:error:", SetFn.self), let (_, s2, enable) = fn("enableMCL:", BErrFn.self) else {
                return "This macOS doesn't let Vitals set the charge limit; use System Settings › Battery › Charging."
            }
            guard setLimit(c, s1, UInt8(l), &e), enable(c, s2, &e) else {
                return "macOS refused the charge limit" + (e.map { ": \($0.localizedDescription)" } ?? ".")
            }
        } else {
            guard let (c, sel, disable) = fn("disableMCL:", BErrFn.self) else { return "This macOS doesn't let Vitals turn the limit off; use System Settings." }
            guard disable(c, sel, &e) else { return "macOS refused to turn the limit off" + (e.map { ": \($0.localizedDescription)" } ?? ".") }
        }
        // Read back: what macOS now says must be what was asked; otherwise put it back to off.
        let after = state()
        if after?.enabled == (limit != nil), limit == nil || after?.limit == limit { return nil }
        if limit != nil, let (c, sel, disable) = fn("disableMCL:", BErrFn.self) { _ = disable(c, sel, &e) }
        return "macOS did not keep the setting, so Vitals turned its charge limit back off."
    }
}
