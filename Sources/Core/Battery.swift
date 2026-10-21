import Foundation

// Battery care, the parts that have no side effects of their own:
//  - what AppleSmartBattery reports, read as any user (health, cycles, charge rate, times, adapter);
//  - the charge-limit policy and the SMC switch the root battery daemon drives (Agent/BatteryCare.swift).
// The controller never touches the SMC itself: it is handed read and write functions, so the same
// code runs against the real SMC as root, a dry run, and the tests.

extension Battery {
    /// nil when the Mac has no battery.
    init?(registry d: [String: Any]) {
        guard (d["BatteryInstalled"] as? Bool) ?? true, let current = (d["CurrentCapacity"] as? NSNumber)?.doubleValue else { return nil }
        let data = d["BatteryData"] as? [String: Any] ?? [:]          // newer firmware keeps the capacities in here
        func num(_ k: String) -> Int64? { ((d[k] ?? data[k]) as? NSNumber)?.int64Value }
        func minutes(_ k: String) -> Int? { num(k).flatMap { $0 > 0 && $0 < 6000 ? Int($0) : nil } }   // 65535: unknown
        // Apple silicon reports percent (MaxCapacity 100); older Macs reported mAh.
        let max = num("MaxCapacity").map(Double.init) ?? 100
        self.init(percent: max > 100 ? current / max * 100 : current, charging: d["IsCharging"] as? Bool ?? false,
                  external: d["ExternalConnected"] as? Bool ?? false)
        let adapter = d["AdapterDetails"] as? [String: Any]
        adapterWatts = (adapter?["Watts"] as? NSNumber)?.doubleValue
            ?? { guard let v = (adapter?["AdapterVoltage"] as? NSNumber)?.doubleValue, let a = (adapter?["Current"] as? NSNumber)?.doubleValue,
                       v > 0, a > 0 else { return nil }; return (v * a / 1e6).rounded() }()
        if external, let mw = ((d["PowerTelemetryData"] as? [String: Any])?["SystemPowerIn"] as? NSNumber)?.doubleValue { inWatts = mw / 1000 }
        if let mv = num("Voltage") ?? num("AppleRawBatteryVoltage"), let ma = num("InstantAmperage") ?? num("Amperage") {
            batteryWatts = Double(mv) * Double(Int32(truncatingIfNeeded: ma)) / 1e6
        }
        cycles = num("CycleCount").map(Int.init)
        designCycles = num("DesignCycleCount9C").map(Int.init)
        // Health: what a full charge holds now against what it held new. AppleRawMaxCapacity is mAh where present.
        let full = num("AppleRawMaxCapacity").flatMap { $0 > 100 ? $0 : nil } ?? num("NominalChargeCapacity") ?? num("FullChargeCapacity")
        if let full, let design = num("DesignCapacity"), design > 0 {
            designMah = Int(design); fullMah = Int(full)
            health = Double(full) / Double(design) * 100
        }
        minutesLeft = minutes("TimeRemaining")
        if charging { minutesToFull = minutes("AvgTimeToFull") ?? minutesLeft }
        if !external { minutesToEmpty = minutes("AvgTimeToEmpty") ?? minutesLeft }
        if let t = num("Temperature") ?? num("VirtualTemperature"), t > 0 { temp = Double(t) / 100 }
        held = external && !charging && !((d["FullyCharged"] as? Bool) ?? false) && percent < 99.5
    }
}

// MARK: charge limit

enum ChargePolicy {
    /// Never hold the charge below this, whatever the limit says.
    static let floor = 20.0
    /// Limits the SMC path accepts; 100 means off. macOS's own limit takes 80-100.
    static let smcRange = 50...100
    static let nativeRange = 80...100
    /// Once held at the limit, charging resumes only this far below it, so it doesn't start and stop every minute.
    static let resume = 5.0

