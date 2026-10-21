import Foundation
import IOKit

// Storage detail for the dashboard: the SSD's own health report, and what is using the space.
// Both run only when a page asks for them; nothing here runs in the background.

// MARK: SSD health

struct SSDHealth: Codable {
    var model: String
    var warning: Int              // NVMe critical-warning bits; 0 is healthy
    var percentUsed: Double       // the drive's own estimate of its rated life used
    var spare: Double             // % of spare blocks left
    var spareThreshold: Double
    var written: Double           // bytes
    var read: Double
    var hours: Double             // powered on
    var cycles: Double
    var unsafeShutdowns: Double
    var mediaErrors: Double
    var temp: Double?             // °C
}

/// IONVMeSMARTInterface from IOKit/storage/nvme/NVMeSMARTLibExternal.h, which Swift does not import.
private struct SMARTVTable {
    var reserved: UnsafeMutableRawPointer?
    var QueryInterface: @convention(c) (UnsafeMutableRawPointer?, REFIID, UnsafeMutablePointer<LPVOID?>?) -> HRESULT
    var AddRef: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
    var Release: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
    var version: UInt16
    var revision: UInt16
    var SMARTReadData: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
}

private func uuid(_ b: [UInt8]) -> CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
}

/// The internal SSD's NVMe SMART log, as `smartctl` reads it. Needs no root.
func ssdHealth() -> SSDHealth? {
    let userClient = uuid([0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F])
    let smartInterface = uuid([0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6])
    let plugInInterface = uuid([0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F])

    let match = IOServiceMatching("IOService") as NSMutableDictionary
    match["IOPropertyMatch"] = ["NVMe SMART Capable": true]
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    let model = (IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "Model Number" as CFString, kCFAllocatorDefault,
                                                 IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String)?
        .trimmingCharacters(in: .whitespaces) ?? "SSD"

    var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    guard IOCreatePlugInInterfaceForService(svc, userClient, plugInInterface, &plugin, &score) == KERN_SUCCESS,
          let plugin, let p = plugin.pointee else { return nil }
    defer { _ = p.pointee.Release(plugin) }
    var iface: LPVOID?
    guard p.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &iface) == S_OK, let iface else { return nil }
    let smart = iface.assumingMemoryBound(to: UnsafeMutablePointer<SMARTVTable>.self).pointee
    defer { _ = smart.pointee.Release(iface) }
    var b = [UInt8](repeating: 0, count: 512)
    guard b.withUnsafeMutableBytes({ smart.pointee.SMARTReadData(iface, $0.baseAddress) }) == kIOReturnSuccess else { return nil }

    // NVMe 1.x SMART / Health log layout; counters are little-endian, data units are 512,000 bytes.
    func u64(_ o: Int) -> Double { Double((0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }) }
    let kelvin = Int(b[1]) | Int(b[2]) << 8
    return SSDHealth(model: model, warning: Int(b[0]), percentUsed: Double(b[5]), spare: Double(b[3]), spareThreshold: Double(b[4]),
                     written: u64(48) * 512_000, read: u64(32) * 512_000, hours: u64(128), cycles: u64(112),
                     unsafeShutdowns: u64(144), mediaErrors: u64(160), temp: kelvin > 0 ? Double(kelvin - 273) : nil)
}

// MARK: what is using the space

struct SpaceItem: Codable {
    var name: String
    var bytes: Double
    var children: [SpaceItem]? = nil
}

struct SpaceReport: Codable {
    var t: Double                 // when the measuring started
    var seconds: Double
    var running: Bool
    var partial: Bool             // ran out of time; sizes are "at least"
    var total: Double
    var free: Double
    var purgeable: Double         // space macOS can free by itself (caches, local snapshots)
    var snapshots: Int            // Time Machine local snapshots
    var fullDiskAccess = false
    var items: [SpaceItem]
    var leftAlone: [String] = []  // home-relative folders never opened
}

