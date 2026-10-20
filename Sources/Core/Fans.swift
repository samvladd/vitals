import Foundation

// Fan control through the SMC. Needs root. The agent hands the fans back to macOS whenever it
// exits, so a dropped connection or a crash never leaves a fan pinned at a low speed.

final class FanControl {
    enum Policy: Equatable {
        case auto
        case fixed(Double)                 // rpm
        case curve(low: Double, high: Double)   // °C at which the fan is at its minimum and its maximum

        var text: String {
            switch self {
            case .auto: return "auto"
            case .fixed(let r): return "fixed \(Int(r))"
            case .curve(let l, let h): return "curve \(Int(l)) \(Int(h))"
            }
        }

        init?(_ words: [String]) {
            switch words.first {
            case "auto": self = .auto
            case "fixed" where words.count > 1: guard let r = Double(words[1]) else { return nil }; self = .fixed(r)
            case "curve" where words.count > 2:
                guard let l = Double(words[1]), let h = Double(words[2]), h > l else { return nil }
                self = .curve(low: l, high: h)
            default: return nil
            }
        }
    }

    /// Above this the fans go to full speed whatever the policy says.
    static let safetyCeiling = 95.0

    private let smc: SMC
    private(set) var policy: Policy = .auto
    private var lastTargets: [Int: Double] = [:]
    private var lastWrite = Date.distantPast

    init(smc: SMC) { self.smc = smc }

    private var count: Int { Int(smc.value("FNum") ?? 0) }
    private func modeKey(_ i: Int) -> String { smc.value("F\(i)Md") != nil ? "F\(i)Md" : "F\(i)md" }

    func set(_ p: Policy) {
        policy = p
        lastTargets = [:]
        if p == .auto { release() }
    }

    /// Called on every sample with the hottest CPU reading.
    func apply(cpuTemp: Double?) {
        guard policy != .auto else { return }
        let refresh = Date().timeIntervalSince(lastWrite) > 20
        for i in 0..<count {
            let lo = smc.value("F\(i)Mn") ?? 1000, hi = smc.value("F\(i)Mx") ?? 5000
            var target: Double
            switch policy {
            case .auto: return
            case .fixed(let r): target = r
            case .curve(let l, let h):
                let x = min(1, max(0, ((cpuTemp ?? h) - l) / (h - l)))
                target = lo + x * (hi - lo)
            }
            if let t = cpuTemp, t >= Self.safetyCeiling { target = hi }
            target = min(hi, max(lo, target.rounded()))
            if refresh || abs((lastTargets[i] ?? -1000) - target) >= 50 {
                if write(fan: i, rpm: target) { lastTargets[i] = target; lastWrite = Date() }
            }
        }
    }

    private func write(fan i: Int, rpm: Double) -> Bool {
        if smc.value(modeKey(i)) != 1, !unlock(i) { return false }
        return smc.write("F\(i)Tg", float: Float(rpm))
    }

    private func unlock(_ i: Int) -> Bool {
        if smc.write(modeKey(i), [1]) { return true }          // M5 and later
        guard smc.value("Ftst") != nil else { return false }   // M1-M4: ask thermalmonitord to yield
        _ = smc.write("Ftst", [1])
        for _ in 0..<60 {
            usleep(250_000)
            if smc.write(modeKey(i), [1]) { return true }
        }
        return false
    }

    /// Hands every fan back to macOS.
    func release() {
        for i in 0..<count {
            _ = smc.write(modeKey(i), [0])
            _ = smc.write("F\(i)Tg", float: 0)
        }
        if let t = smc.value("Ftst"), t != 0 { _ = smc.write("Ftst", [0]) }
    }
}