    /// Whether charging should be stopped now. Only ever on power and above the floor.
    static func inhibit(limit: Int?, percent: Double, external: Bool, inhibitedNow: Bool) -> Bool {
        guard let limit, smcRange.contains(limit), limit < 100, external, percent >= floor else { return false }
        return percent >= Double(limit) || (inhibitedNow && percent > Double(limit) - resume)
    }
}

/// One way the SMC lets root stop charging. Which keys exist depends on the Mac's firmware, not on
/// the macOS version, so they are probed, never assumed (sources in README, Battery care).
struct ChargeKey: Equatable {
    var name: String
    var keys: [String]          // written together, in this order
    var size: Int
    var inhibit: [UInt8]
    var allow: [UInt8]

    static let known = [
        // Firmware from macOS 15.7.1 and 26.0 (actuallymentor/battery PR #388). Gone again on firmware 20457.0.125+.
        ChargeKey(name: "CHTE", keys: ["CHTE"], size: 4, inhibit: [1, 0, 0, 0], allow: [0, 0, 0, 0]),
        // Earlier Apple-silicon firmware (AlDente's open-source helper, `battery` before 2025).
        ChargeKey(name: "CH0B+CH0C", keys: ["CH0B", "CH0C"], size: 1, inhibit: [2], allow: [0]),
    ]

    /// The first known switch whose every key exists with the expected size.
    static func detect(read: (String) -> [UInt8]?) -> ChargeKey? {
        known.first { k in k.keys.allSatisfy { read($0)?.count == k.size } }
    }
}

/// What the daemon is doing, for the page and `vitals-agent battery`. Written by the daemon as JSON.
struct CareStatus: Codable, Equatable {
    var v = vitalsVersion
    var t: Double = 0
    var key: String?            // the SMC switch in use, nil when this Mac has none
    var limit: Int?             // nil: off
    var state = "off"           // off, charging, holding, unplugged, low, sleeping, unsupported, failed, conflict
    var message: String?
    var inhibited = false       // charging is stopped right now
    var percent: Double?
    var dryRun = false
}

/// Holds the charge at the limit through one SMC switch, with the safety rules:
///  - charging is allowed whenever there is any doubt: off, unplugged, below the floor, asleep, exiting;
///  - every write is read back; a value that does not stick re-enables charging and stops trying;
///  - if the battery keeps charging two minutes after the switch says stop, the switch does not work
///    on this Mac: charging is re-enabled and it stops trying;
///  - a value it did not write (another battery app) is left alone rather than fought over.
/// After it gives up it tries again only when the limit is changed.
final class ChargeController {
    let key: ChargeKey?
    private let read: (String) -> [UInt8]?
    private let write: (String, [UInt8]) -> Bool
    private(set) var inhibited = false
    private(set) var gaveUp: (state: String, why: String)?
    private var started = false
    private var lastLimit: Int?
    private var inhibitedAt: Date?
    private var resets: [Date] = []
    var clock: () -> Date = Date.init

    /// Grace for the charger to react before "still charging" counts against the switch.
    static let verifyAfter = 120.0
    /// Current into the battery (W) that counts as charging.
    static let chargingWatts = 1.0

    init(key: ChargeKey?, read: @escaping (String) -> [UInt8]?, write: @escaping (String, [UInt8]) -> Bool) {
        self.key = key; self.read = read; self.write = write
    }

    private func values() -> [[UInt8]?] { key?.keys.map(read) ?? [] }
    private func all(_ v: [UInt8]) -> Bool { let x = values(); return !x.isEmpty && x.allSatisfy { $0 == v } }

    /// At start, before anything else: a switch left at "stop" (this daemon crashed, or was killed) is
    /// turned back to "allow". Anything other than our own two values is someone else's: hands off.
    func recover() -> String? {
        guard let key else { return nil }
        if all(key.allow) { return nil }
        if all(key.inhibit) {
            return allow() ? "Charging had been left off; turned it back on." : "Charging is off and the SMC would not turn it back on. Restart the Mac."
        }
        gaveUp = ("conflict", "\(key.name) holds a value Vitals never writes; another battery app may be in control. Vitals leaves it alone.")
        return gaveUp?.why
    }

