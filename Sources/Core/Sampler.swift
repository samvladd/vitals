import Foundation
import IOKit
import Darwin

func sysctlInt(_ name: String) -> Int? {
    var v: Int64 = 0, size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

/// One property from every instance of a class; far cheaper than copying whole property tables.
private func registryProperty(_ cls: String, _ key: String) -> [Any] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == kIOReturnSuccess else { return [] }
    defer { IOObjectRelease(it) }
    var out: [Any] = []
    while case let e = IOIteratorNext(it), e != 0 {
        if let v = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { out.append(v) }
        IOObjectRelease(e)
    }
    return out
}

private func registryProperties(_ cls: String) -> [[String: Any]] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == kIOReturnSuccess else { return [] }
    defer { IOObjectRelease(it) }
    var out: [[String: Any]] = []
    while case let e = IOIteratorNext(it), e != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
           let d = props?.takeRetainedValue() as? [String: Any] { out.append(d) }
        IOObjectRelease(e)
    }
    return out
}

final class Sampler {
    let smc = SMC()
    private let energy = EnergyReport()
    var withProcs: Bool
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var ssdKey: String?
    private var hotKeys: [String] = []      // the hottest CPU sensors at the last full scan
    private var ticks = 0
    private var volumeCache: (Date, [Volume]) = (.distantPast, [])
    private lazy var hasBattery = !registryProperty("AppleSmartBattery", "CurrentCapacity").isEmpty
    private let eCores = (sysctlString("hw.perflevel1.name") == "Efficiency") ? (sysctlInt("hw.perflevel1.logicalcpu") ?? 0) : 0

    private var prevTicks: [[UInt32]] = []
    private var prevNet: (Double, Double, Double)?     // in, out, time
    private var prevDisk: (Double, Double, Double)?
    private var prevProcs: [pid_t: UInt64] = [:]
    private var prevProcTime: UInt64 = 0
    private let timebase: (UInt32, UInt32) = { var t = mach_timebase_info(); mach_timebase_info(&t); return (t.numer, t.denom) }()

    init(procs: Bool) {
        withProcs = procs
        guard let smc else { return }
        // Group the temperature sensors once by family; chips name them differently.
        for k in smc.allKeys() where k.hasPrefix("T") {
            guard let (type, _) = smc.bytes(k), type == "flt ", let v = smc.value(k), v > 10, v < 130 else { continue }
            let fam = String(k.prefix(2))
            if ["Tp", "Te", "Tm"].contains(fam) { cpuKeys.append(k) }
            else if fam == "Tg" { gpuKeys.append(k) }
        }
        ssdKey = smc.value("TH0x") != nil ? "TH0x" : nil
    }

    func sample() -> Snapshot {
        var s = Snapshot()
        s.t = Date().timeIntervalSince1970
        s.root = geteuid() == 0
        sampleCPU(&s)
        sampleMemory(&s)
        sampleSensors(&s)
        if let e = energy?.sample() { s.wCPU = e.cpu; s.wGPU = e.gpu; s.wANE = e.ane; s.wDRAM = e.dram }
        s.gpu = registryProperty("IOAccelerator", "PerformanceStatistics").lazy
            .compactMap { ($0 as? [String: Any])?["Device Utilization %"] as? NSNumber }
            .first.map { $0.doubleValue }
        if hasBattery { s.battery = battery() }
        if s.wSystem == nil, let b = s.battery, let w = b.inWatts { s.wSystem = w }
        sampleIO(&s)
        if withProcs { s.procs = topProcs() } else { prevProcTime = 0 }
        s.volumes = volumes()
        var boot = timeval(), size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 { s.uptime = s.t - Double(boot.tv_sec) }
        s.thermal = ProcessInfo.processInfo.thermalState.rawValue
        return s
    }

