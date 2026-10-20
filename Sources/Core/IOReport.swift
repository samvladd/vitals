import Foundation

// Energy counters for CPU, GPU, Neural Engine and memory from the private IOReport library.
// Readable by any user; the counters are energy, so watts = delta / seconds.

final class EnergyReport {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetInt = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let getInt: GetInt
    private let getName: GetString
    private let getUnit: GetString
    private let sub: OpaquePointer
    private let channels: CFMutableDictionary
    private var last: (CFDictionary, Double)?

    init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func sym<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannels.self),
              let mk = sym("IOReportCreateSubscription", CreateSub.self),
              let cs = sym("IOReportCreateSamples", CreateSamples.self),
              let cd = sym("IOReportCreateSamplesDelta", CreateDelta.self),
              let gi = sym("IOReportSimpleGetIntegerValue", GetInt.self),
              let gn = sym("IOReportChannelGetChannelName", GetString.self),
              let gu = sym("IOReportChannelGetUnitLabel", GetString.self),
              let ch = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let s = mk(nil, ch, &subbed, 0, nil), let subscribed = subbed?.takeRetainedValue() else { return nil }
        createSamples = cs; createDelta = cd; getInt = gi; getName = gn; getUnit = gu
        sub = s; channels = subscribed
    }

    /// Mean watts per component since the previous call (nil on the first).
    func sample() -> (cpu: Double?, gpu: Double?, ane: Double?, dram: Double?)? {
        guard let now = createSamples(sub, channels, nil)?.takeRetainedValue() else { return nil }
        let t = ProcessInfo.processInfo.systemUptime
        defer { last = (now, t) }
        guard let (prev, pt) = last, t - pt > 0.05,
              let delta = createDelta(prev, now, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        let secs = t - pt
        var r = (cpu: 0.0, gpu: 0.0, ane: 0.0, dram: 0.0)
        var seen = (cpu: false, gpu: false, ane: false, dram: false)
        for item in items {
            guard let name = getName(item)?.takeUnretainedValue() as String? else { continue }
            let unit = (getUnit(item)?.takeUnretainedValue() as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
            let scale: Double = unit == "mJ" ? 1e-3 : unit == "uJ" ? 1e-6 : unit == "nJ" ? 1e-9 : 0
            let w = Double(getInt(item, 0)) * scale / secs
            let live = w > 0
            if name == "GPU Energy" { r.gpu += w; seen.gpu = seen.gpu || live }
            else if name.hasSuffix("CPU Energy") { r.cpu += w; seen.cpu = seen.cpu || live }
            else if name.hasPrefix("ANE") { r.ane += w; seen.ane = true }
            else if name.hasPrefix("DRAM") { r.dram += w; seen.dram = seen.dram || live }
        }
        // A counter that never moves is one this chip does not fill in (CPU on M5): unknown, not 0 W.
        return (seen.cpu ? r.cpu : nil, seen.gpu ? r.gpu : nil, seen.ane ? r.ane : nil, seen.dram ? r.dram : nil)
    }

    func channelNames() -> [String] {
        guard let s = createSamples(sub, channels, nil)?.takeRetainedValue(),
              let items = (s as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return [] }
        return items.compactMap { item in
            (getName(item)?.takeUnretainedValue() as String?).map { "\($0) [\((getUnit(item)?.takeUnretainedValue() as String?) ?? "")]" }
        }
    }
}