/// Measures, on demand, the folders that are yours and your apps': everything in your home folder
/// except the places macOS guards with a permission prompt, plus /Applications. It never opens
/// Desktop, Documents, Downloads, your media libraries, the Trash, other apps' sandboxed data, cloud
/// folders, or Apple's own data in Library: on a Mac nobody is sitting at, a prompt would never be
/// answered. A watchdog backs that up: a folder that stalls is abandoned and never opened again.
final class SpaceScanner {
    static let shared = SpaceScanner()
    static let deadline = 45.0
    static let freshFor = 3600.0
    static let stall = 6.0

    private let lock = NSLock()
    private var report: SpaceReport?
    private let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Vitals")
    private var cacheFile: URL { dir.appendingPathComponent("space.json") }
    private var blockedFile: URL { dir.appendingPathComponent("space-blocked.txt") }

    /// Home folders macOS guards with a permission prompt (or that hold cloud placeholders).
    static let guardedHome: Set<String> = ["Desktop", "Documents", "Downloads", "Music", "Movies", "Pictures", "Public", ".Trash", "Library"]
    static let cloud: Set<String> = ["Library/Mobile Documents", "Library/CloudStorage"]
    /// Library folders that hold your apps' data; Apple's own (and other apps' sandboxes) are left out.
    static func appleOwned(_ name: String) -> Bool {
        name.hasPrefix("com.apple") || name.hasPrefix("Apple") || appleNames.contains(name)
    }
    static let appleNames: Set<String> = [
        "Accounts", "Assistant", "Assistants", "Audio", "Autosave Information", "Biome", "Calendars", "CallServices", "ColorPickers",
        "ColorSync", "Colors", "Compositions", "ContainerManager", "Containers", "Cookies", "CoreFollowUp", "Daemon Containers",
        "DataDeliveryServices", "DoNotDisturb", "DuetExpertCenter", "Favorites", "FontCollections", "Fonts", "FrontBoard", "GameKit",
        "Group Containers", "HTTPStorages", "HomeKit", "IdentityServices", "Input Methods", "IntelligencePlatform", "Intents",
        "Internet Plug-Ins", "Keyboard", "Keyboard Layouts", "KeyboardServices", "Keychains", "LanguageModeling", "LaunchAgents",
        "Mail", "Messages", "Metadata", "Mobile Documents", "CloudStorage", "Passes", "Personas", "PersonalizationPortrait", "Photos",
        "Preferences", "Printers", "PrivateCloudCompute", "Reminders", "ResponseKit", "Safari", "SafariSafeBrowsing",
        "Saved Application State", "Screen Savers", "Services", "Sharing", "Shortcuts", "Sounds", "Spelling", "Spotlight", "StatusKit",
        "Suggestions", "SyncedPreferences", "Translation", "Trial", "Weather", "WebKit", "Application Scripts", "Frameworks",
        "AddressBook", "CallHistoryDB", "CallHistoryTransactions", "MobileSync", "Knowledge", "FileProvider", "CloudDocs", "FaceTime",
        "Dock", "Animoji", "AccessibilityBundles", "App Store", "CrashReporter", "DiskImages", "SyncServices", "Wallpaper", "Photos",
        "Music", "TV", "Podcasts", "Books", "News", "Stocks", "Home", "Maps", "Notes", "Voice Memos", "Siri", "icdd", "homeenergyd",
        "networkserviceproxy", "identityservicesd", "NotificationCenter", "Mail Downloads", "Containers 2", "Group Containers 2"]

    /// Still measuring, and not stuck: past this the server may exit even if a walk never returns.
    var busy: Bool { lock.lock(); defer { lock.unlock() }; return report.map { $0.running && Date().timeIntervalSince1970 - $0.t < Self.deadline + 60 } ?? false }

    /// The latest report; starts measuring when there is none, it is over an hour old, or `fresh` is asked.
    func current(fresh: Bool) -> SpaceReport? {
        lock.lock()
        if report == nil, let d = try? Data(contentsOf: cacheFile) { report = try? JSONDecoder().decode(SpaceReport.self, from: d) }
        let r = report
        lock.unlock()
        let stale = r.map { Date().timeIntervalSince1970 - $0.t > Self.freshFor } ?? true
        if r?.running != true, fresh || stale { start() }
        lock.lock(); defer { lock.unlock() }
        return report
    }