    /// Writes "allow" and checks it stuck. Always safe to call.
    @discardableResult func allow() -> Bool {
        guard let key else { return true }
        for k in key.keys { _ = write(k, key.allow) }
        let ok = all(key.allow)
        inhibited = !ok
        inhibitedAt = nil
        return ok
    }

    private func stop() -> Bool {
        guard let key else { return false }
        var ok = true
        for k in key.keys { ok = write(k, key.inhibit) && ok }
        guard ok, all(key.inhibit) else {
            allow()
            gaveUp = ("failed", "The SMC did not accept \(key.name) on this Mac (written, but it read back differently). Charging is on; Vitals stopped trying.")
            return false
        }
        inhibited = true
        inhibitedAt = clock()
        return true
    }

    /// One look: decides, writes if needed, and says what it is doing.
    func step(limit: Int?, battery b: Battery?, asleep: Bool = false) -> CareStatus {
        var s = decide(limit: limit, battery: b, asleep: asleep)
        s.inhibited = inhibited
        return s
    }

    private func decide(limit: Int?, battery b: Battery?, asleep: Bool) -> CareStatus {
        var s = CareStatus(t: clock().timeIntervalSince1970, key: key?.name, limit: limit, percent: b?.percent)
        // A new limit from the user is a fresh try, also after giving up.
        if !started { started = true; lastLimit = limit } else if lastLimit != limit { lastLimit = limit; gaveUp = nil; resets = [] }
        guard let key else {
            s.state = limit == nil ? "off" : "unsupported"
            s.message = "This Mac's firmware has no charge switch Vitals knows (CHTE, CH0B/CH0C)."
            return s
        }
        if let g = gaveUp {
            if g.state != "conflict", inhibited || all(key.inhibit) { allow() }
            s.state = g.state; s.message = g.why
            return s
        }
        // Someone else moved the switch since the last look.
        if inhibited, all(key.allow) {
            inhibited = false; inhibitedAt = nil
            resets = resets.filter { clock().timeIntervalSince($0) < 600 } + [clock()]
            if resets.count > 5 {
                gaveUp = ("failed", "macOS keeps turning charging back on over \(key.name). Vitals stopped trying.")
                s.state = "failed"; s.message = gaveUp?.why
                return s
            }
        } else if !inhibited, all(key.inhibit) {
            gaveUp = ("conflict", "Another app stopped charging through \(key.name). Vitals leaves it alone; quit the other app, then set the limit again.")
            s.state = "conflict"; s.message = gaveUp?.why
            return s
        }
        guard let b else { if inhibited { allow() }; s.state = "failed"; s.message = "Can't read the battery."; return s }
        let want = !asleep && ChargePolicy.inhibit(limit: limit, percent: b.percent, external: b.external, inhibitedNow: inhibited)
        if want != inhibited {
            if want { if !stop() { s.state = "failed"; s.message = gaveUp?.why; return s } }
            else if !allow() { s.state = "failed"; s.message = "Charging should be on, but \(key.name) would not switch back. Restart the Mac."; return s }
        }
        // The switch says stop: two minutes on, the battery must not still be taking charge.
        if inhibited, let at = inhibitedAt, clock().timeIntervalSince(at) > Self.verifyAfter, b.external,
           (b.batteryWatts ?? 0) > Self.chargingWatts {
            allow()
            gaveUp = ("failed", "\(key.name) was set but the battery kept charging, so it doesn't work on this Mac. Charging is on; Vitals stopped trying.")
            s.state = "failed"; s.message = gaveUp?.why
            return s
        }
        if limit == nil { s.state = "off" }
        else if asleep { s.state = "sleeping"; s.message = "Asleep: charging is allowed until the Mac wakes." }
        else if !b.external { s.state = "unplugged" }
        else if b.percent < ChargePolicy.floor { s.state = "low"; s.message = "Below \(Int(ChargePolicy.floor))%: always charges." }
        else { s.state = inhibited ? "holding" : "charging" }
        return s
    }
}