    private func sampleCPU(_ s: inout Snapshot) {
        var count: natural_t = 0, info: processor_info_array_t?, infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let ticks: [[UInt32]] = (0..<Int(count)).map { c in
            (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[c * Int(CPU_STATE_MAX) + $0]) }
        }
        defer { prevTicks = ticks }
        s.eCores = eCores
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        s.load = load
        guard prevTicks.count == ticks.count else { return }
        var busyAll = 0.0, totalAll = 0.0
        s.cores = zip(ticks, prevTicks).map { now, was in
            let d = (0..<Int(CPU_STATE_MAX)).map { Double(now[$0] &- was[$0]) }
            let busy = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            let total = busy + d[Int(CPU_STATE_IDLE)]
            busyAll += busy; totalAll += total
            return total > 0 ? busy / total * 100 : 0
        }
        s.cpu = totalAll > 0 ? busyAll / totalAll * 100 : 0
    }

    private func sampleMemory(_ s: inout Snapshot) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        s.memTotal = Double(sysctlInt("hw.memsize") ?? 0)
        if r == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            s.memApp = Double(Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page
            s.memWired = Double(vm.wire_count) * page
            s.memCompressed = Double(vm.compressor_page_count) * page
            s.memCached = Double(vm.external_page_count + vm.purgeable_count) * page
            s.memUsed = s.memApp + s.memWired + s.memCompressed
        }
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = Double(swap.xsu_used); s.swapTotal = Double(swap.xsu_total)
        }
        s.pressure = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
    }

    private func sampleSensors(_ s: inout Snapshot) {
        guard let smc else { return }
        // Reading every sensor costs ~0.2 ms each; scan them all every 30th sample and in between
        // follow only the dozen that were hottest.
        if ticks % 30 == 0 || hotKeys.isEmpty {
            let all = cpuKeys.compactMap { k in smc.value(k).map { (k, $0) } }.filter { $0.1 > 1 }
            hotKeys = all.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
            if !all.isEmpty { s.tCPUAvg = all.map(\.1).reduce(0, +) / Double(all.count) }
        }
        ticks += 1
        let cpu = hotKeys.compactMap { smc.value($0) }.filter { $0 > 1 }
        if !cpu.isEmpty { s.tCPU = cpu.max() }
        let gpu = stride(from: 0, to: gpuKeys.count, by: max(1, gpuKeys.count / 8)).compactMap { smc.value(gpuKeys[$0]) }.filter { $0 > 1 }
        if !gpu.isEmpty { s.tGPU = gpu.reduce(0, +) / Double(gpu.count) }
        if let k = ssdKey { s.tSSD = smc.value(k) }
        if let w = smc.value("PSTR"), w > 0 { s.wSystem = w }
        let n = Int(smc.value("FNum") ?? 0)
        s.fans = (0..<n).compactMap { i in
            guard let rpm = smc.value("F\(i)Ac") else { return nil }
            let mode = smc.value("F\(i)Md") ?? smc.value("F\(i)md") ?? 0
            return Fan(rpm: rpm, min: smc.value("F\(i)Mn") ?? 0, max: smc.value("F\(i)Mx") ?? 0,
                       target: smc.value("F\(i)Tg") ?? 0, manual: mode == 1)
        }
    }

    private func battery() -> Battery? {
        guard let d = registryProperties("AppleSmartBattery").first, (d["BatteryInstalled"] as? Bool) ?? true,
              let pct = d["CurrentCapacity"] as? NSNumber else { return nil }
        let num = { (k: String) in (d[k] as? NSNumber)?.int64Value }
        let tel = d["PowerTelemetryData"] as? [String: Any]
        var b = Battery(percent: pct.doubleValue, charging: d["IsCharging"] as? Bool ?? false,
                        external: d["ExternalConnected"] as? Bool ?? false)
        b.adapterWatts = ((d["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber)?.doubleValue
        if let mw = (tel?["SystemPowerIn"] as? NSNumber)?.doubleValue { b.inWatts = mw / 1000 }
        if let mv = num("Voltage"), let ma = num("InstantAmperage") ?? num("Amperage") {
            b.batteryWatts = Double(mv) * Double(Int32(truncatingIfNeeded: ma)) / 1e6
        }
        b.cycles = num("CycleCount").map(Int.init)
        if let raw = num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity"), let design = num("DesignCapacity"), design > 0 {
            b.health = Double(raw) / Double(design) * 100
        }
        if let m = num("TimeRemaining"), m > 0, m < 6000 { b.minutesLeft = Int(m) }
        if let t = num("Temperature") { b.temp = Double(t) / 100 }
        return b
    }

    private func sampleIO(_ s: inout Snapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        // Network: physical interfaces only, so a VPN tunnel is not counted twice.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        if sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 {
            var buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, 6, &buf, &len, nil, 0) == 0 {
                var rx = 0.0, tx = 0.0, off = 0
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                buf.withUnsafeBytes { raw in
                    while off + MemoryLayout<if_msghdr>.size <= len {
                        let h = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                        if Int32(h.ifm_type) == RTM_IFINFO2 {
                            let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                            if if_indextoname(UInt32(m.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                                rx += Double(m.ifm_data.ifi_ibytes); tx += Double(m.ifm_data.ifi_obytes)
                            }
                        }
                        off += max(Int(h.ifm_msglen), 1)
                    }
                }
                if let p = prevNet, now > p.2 { s.netIn = max(0, rx - p.0) / (now - p.2); s.netOut = max(0, tx - p.1) / (now - p.2) }
                prevNet = (rx, tx, now)
            }
        }
        var rd = 0.0, wr = 0.0
        for d in registryProperty("IOBlockStorageDriver", "Statistics") {
            guard let st = d as? [String: Any] else { continue }
            rd += (st["Bytes (Read)"] as? NSNumber)?.doubleValue ?? 0
            wr += (st["Bytes (Write)"] as? NSNumber)?.doubleValue ?? 0
        }
        if let p = prevDisk, now > p.2 { s.diskRead = max(0, rd - p.0) / (now - p.2); s.diskWrite = max(0, wr - p.1) / (now - p.2) }
        prevDisk = (rd, wr, now)
    }

    /// The boot volume and any other local drives. Free space counts purgeable files, as Finder does;
    /// working that out is slow, so it is refreshed once a minute.
    private func volumes() -> [Volume] {
        if Date().timeIntervalSince(volumeCache.0) < 60 { return volumeCache.1 }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let vols: [Volume] = urls.compactMap { u in
            guard let r = try? u.resourceValues(forKeys: Set(keys)), r.volumeIsLocal == true, r.volumeIsBrowsable != false,
                  let total = r.volumeTotalCapacity, total > 1_000_000_000 else { return nil }
            let boot = r.volumeIsRootFileSystem == true
            let free = r.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? Double(r.volumeAvailableCapacity ?? 0)
            return Volume(name: r.volumeLocalizedName ?? u.lastPathComponent, total: Double(total), free: free, boot: boot)
        }.sorted { $0.boot && !$1.boot }
        volumeCache = (Date(), vols)
        return vols
    }

    /// The processes using the most CPU since the last sample, then the largest by memory, helpers grouped under one name.
    private func topProcs() -> [Proc] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let nowTicks = mach_absolute_time()
        let elapsedNs = Double(nowTicks - prevProcTime) * Double(timebase.0) / Double(timebase.1)
        var next: [pid_t: UInt64] = [:]
        var byName: [String: (cpu: Double, mem: Double)] = [:]
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(got) where pid > 0 {
            var ti = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { continue }
            let total = ti.pti_total_user + ti.pti_total_system
            next[pid] = total
            guard prevProcTime > 0, let was = prevProcs[pid], total >= was else { continue }
            let cpu = Double(total - was) * Double(timebase.0) / Double(timebase.1) / elapsedNs * 100
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            var name = String(cString: nameBuf)
            if name.isEmpty { continue }
            if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }
            byName[name, default: (0, 0)].cpu += cpu
            byName[name, default: (0, 0)].mem += Double(ti.pti_resident_size)
        }
        prevProcs = next; prevProcTime = nowTicks
        // The busiest eight, plus the largest by memory so the phone's memory view can name them.
        let byCPU = byName.sorted { $0.value.cpu > $1.value.cpu }.prefix(8)
        let byMem = byName.sorted { $0.value.mem > $1.value.mem }.prefix(6).filter { m in !byCPU.contains { $0.key == m.key } }
        return (byCPU + byMem).map { Proc(name: $0.key, cpu: $0.value.cpu, mem: $0.value.mem) }
    }
}

func machineInfo() -> MachineInfo {
    let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
    defer { IOObjectRelease(product) }
    let model = (IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data)
        .flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
        ?? sysctlString("hw.model") ?? "Mac"
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return MachineInfo(name: Host.current().localizedName ?? sysctlString("kern.hostname") ?? "Mac",
                       model: model, chip: sysctlString("machdep.cpu.brand_string") ?? "",
                       cores: sysctlInt("hw.ncpu") ?? 0, eCores: (sysctlString("hw.perflevel1.name") == "Efficiency") ? (sysctlInt("hw.perflevel1.logicalcpu") ?? 0) : 0,
                       memory: Double(sysctlInt("hw.memsize") ?? 0),
                       os: "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""))
}
