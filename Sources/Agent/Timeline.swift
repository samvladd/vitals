import Foundation

// The activity timeline: "what did my Mac do?". Once a minute the logger also notes which apps used
// the CPU over that minute and which held the most memory, in a file of its own beside the day's CSV
// (Logs/YYYY-MM-DD.procs.jsonl), so the CSV and loadHistory stay exactly as they were. The yearly
// cleanup in write() removes these files too: their names start with the date, so they sort against
// the cutoff the same way the CSVs do. GET /timeline?day= reads one day of both and says what
// happened: hour by hour, the moments worth knowing about, and the day's totals.

// MARK: logging

/// A once-a-minute version of Sampler's process scan. It reads each process's CPU time and takes the
/// difference from the last scan, which is exact for the whole minute, where sampling every 10 s
/// would cost six scans. Names are looked up only for processes it has not seen before.
final class ProcLog {
    private var prev: [pid_t: UInt64] = [:]
    private var names: [pid_t: String] = [:]
    private var prevAt: Date?
    private let ns: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()

    /// Called by the logger as it writes `minute`'s row; the scan covers the minute just ended.
    func record(minute: Int) {
        let now = Date()
        // The first scan, or the first after the Mac slept, has no minute to measure: only a new baseline.
        let elapsed = prevAt.map { now.timeIntervalSince($0) } ?? 0
        let measure = elapsed > 20 && elapsed < 150
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var next: [pid_t: UInt64] = [:], nextNames: [pid_t: String] = [:]
        next.reserveCapacity(got); nextNames.reserveCapacity(got)
        var byName: [String: (cpu: Double, mem: Double)] = [:]
        var buf = [CChar](repeating: 0, count: 256)
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(got) where pid > 0 {
            var ti = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { continue }
            let total = ti.pti_total_user + ti.pti_total_system
            next[pid] = total
            // A process that started since the last scan counts all of its time; one that ended is missed.
            let was = prev[pid].flatMap { $0 <= total ? $0 : nil }
            let name: String
            if was != nil, let known = names[pid] { name = known } else {
                proc_name(pid, &buf, UInt32(buf.count))
                let s = String(cString: buf)
                name = s.range(of: " Helper").map { String(s[..<$0.lowerBound]) } ?? s    // helpers under their app, as topProcs does
            }
            nextNames[pid] = name
            guard measure, !name.isEmpty else { continue }
            byName[name, default: (0, 0)].cpu += Double(total - (was ?? 0)) * ns / (elapsed * 1e9) * 100
            byName[name, default: (0, 0)].mem += Double(ti.pti_resident_size)
        }
        prev = next; names = nextNames; prevAt = now
        guard measure, !byName.isEmpty else { return }

        // The five busiest (% of one core, as the dashboard shows processes) and the three largest (MB).
        let cpu = byName.filter { $0.value.cpu >= 1 }.sorted { $0.value.cpu > $1.value.cpu }.prefix(5)
            .map { "[\(quoted($0.key)),\(String(format: "%.1f", $0.value.cpu))]" }
        let mem = byName.sorted { $0.value.mem > $1.value.mem }.prefix(3)
            .map { "[\(quoted($0.key)),\(Int($0.value.mem / 1_048_576))]" }
        let line = "{\"t\":\(minute * 60),\"cpu\":[\(cpu.joined(separator: ","))],\"mem\":[\(mem.joined(separator: ","))]}\n"
        let file = logDir.appendingPathComponent(dayFormat.string(from: Date(timeIntervalSince1970: Double(minute * 60))) + ".procs.jsonl")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func quoted(_ s: String) -> String { (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"?\"" }
}

// MARK: GET /timeline

enum Timeline {
    /// CPU time in minutes of one core: an app that kept one core busy for an hour used 60.
    struct Use: Encodable { var name: String; var min: Double }

    struct Hour: Encodable {
        var t: Double
        var minutes = 0                   // logged, so awake
        var cpu: Double?, cpuMax: Double? // % of the whole chip: the hour's average, its busiest minute
        var w: Double?, wh = 0.0
        var temp: Double?, tempMax: Double?
        var apps: [Use] = []
        var appMinutes = 0                // minutes with app activity logged (none before this version)
    }

    struct Moment: Encodable {
        var kind: String                  // busy, hot, swap, asleep, off
        var start: Double, end: Double
        var app: String? = nil            // the app behind it
        var cpu: Double? = nil            // % of the whole chip, on average
        var temp: Double? = nil           // °C, at peak
        var swap: Double? = nil           // bytes it grew by
        var mem: Double? = nil            // bytes the app held
        var minutes: Int? = nil           // hot: how many minutes were above 90°
    }

    struct Totals: Encodable {
        var wh = 0.0, wMax = 0.0
        var cpu: Double?, tempMax: Double?
        var minutes = 0
        var apps: [Use] = []              // the day's busiest, most first
    }

    struct Day: Encodable {
        var day: String
        var start: Double, end: Double, now: Double
        var hours: [Hour]
        var awake: [[Double]]             // the logged stretches, [start, end]
        var moments: [Moment]
        var totals: Totals
        var apps: Bool                    // app activity was logged that day
        var days: [String]                // of the last 14, the days with a log, oldest first
    }

    // Thresholds for a moment.
    static let busyCPU = 80.0, busyFor = 600.0, hotTemp = 90.0, swapGrowth = 2_147_483_648.0, asleepFor = 900.0

    private struct Row { var t, w, cpu, temp, swap, seconds: Double }
    private struct Minute { var t: Double; var cpu: [(String, Double)]; var mem: [(String, Double)] }

    /// One day, `yyyy-MM-dd` (today when missing or malformed). About 1,440 rows: a few milliseconds.
    static func day(_ asked: String?) -> Day {
        let cal = Calendar.current, nowT = Date().timeIntervalSince1970
        let date = asked.flatMap { a in dayFormat.date(from: a).flatMap { dayFormat.string(from: $0) == a ? $0 : nil } } ?? Date()
        let name = dayFormat.string(from: date)
        let start = cal.startOfDay(for: date), end = cal.date(byAdding: .day, value: 1, to: start)!
        var hours: [Hour] = []
        var h = start
        while h < end { hours.append(Hour(t: h.timeIntervalSince1970)); h = cal.date(byAdding: .hour, value: 1, to: h)! }   // 23 or 25 on a clock change
        let t0 = start.timeIntervalSince1970, t1 = end.timeIntervalSince1970
        func hourOf(_ t: Double) -> Int {
            var i = min(max(Int((t - t0) / 3600), 0), hours.count - 1)
            while i > 0, hours[i].t > t { i -= 1 }
            while i + 1 < hours.count, hours[i + 1].t <= t { i += 1 }
            return i
        }

        let rows = readRows(name), minutes = readMinutes(name)

        // Hours: averages over the minutes logged, and the apps that used the most CPU in each.
        var sums = [(cpu: Double, w: Double, temp: Double, n: Double, nt: Double)](repeating: (0, 0, 0, 0, 0), count: hours.count)
        for r in rows {
            let i = hourOf(r.t)
            hours[i].minutes += 1; hours[i].wh += r.w * r.seconds / 3600
            hours[i].cpuMax = max(hours[i].cpuMax ?? 0, r.cpu)
            sums[i].cpu += r.cpu; sums[i].w += r.w; sums[i].n += 1
            if r.temp > 0 { sums[i].temp += r.temp; sums[i].nt += 1; hours[i].tempMax = max(hours[i].tempMax ?? 0, r.temp) }
        }
        var perHour = [[String: Double]](repeating: [:], count: hours.count), perDay: [String: Double] = [:]
        for m in minutes {
            let i = hourOf(m.t)
            hours[i].appMinutes += 1
            for (n, c) in m.cpu { perHour[i][n, default: 0] += c / 100; perDay[n, default: 0] += c / 100 }
        }
        for i in hours.indices {
            let s = sums[i]
            if s.n > 0 { hours[i].cpu = r1(s.cpu / s.n); hours[i].w = r1(s.w / s.n) }
            if s.nt > 0 { hours[i].temp = r1(s.temp / s.nt) }
            hours[i].wh = r1(hours[i].wh); hours[i].cpuMax = hours[i].cpuMax.map(r1); hours[i].tempMax = hours[i].tempMax.map(r1)
            hours[i].apps = top(perHour[i], 3)
        }

        // Awake: runs of rows a minute apart; a gap of more than two minutes is the Mac asleep or off.
        var awake: [[Double]] = []
        for r in rows {
            if let last = awake.last, r.t - (last[1] - 60) <= 180 { awake[awake.count - 1][1] = r.t + 60 } else { awake.append([r.t, r.t + 60]) }
        }

        var moments: [Moment] = []
        func topApp(_ a: Double, _ b: Double) -> String? {
            var use: [String: Double] = [:]
            for m in minutes where m.t >= a && m.t < b { for (n, c) in m.cpu { use[n, default: 0] += c } }
            return use.max { $0.value < $1.value }?.key
        }
        func within(_ a: Double, _ b: Double) -> [Row] { rows.filter { $0.t >= a && $0.t < b } }

        // Busy: the CPU at 80% or more for ten minutes, letting it dip for a minute or two.
        for run in runs(rows.filter { $0.cpu >= busyCPU }, gap: 180) where run.last!.t + 60 - run.first!.t >= busyFor {
            let a = run.first!.t, b = run.last!.t + 60, inside = within(a, b)
            moments.append(Moment(kind: "busy", start: a, end: b, app: topApp(a, b),
                                  cpu: r1(inside.reduce(0) { $0 + $1.cpu } / Double(inside.count)),
                                  temp: inside.map(\.temp).max().flatMap { $0 > 0 ? r1($0) : nil }))
        }
        // Hot: above 90° outside the busy stretches (inside one, it is that stretch's peak). Some Macs
        // run near 90° all day, so minutes a quarter of an hour apart are one moment, and it takes three.
        let busy = moments
        let hot = rows.filter { r in r.temp >= hotTemp && !busy.contains { r.t >= $0.start && r.t < $0.end } }
        for run in runs(hot, gap: 900) where run.count >= 3 {
            let a = run.first!.t, b = run.last!.t + 60
            moments.append(Moment(kind: "hot", start: a, end: b, app: topApp(a, b), temp: r1(run.map(\.temp).max()!), minutes: run.count))
        }
        // Swap: 2 GB or more above its lowest point of the half hour before. Swap swings by a gigabyte
        // on a busy Mac all the time; this is the climb that stays. Climbs ten minutes apart are one, and
        // the app behind it is the one holding the most memory at the top.
        var growing: [(row: Row, low: Row)] = []
        var w = 0
        for r in rows {
            while rows[w].t < r.t - 1800 { w += 1 }
            let low = rows[w...].prefix { $0.t <= r.t }.min { $0.swap < $1.swap }!
            if r.swap - low.swap >= swapGrowth { growing.append((r, low)) }
        }
        var k = 0
        while k < growing.count {
            var j = k
            while j + 1 < growing.count, growing[j + 1].row.t - growing[j].row.t <= 600 { j += 1 }
            let low = growing[k].low, top = growing[k...j].max { $0.row.swap < $1.row.swap }!.row
            let last = minutes.last { $0.t >= low.t && $0.t <= top.t }
            moments.append(Moment(kind: "swap", start: low.t, end: top.t + 60, app: last?.mem.first?.0, swap: top.swap - low.swap,
                                  mem: last?.mem.first.map { $0.1 * 1_048_576 }))
            k = j + 1
        }
        // Asleep or off: the gaps, including before the first minute (if the Mac was logged the day
        // before) and after the last. The latest start-up says which gap was a restart.
        var boot = timeval(), size = MemoryLayout<timeval>.size
        let booted = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 ? Double(boot.tv_sec) : 0
        let logged = FileManager.default.fileExists(atPath: logDir.appendingPathComponent(dayFormat.string(from: start.addingTimeInterval(-43200)) + ".csv").path)
        var edges = awake.flatMap { $0 }
        edges.insert(logged || awake.isEmpty ? t0 : awake[0][0], at: 0)
        edges.append(min(t1, nowT))
        for k in stride(from: 0, to: edges.count - 1, by: 2) where edges[k + 1] - edges[k] >= asleepFor {
            let a = edges[k], b = edges[k + 1]
            moments.append(Moment(kind: booted > a && booted < b + 120 ? "off" : "asleep", start: a, end: b))
        }
        if rows.isEmpty { moments.removeAll() }       // nothing logged: nothing to say, rather than "asleep all day"
        moments.sort { $0.start < $1.start }

        var totals = Totals()
        for r in rows { totals.wh += r.w * r.seconds / 3600; totals.wMax = max(totals.wMax, r.w) }
        totals.wh = r1(totals.wh); totals.wMax = r1(totals.wMax); totals.minutes = rows.count
        if !rows.isEmpty { totals.cpu = r1(rows.reduce(0) { $0 + $1.cpu } / Double(rows.count)) }
        totals.tempMax = rows.map(\.temp).max().flatMap { $0 > 0 ? r1($0) : nil }
        totals.apps = top(perDay, 5)

        let days = (0..<14).reversed().map { dayFormat.string(from: cal.date(byAdding: .day, value: -$0, to: Date())!) }
            .filter { FileManager.default.fileExists(atPath: logDir.appendingPathComponent($0 + ".csv").path) }
        return Day(day: name, start: t0, end: t1, now: nowT, hours: hours, awake: awake, moments: moments, totals: totals,
                   apps: !minutes.isEmpty, days: days)
    }

    /// The day's CSV, read positionally as loadHistory does.
    private static func readRows(_ day: String) -> [Row] {
        guard let text = try? String(contentsOf: logDir.appendingPathComponent(day + ".csv"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let c = line.split(separator: ",").compactMap { Double($0) }
            return c.count >= 10 ? Row(t: c[0], w: c[1], cpu: c[3], temp: c[5], swap: c[8], seconds: c[9]) : nil
        }.sorted { $0.t < $1.t }
    }

    /// The day's app activity, one JSON line a minute, parsed in one go; a torn last line is skipped.
    private static func readMinutes(_ day: String) -> [Minute] {
        guard let text = try? String(contentsOf: logDir.appendingPathComponent(day + ".procs.jsonl"), encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("{") && $0.hasSuffix("}") }
        guard let all = try? JSONSerialization.jsonObject(with: Data(("[" + lines.joined(separator: ",") + "]").utf8)) as? [[String: Any]] else { return [] }
        func pairs(_ v: Any?) -> [(String, Double)] {
            (v as? [[Any]] ?? []).compactMap { p in p.count == 2 ? (p[0] as? String).flatMap { n in (p[1] as? NSNumber).map { (n, $0.doubleValue) } } : nil }
        }
        return all.compactMap { d in (d["t"] as? NSNumber).map { Minute(t: $0.doubleValue, cpu: pairs(d["cpu"]), mem: pairs(d["mem"])) } }
    }

    /// Runs of rows no more than `gap` seconds apart.
    private static func runs(_ rs: [Row], gap: Double) -> [[Row]] {
        var out: [[Row]] = []
        for r in rs { if let l = out.last?.last, r.t - l.t <= gap { out[out.count - 1].append(r) } else { out.append([r]) } }
        return out
    }

    private static func top(_ use: [String: Double], _ n: Int) -> [Use] {
        use.sorted { $0.value > $1.value }.prefix(n).filter { $0.value >= 0.05 }.map { Use(name: $0.key, min: r1($0.value)) }
    }

    private static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
