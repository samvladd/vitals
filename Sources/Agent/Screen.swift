import AppKit
import CoreGraphics
import CryptoKit
import Foundation

// Screen: the dashboard's Screen page shows and controls this Mac's screen in the browser. macOS's own
// Screen Sharing does the work (it asks for this Mac's login password, and macOS starts it only while
// someone is connected); this file only relays bytes between the page's WebSocket and Screen Sharing
// on 127.0.0.1:5900. The relay never reads or keeps what passes through it, the password included.
//
// It is off until `vitals-agent screen on`, and the WebSocket must pass the same checks as app control
// (Control.gate, as a change). A session ends when the page closes, when either side drops, when the
// page stops answering (a ping every 25 s; silence for 75 s is a phone out of signal), or after ten
// minutes without that device's page reporting a touch or a key (POST /screen/alive). At most three
// sessions at a time.
//
// Copy and paste go through this Mac's own clipboard (Clipboard, below), read and set by this process
// for the page: Screen Sharing passes it to a browser unreliably, if at all. A file dropped on the page
// lands in ~/Downloads (Upload), and the speed box can say how Tailscale carries the session (Link).

enum Screen {
    static var idleLimit = 600.0               // --screen-idle, for tests
    static var port: UInt16 = 5900
    static let maxSessions = 3
    private(set) static var relays: [ScreenRelay] = []      // main queue only
    private static var emptySince: Date?

    static func add(_ r: ScreenRelay) { relays.append(r); emptySince = nil }
    static func remove(_ r: ScreenRelay) {
        relays.removeAll { $0 === r }
        if relays.isEmpty { emptySince = Date() }
    }

    /// A touch or a key on one device's page keeps that device's sessions open (and no one else's).
    static func touched(by device: String) { for r in relays where r.device == device { r.lastInput = Date() } }

    /// That device's open session, if it has one: the clipboard is only shared while its screen is open.
    static func session(of device: String) -> ScreenRelay? { relays.first { $0.device == device } }

    /// Called every few seconds on the main queue.
    static func housekeeping() {
        let now = Date()
        // Back to Retina once nobody has been connected for 30 s; a reconnect in between keeps it fast.
        if relays.isEmpty, let since = Display.since, now.timeIntervalSince(max(since, emptySince ?? since)) > 30 { Display.restore() }
        for r in relays {
            if now.timeIntervalSince(r.lastInput) > idleLimit { r.end(reason: "nothing touched for \(F.duration(idleLimit))") }
            else { r.pingIfDue(now) }
        }
    }

    /// The `Sec-WebSocket-Accept` value for a client's key (RFC 6455).
    static func accept(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    static func connectLocal(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }
}

/// One Screen session: the page's socket on one side, Screen Sharing's on the other, a thread each way.
/// Blocking reads and writes keep it simple and fast: bytes are copied once and sent as they arrive.
/// Two locks: `state` for the flags (held only for an instant, so the main queue never waits on a slow
/// phone), `writing` around every write to the page, and the sockets are closed while holding both, so
/// nothing can write to or shut down a socket number that has since been reused.
final class ScreenRelay {
    let client: Int32, vnc: Int32, device: String
    var lastInput = Date()                    // main queue only
    var sharedClipboard = false               // main queue only: logged once a session
    private var lastPing = Date()             // main queue only
    private let started = Date()
    private let state = NSLock(), writing = NSLock()
    private var ended = false, closed = false
    private var why = "closed"
    private var running = 2
    private(set) var fromMac = 0, peakPerSecond = 0      // read once both threads are done
    private let onFinish: (ScreenRelay, String, TimeInterval) -> Void

