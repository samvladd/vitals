import Foundation

// Energy: what each day used, for up to a year, cheap enough to ask for on every page open. A year of
// minute logs is ~500,000 lines, too much to read per request, so each past day's total is kept in
// Logs/energy.json with the size of the file it came from: a day is read once, and again only if its
// file changed (the 23:59 row lands a few seconds after midnight). Today is always read fresh.

enum Energy {
    struct Total: Encodable { var wh = 0.0, minutes = 0, days = 0 }
    struct Report: Encodable {
        var days: [DayTotal]                // oldest first, only days with a log
        var today: Total, month: Total, lastMonth: Total, year: Total
        var first: String?                  // the first day logged: before it, nothing is known
        var day: String                     // today on this Mac, so a phone in another time zone groups months as it does
    }
    /// For /summary: enough for the fleet card to add up every Mac's month.
    struct Brief: Encodable { var today: Double, month: Double }

    private struct Cached: Codable { var wh: Double, peak: Double, minutes: Int, bytes: Int }
    private static let lock = NSLock()
    private static var cacheFile: URL { logDir.appendingPathComponent("energy.json") }

    /// Every logged day from `since` (yyyy-MM-dd) through today.
    static func days(since: String) -> [DayTotal] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var cache = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode([String: Cached].self, from: $0) } ?? [:]
        var changed = false
        let today = dayFormat.string(from: Date())
        var out: [DayTotal] = []
        let names = ((try? fm.contentsOfDirectory(atPath: logDir.path)) ?? []).filter { $0.hasSuffix(".csv") }.sorted()
        for name in names {
            let day = String(name.dropLast(4))
            guard day >= since, day <= today else { continue }
            let file = logDir.appendingPathComponent(name)
            let bytes = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if day < today, let c = cache[day], c.bytes == bytes {
                out.append(DayTotal(day: day, wh: c.wh, peak: c.peak, minutes: c.minutes)); continue
            }
            guard let d = total(of: file, day: day) else { continue }
            out.append(d)
            if day < today { cache[day] = Cached(wh: d.wh, peak: d.peak, minutes: d.minutes, bytes: bytes); changed = true }
        }
        if changed {
            // The logs are kept a year; so is what was learned from them.
            let cutoff = dayFormat.string(from: Date(timeIntervalSinceNow: -400 * 86400))
            cache = cache.filter { $0.key >= cutoff }
            let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
            try? enc.encode(cache).write(to: cacheFile, options: .atomic)
        }
        return out
    }

    /// One day's file: watt-hours (each minute's mean watts for the seconds it was sampled), the
    /// highest minute peak, and how many minutes were logged. Read as bytes with strtod: a whole
    /// year of files takes well under a second this way.
    private static func total(of file: URL, day: String) -> DayTotal? {
        guard var data = try? Data(contentsOf: file) else { return nil }
        data.append(0)
        var wh = 0.0, peak = 0.0, n = 0
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let base = raw.bindMemory(to: CChar.self).baseAddress!
            let end = base + raw.count - 1
            var p = base
            while p < end, p.pointee != 10 { p += 1 }      // the header
            var cols = [Double](repeating: 0, count: 10)
            while p < end {
                p += 1
                var k = 0
                var q: UnsafeMutablePointer<CChar>? = nil
                while k < 10, p < end, p.pointee != 10 {
                    cols[k] = strtod(p, &q)
                    guard let next = q, next != p else { break }
                    k += 1; p = next
                    if p.pointee == 44 { p += 1 }              // ','
                }
                while p < end, p.pointee != 10 { p += 1 }     // the rest of the line (free space)
                guard k == 10 else { continue }               // a half-written last line
                wh += cols[1] * cols[9] / 3600; peak = max(peak, cols[2]); n += 1
            }
        }
        return DayTotal(day: day, wh: wh, peak: peak, minutes: n)
    }

    private static func month(_ d: Date) -> String { String(dayFormat.string(from: d).prefix(7)) }

    static func report() -> Report {
        let now = Date(), cal = Calendar.current
        let list = days(since: dayFormat.string(from: now.addingTimeInterval(-365 * 86400)))
        let today = dayFormat.string(from: now), thisMonth = month(now)
        let lastMonth = month(cal.date(byAdding: .month, value: -1, to: now) ?? now)
        func sum(_ keep: (String) -> Bool) -> Total {
            list.filter { keep($0.day) }.reduce(into: Total()) { t, d in t.wh += d.wh; t.minutes += d.minutes; t.days += 1 }
        }
        return Report(days: list, today: sum { $0 == today }, month: sum { $0.hasPrefix(thisMonth) },
                      lastMonth: sum { $0.hasPrefix(lastMonth) }, year: sum { $0.hasPrefix(String(today.prefix(4))) },
                      first: list.first?.day, day: today)
    }

    /// This month so far, and today: at most a month of files, nearly always straight from the cache.
    static func brief() -> Brief {
        let now = Date(), today = dayFormat.string(from: now)
        let list = days(since: month(now) + "-01")
        return Brief(today: list.last?.day == today ? list.last!.wh : 0, month: list.reduce(0) { $0 + $1.wh })
    }
}