    /// One folder to measure: where it goes in the report, and which of its subfolders to leave alone.
    private struct Unit { var group: String; var child: String?; var path: String; var leave: (String, String) -> Bool }

    private func start() {
        let home = NSHomeDirectory()
        let vol = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                                            .volumeAvailableCapacityForImportantUsageKey])
        let avail = Double(vol?.volumeAvailableCapacity ?? 0)
        let important = vol?.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? avail
        let begin = Date()
        lock.lock()
        report = SpaceReport(t: begin.timeIntervalSince1970, seconds: 0, running: true, partial: false, total: Double(vol?.volumeTotalCapacity ?? 0),
                             free: important, purgeable: max(0, important - avail), snapshots: 0, items: [])
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            let fm = FileManager.default
            var blocked = Set((try? String(contentsOf: blockedFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [])
            let fda = hasFullDiskAccess()

            // What to measure. Listing a folder's names (not opening its subfolders) never prompts
            // for home and Library; it is opening the guarded subfolders that does.
            var units: [Unit] = []
            var homeFiles = 0.0
            var leftAlone: [String] = []
            for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] {
                let path = home + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) != S_IFDIR { homeFiles += Double(st.st_blocks) * 512; continue }
                if Self.guardedHome.contains(name) {
                    if fda, ["Desktop", "Documents", "Downloads"].contains(name) { units.append(Unit(group: name, path: path, leave: { _, _ in false })) }
                    else if name != "Library" && name != "Public" { leftAlone.append(name) }
                    continue
                }
                units.append(Unit(group: name, path: path, leave: { _, _ in false }))
            }
            let shared = ["Application Support", "Caches", "Logs"]
            for name in (try? fm.contentsOfDirectory(atPath: home + "/Library")) ?? [] where !Self.appleOwned(name) && !shared.contains(name) {
                var isDir: ObjCBool = false
                let path = home + "/Library/" + name
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                units.append(Unit(group: "Library", child: name, path: path, leave: { _, _ in false }))
            }
            // Your apps' share of the folders Apple also writes to.
            for name in shared {
                units.append(Unit(group: "Library", child: name, path: home + "/Library/" + name, leave: { rel, n in !rel.contains("/") && Self.appleOwned(n) }))
            }
            units.append(Unit(group: "Applications", path: "/Applications", leave: { _, _ in false }))
            leftAlone.append(contentsOf: ["Other apps’ data and Apple’s own data in Library", "Cloud folders"])

            var groups: [String: SpaceItem] = homeFiles > 0 ? ["Other files in your home folder": SpaceItem(name: "Other files in your home folder", bytes: homeFiles)] : [:]
            var library: [String: SpaceItem] = [:]
            let deadline = begin.addingTimeInterval(Self.deadline)
            var timedOut = false

            func publish(running: Bool) {
                var items = Array(groups.values)
                if var lib = groups["Library"] {
                    lib.children = library.values.sorted { $0.bytes > $1.bytes }.filter { $0.bytes > 50e6 }
                    items.removeAll { $0.name == "Library" }
                    items.append(lib)
                }
                items = items.filter { $0.bytes > 1e6 }.sorted { $0.bytes > $1.bytes }
                lock.lock()
                report?.items = items
                report?.running = running
                report?.partial = timedOut
                report?.fullDiskAccess = fda
                report?.leftAlone = leftAlone + blocked.map { $0.hasPrefix(home + "/") ? String($0.dropFirst(home.count + 1)) : $0 }.sorted()
                report?.seconds = Date().timeIntervalSince(begin)
                let r = report
                lock.unlock()
                if !running, let r, let d = try? JSONEncoder().encode(r) {
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? d.write(to: cacheFile, options: .atomic)
                }
            }

            for u in units {
                if Date() > deadline { timedOut = true; break }
                // A folder that stalls (macOS waiting on a permission answer) is abandoned on its thread
                // and remembered, then the rest of the unit is measured again without it.
                for _ in 0..<3 {
                    let w = Walk(root: u.path, skip: blocked.union(Self.cloud.map { home + "/" + $0 }), leave: u.leave, deadline: deadline)
                    let done = DispatchSemaphore(value: 0)
                    Thread.detachNewThread { w.run(); done.signal() }
                    var seen = -1
                    while done.wait(timeout: .now() + Self.stall) == .timedOut {
                        let n = w.progress
                        if n == seen { break }      // no new entry in `stall` seconds: stuck
                        seen = n
                    }
                    if w.finished {
                        if w.ranOut { timedOut = true }
                        groups[u.group, default: SpaceItem(name: u.group, bytes: 0)].bytes += w.bytes
                        if let c = u.child { library[c, default: SpaceItem(name: c, bytes: 0)].bytes += w.bytes }
                        break
                    }
                    w.abandon()
                    blocked.insert(w.currentDir)
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? blocked.sorted().joined(separator: "\n").write(to: blockedFile, atomically: true, encoding: .utf8)
                }
                publish(running: true)
            }
            lock.lock(); report?.snapshots = localSnapshots(); lock.unlock()
            publish(running: false)
        }
    }

    /// The privacy database is readable only with Full Disk Access, and a refusal there is silent.
    private func hasFullDiskAccess() -> Bool {
        let fd = open(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    private func localSnapshots() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").filter { $0.contains("com.apple.") }.count
    }
}