    init(client: Int32, vnc: Int32, device: String, onFinish: @escaping (ScreenRelay, String, TimeInterval) -> Void) {
        self.client = client; self.vnc = vnc; self.device = device; self.onFinish = onFinish
        var on: Int32 = 1
        // Nothing waits to fill a packet: a click goes out at once, and so does each piece of the picture.
        for fd in [client, vnc] {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        // A page that stops reading for 20 s, or sends nothing for 75 s (it answers the 25 s pings by
        // itself), is a phone out of signal: dropped rather than left holding a signed-in session.
        var w = timeval(tv_sec: 20, tv_usec: 0), r = timeval(tv_sec: 75, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &w, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
    }

    func start() {
        Thread.detachNewThread { [self] in pageToMac(); finished() }
        Thread.detachNewThread { [self] in macToPage(); finished() }
    }

    /// Ends the session from any thread: tells the page (unless it is the one closing), then shuts both
    /// sockets so the blocking reads return and both threads finish. Never blocks the caller.
    func end(reason: String, tellPage: Bool = true) {
        state.lock()
        guard !ended else { return state.unlock() }
        ended = true; why = reason
        state.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            if tellPage { send(0x8, [0x03, 0xE9][...]) }          // 1001: going away
            state.lock()
            if !closed { shutdown(client, SHUT_RDWR); shutdown(vnc, SHUT_RDWR) }
            state.unlock()
        }
    }

    /// Main queue: a ping every 25 s, sent off the main queue since a stalled page can block a write.
    func pingIfDue(_ now: Date) {
        guard now.timeIntervalSince(lastPing) >= 25 else { return }
        lastPing = now
        DispatchQueue.global(qos: .utility).async { [self] in send(0x9, [][...]) }
    }

    private func finished() {
        state.lock(); running -= 1; let last = running == 0; state.unlock()
        guard last else { return }
        writing.lock(); state.lock()
        closed = true
        close(client); close(vnc)
        let reason = why
        state.unlock(); writing.unlock()
        let seconds = Date().timeIntervalSince(started)
        DispatchQueue.main.async { [self] in onFinish(self, reason, seconds) }
    }

    // MARK: page -> Mac: unmask the page's WebSocket frames and pass their payload on

    private func pageToMac() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var pos = 0, top = 0                    // unread bytes are buf[pos..<top]
        var silent = false                      // the 75 s receive timeout ran out
        func more() -> Bool {
            if pos == top { pos = 0; top = 0 }
            if top == buf.count {               // move what is left to the front
                buf.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: $0.baseAddress! + pos, byteCount: top - pos) }
                top -= pos; pos = 0
            }
            let room = buf.count - top
            let r = buf.withUnsafeMutableBytes { read(client, $0.baseAddress! + top, room) }
            if r < 0, errno == EAGAIN || errno == EWOULDBLOCK { silent = true }
            if r <= 0 { return false }
            top += r
            return true
        }
        func need(_ n: Int) -> Bool {           // n <= 14: a frame header
            while top - pos < n { guard more() else { return false } }
            return true
        }
        func byte() -> UInt8 { defer { pos += 1 }; return buf[pos] }

