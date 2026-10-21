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
        func put(_ p: UnsafeRawBufferPointer) -> Bool {
            var off = 0
            while off < p.count {
                let w = write(client, p.baseAddress! + off, p.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
        return head.withUnsafeBytes(put) && (n == 0 || payload.withUnsafeBytes(put))
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