/// One folder's allocated size (one volume, links not followed), walked on its own thread so a stuck
/// open can be abandoned.
private final class Walk {
    let root: String, skip: Set<String>, leave: (String, String) -> Bool, deadline: Date
    private let lock = NSLock()
    private var _bytes = 0.0, _progress = 0, _dir = "", _finished = false, _ranOut = false, _abandoned = false

    init(root: String, skip: Set<String>, leave: @escaping (String, String) -> Bool, deadline: Date) {
        self.root = root; self.skip = skip; self.leave = leave; self.deadline = deadline
    }

    var bytes: Double { lock.lock(); defer { lock.unlock() }; return _bytes }
    var progress: Int { lock.lock(); defer { lock.unlock() }; return _progress }
    var currentDir: String { lock.lock(); defer { lock.unlock() }; return _dir }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
    var ranOut: Bool { lock.lock(); defer { lock.unlock() }; return _ranOut }
    func abandon() { lock.lock(); _abandoned = true; lock.unlock() }

    func run() {
        let cRoot = strdup(root)
        defer { free(cRoot) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { finish(ranOut: false); return }
        defer { fts_close(fts) }
        var total = 0.0, n = 0
        while let e = fts_read(fts) {
            let info = Int32(e.pointee.fts_info)
            if info == FTS_D {
                let path = String(cString: e.pointee.fts_path)
                let rel = path.count > root.count ? String(path.dropFirst(root.count + 1)) : ""
                if e.pointee.fts_level > 0, skip.contains(path) || leave(rel, (path as NSString).lastPathComponent) {
                    fts_set(fts, e, FTS_SKIP)
                } else {
                    lock.lock(); _dir = path; lock.unlock()     // the next read opens it
                }
            } else if info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT, let st = e.pointee.fts_statp {
                total += Double(st.pointee.st_blocks) * 512
            }
            n += 1
            if n % 64 == 0 {
                lock.lock(); let gone = _abandoned; _bytes = total; _progress = n; lock.unlock()
                if gone { return }
                if Date() > deadline { lock.lock(); _bytes = total; lock.unlock(); finish(ranOut: true); return }
            }
        }
        lock.lock(); _bytes = total; _progress = n; lock.unlock()
        finish(ranOut: false)
    }

    private func finish(ranOut: Bool) { lock.lock(); _ranOut = ranOut; _finished = !_abandoned; lock.unlock() }
}