        var inBinary = false                    // inside a fragmented binary message
        while true {
            guard need(2) else { return end(reason: silent ? "page stopped answering" : "page closed", tellPage: false) }
            let b0 = byte(), b1 = byte()
            let fin = b0 & 0x80 != 0, op = b0 & 0x0F
            // Only what a browser sends noVNC's way: binary data (maybe in pieces), close, ping, pong.
            guard b0 & 0x70 == 0, [0x0, 0x2, 0x8, 0x9, 0xA].contains(op), op != 0x0 || inBinary else { return end(reason: "bad frame") }
            var len = Int(b1 & 0x7F)
            if len == 126 { guard need(2) else { return end(reason: silent ? "page stopped answering" : "page closed", tellPage: false) }; len = Int(byte()) << 8 | Int(byte()) }
            else if len == 127 { guard need(8) else { return end(reason: silent ? "page stopped answering" : "page closed", tellPage: false) }; len = (0..<8).reduce(0) { a, _ in a << 8 | Int(byte()) } }
            // Pages always mask what they send (RFC 6455), and noVNC's messages are small.
            guard b1 & 0x80 != 0, len >= 0, len <= 1 << 20, op < 0x8 || (fin && len <= 125), need(4) else { return end(reason: "bad frame") }
            if op < 0x8 { inBinary = !fin }
            let mask = [byte(), byte(), byte(), byte()]
            var payload: [UInt8] = []           // control frames only: small, kept whole
            var done = 0
            while done < len {
                if pos == top { guard more() else { return end(reason: silent ? "page stopped answering" : "page closed", tellPage: false) } }
                let n = min(len - done, top - pos)
                for i in 0..<n { buf[pos + i] ^= mask[(done + i) & 3] }
                if op == 0x0 || op == 0x2 {     // binary data, or its continuation: straight to Screen Sharing
                    var off = 0
                    while off < n {
                        let w = buf.withUnsafeBytes { write(vnc, $0.baseAddress! + pos + off, n - off) }
                        if w <= 0 { return end(reason: "Screen Sharing closed") }
                        off += w
                    }
                } else { payload += buf[pos..<pos + n] }
                pos += n; done += n
            }
            switch op {
            case 0x8: send(0x8, payload.prefix(2)[...]); return end(reason: silent ? "page stopped answering" : "page closed", tellPage: false)
            case 0x9: send(0xA, payload[...])  // ping: answer pong
            default: break                      // text and pong frames carry nothing for us
            }
        }
    }

    // MARK: Mac -> page: whatever Screen Sharing sends, as one binary frame per read

    private func macToPage() {
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        var second = Date(), inSecond = 0
        while true {
            let n = read(vnc, &buf, buf.count)
            guard n > 0 else { return end(reason: "Screen Sharing closed") }     // keeps an earlier reason
            fromMac += n; inSecond += n
            if Date().timeIntervalSince(second) >= 1 { peakPerSecond = max(peakPerSecond, inSecond); inSecond = 0; second = Date() }
            guard send(0x2, buf[0..<n]) else { return end(reason: "page stopped reading") }
        }
    }

    @discardableResult private func send(_ op: UInt8, _ payload: ArraySlice<UInt8>) -> Bool {
        var head: [UInt8] = [0x80 | op]
        let n = payload.count
        if n < 126 { head.append(UInt8(n)) }
        else if n < 65536 { head += [126, UInt8(n >> 8), UInt8(n & 0xFF)] }
        else { head.append(127); head += (0..<8).reversed().map { UInt8((n >> ($0 * 8)) & 0xFF) } }
        writing.lock(); defer { writing.unlock() }
        if closed { return false }              // set only while `writing` is held, so safe to read here
        func put(_ p: UnsafeRawBufferPointer, from: Int) -> Bool {
            var off = from
            while off < p.count {
                let w = write(client, p.baseAddress! + off, p.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
        // Header and payload in one call, so they leave as one packet rather than a tiny one and the rest.
        return head.withUnsafeBytes { h in payload.withUnsafeBytes { p in
            var iov = [iovec(iov_base: UnsafeMutableRawPointer(mutating: h.baseAddress), iov_len: h.count),
                       iovec(iov_base: UnsafeMutableRawPointer(mutating: p.baseAddress), iov_len: p.count)]
            let w = writev(client, &iov, n == 0 ? 1 : 2)
            if w <= 0 { return false }
            return w < h.count ? put(h, from: w) && put(p, from: 0) : put(p, from: w - h.count)
        } }
    }
}

// MARK: Copy and paste: this Mac's clipboard, for the page

/// The page's Copy and Paste. Paste sets this Mac's clipboard to what the page sends and the page then
/// presses ⌘V on the Mac; Copy waits for this Mac's clipboard to change (after the page's ⌘C, or a
/// Copy from a menu on the Mac) and hands it back. Text, rich text (as HTML) and pictures (as PNG):
/// text and HTML up to 1 MB each, a picture up to 8 MB.
enum Clipboard {
    static let maxBytes = 1 << 20
    static let maxImage = 8 << 20
    /// The largest write the page can send: JSON with all three, the picture in base64.
    static let maxWrite = maxImage / 3 * 4 + 3 * maxBytes
    static var count: Int { NSPasteboard.general.changeCount }

    struct Reply: Encodable { var count: Int, text: String?, html: String?, png: String?, skipped: String? }

    /// {"count": N}, with what is on the clipboard when asked and not too big: text, HTML, a PNG (base64).
    static func reply(_ withContent: Bool) -> String {
        let pb = NSPasteboard.general
        var r = Reply(count: pb.changeCount, text: nil, html: nil, png: nil, skipped: nil)
        guard withContent else { return json(r) }
        var tooBig = false
        if let s = pb.string(forType: .string) { if s.utf8.count <= maxBytes { r.text = s } else { tooBig = true } }
        if r.text != nil, let h = html(pb), h.utf8.count <= maxBytes { r.html = h }
        if let png = image(pb) { if png.count <= maxImage { r.png = png.base64EncodedString() } else { tooBig = true } }
        if r.text == nil, r.png == nil { r.html = nil; r.skipped = tooBig ? "too big" : "not text or a picture" }
        return json(r)
    }

    /// HTML as copied from a browser, or rich text (TextEdit, Notes, Pages) turned into HTML.
    private static func html(_ pb: NSPasteboard) -> String? {
        if let h = pb.string(forType: .html) { return h }
        guard let rtf = pb.data(forType: .rtf), rtf.count <= maxBytes,
              let a = NSAttributedString(rtf: rtf, documentAttributes: nil),
              let d = try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// A picture on the clipboard as PNG. Not a file copied in Finder: its picture is only the file's icon.
    private static func image(_ pb: NSPasteboard) -> Data? {
        if pb.types?.contains(.fileURL) == true { return nil }
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff) else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// The page's paste, already checked: replaces what is on the clipboard with all of it at once.
    static func set(text: String?, html: String?, png: Data?) -> Int {
        let item = NSPasteboardItem()
        if let text { item.setString(text, forType: .string) }
        if let html { item.setString(html, forType: .html) }
        if let png { item.setData(png, forType: .png) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        return pb.changeCount
    }

    /// Any picture a browser hands over (PNG, JPEG, GIF, HEIC...) as PNG; nil when it isn't one.
    static func png(_ d: Data) -> Data? {
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return d }
        return NSBitmapImageRep(data: d)?.representation(using: .png, properties: [:])
    }

    /// An app copying empties the clipboard, then fills it: true in between.
    static var settling: Bool { NSPasteboard.general.types?.isEmpty ?? true }
}

// MARK: The speed box: how this device reaches the Mac

/// Whether Tailscale carries this device's traffic straight to the Mac (and whether over the same
/// network), through a peer relay, or through a DERP relay server, which is slower. From
/// `tailscale status --json`, asked at most every 5 s: an answer is never waited for once one is known.
enum Link {
    struct Path: Encodable { var via: String; var lan: Bool? = nil; var region: String? = nil }    // via: direct, peer relay, DERP, unknown

    private static var cache: (Date, [String: Any])?
    private static var asking = false
    private static var waiting: [() -> Void] = []

    /// Main queue. `device` is the tailnet address Tailscale gives in X-Forwarded-For.
    static func path(of device: String, _ done: @escaping (Path) -> Void) {
        if let (t, status) = cache {
            done(path(of: device, in: status))
            if Date().timeIntervalSince(t) > 5 { refresh() }
        } else {
            waiting.append { done(path(of: device, in: cache?.1 ?? [:])) }
            refresh()
        }
    }

    private static func refresh() {
        guard !asking else { return }
        asking = true
        DispatchQueue.global(qos: .utility).async {
            let status = tailscaleStatus() ?? [:]
            DispatchQueue.main.async {
                cache = (Date(), status); asking = false
                let w = waiting; waiting = []
                for f in w { f() }
            }
        }
    }

    static func path(of device: String, in status: [String: Any]) -> Path {
        let peers = (status["Peer"] as? [String: [String: Any]] ?? [:]).values
        guard let p = peers.first(where: { ($0["TailscaleIPs"] as? [String] ?? []).contains(device) }) else { return Path(via: "unknown") }
        if let addr = p["CurAddr"] as? String, !addr.isEmpty { return Path(via: "direct", lan: isLocal(addr)) }
        if let r = p["PeerRelay"] as? String, !r.isEmpty { return Path(via: "peer relay") }
        let region = p["Relay"] as? String
        return Path(via: "DERP", region: region?.isEmpty == false ? region : nil)
    }

    /// "192.168.1.20:41641" or "[fd7a::1]:41641": an address on a private network, so the same one as the Mac.
    static func isLocal(_ addr: String) -> Bool {
        let host = addr.hasPrefix("[") ? String(addr.dropFirst().prefix { $0 != "]" }) : String(addr.split(separator: ":").first ?? "")
        if host.contains(":") { let h = host.lowercased(); return h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd") }
        let o = host.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }
}

// MARK: Files dropped on the page

/// A file dropped onto the Screen page (or picked on a phone) is saved in ~/Downloads on the Mac, under
/// its own name made safe (no folders, no hidden names, nothing that renders backwards), never over
/// an existing file, and marked as downloaded so macOS checks it before it opens, as for a browser's.
enum Upload {
    static let maxBytes = 100 << 20
    static var folder: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads") }

    static func safeName(_ raw: String) -> String {
        // The last part of a path (a phone's, a PC's), and ":" as "-": Finder shows a ":" in a name as "/".
        let last = (raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "").replacingOccurrences(of: ":", with: "-")
        // No control characters, and none of Unicode's invisible format ones (a right-to-left override
        // makes "photo\u{202E}gpj.app" read as "photoppa.jpg").
        var s = String(String.UnicodeScalarView(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }))
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "file" }
        // At most 200 bytes, keeping the extension (macOS allows 255).
        let ext = (s as NSString).pathExtension, base = (s as NSString).deletingPathExtension
        if s.utf8.count > 200 {
            let keep = ext.utf8.count < 20 ? ext : ""
            var b = keep.isEmpty ? s : base
            while b.utf8.count > 200 - (keep.isEmpty ? 0 : keep.utf8.count + 1) { b.removeLast() }
            s = keep.isEmpty ? b : b + "." + keep
        }
        return s
    }

    /// Off the main queue. The name it was saved as, or why not.
    static func save(_ data: Data, as raw: String) -> (name: String?, error: String?) {
        let name = safeName(raw)
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<1000 {
            let candidate = i == 0 ? name : "\(base) (\(i))" + (ext.isEmpty ? "" : "." + ext)
            let path = folder.appendingPathComponent(candidate).path
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if fd < 0 { if errno == EEXIST { continue }; return (nil, "Couldn't save in Downloads on the Mac.") }
            let ok = data.withUnsafeBytes { p -> Bool in
                var off = 0
                while off < p.count {
                    let w = write(fd, p.baseAddress! + off, p.count - off)
                    if w <= 0 { return false }
                    off += w
                }
                return true
            }
            close(fd)
            guard ok else { unlink(path); return (nil, "Couldn't save in Downloads on the Mac (is the disk full?).") }
            let q = String(format: "0081;%08x;Vitals;%@", Int(Date().timeIntervalSince1970), UUID().uuidString)
            _ = q.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
            return (candidate, nil)
        }
        return (nil, "Too many files with that name in Downloads.")
    }
}

// MARK: Faster: the same layout at 1x while someone is watching

/// A Retina screen sends four pixels for every point. For a session, Display switches the screen to
/// the non-Retina mode with the same size in points: windows stay where they are, the picture is a
/// little softer, and Screen Sharing sends a quarter of the pixels. It is for this process only
/// (kCGConfigureForAppOnly), so macOS puts the screen back by itself when the process ends, whatever
/// the reason; Display.restore does it as soon as the last session closes.
enum Display {
    private(set) static var since: Date?          // switched, and when

    /// "1920 × 1080", or nil when the screen is already 1x or has no matching mode.
    static func fast() -> String? {
        let d = CGMainDisplayID()
        guard let cur = CGDisplayCopyDisplayMode(d) else { return nil }
        if cur.pixelWidth == cur.width { return since == nil ? nil : "\(cur.width) × \(cur.height)" }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() && $0.pixelWidth == $0.width && $0.width == cur.width && $0.height == cur.height }
        guard let mode = modes.min(by: { abs($0.refreshRate - cur.refreshRate) < abs($1.refreshRate - cur.refreshRate) }) else { return nil }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return nil }
        CGConfigureDisplayWithDisplayMode(config, d, mode, nil)
        guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success else { return nil }
        since = Date()
        return "\(mode.width) × \(mode.height)"
    }

    static func restore() {
        guard since != nil else { return }
        CGRestorePermanentDisplayConfiguration()
        since = nil
    }
}
