import Foundation
import SystemConfiguration

// Wake on LAN: a sleeping Mac can't answer its own page, so another Mac on the same network wakes it.
// Each Mac's /summary says how to wake it (its network card's hardware address and its network's
// broadcast address), and a Mac with app control on sends the standard "magic packet" (6 × 0xFF, then
// the target's address 16 times) when an allowed device asks: POST /wake, body: the target's address.
// It only wakes your own Macs, on its own network:
//  - the address must be one this Mac read itself, over Tailscale, from a fleet member's /summary.
//    Kept in wake.json, because by the time you want to wake a Mac it is asleep and can't be asked; a
//    page can't add to it, so a device allowed here still can't aim packets at anything else;
//  - that Mac must still be in the fleet (your Tailscale account, untagged, macOS);
//  - and it must have been seen on this Mac's own network: the same broadcast address and, where
//    both know it, the same router, which tells two "192.168.1.x" networks apart.
// The packet only goes to this Mac's own LAN broadcast, out of its LAN interface, never to Tailscale.

enum Wake {
    struct Info: Codable, Equatable {
        var mac: String              // the network card's hardware address, aa:bb:cc:dd:ee:ff
        var broadcast: String        // its LAN's IPv4 broadcast address, e.g. 192.168.1.255
        var router: String?          // the router's hardware address: which LAN it is
        var iface: String            // en0
    }

    struct Seen: Codable { var name: String, info: Info, t: Double }

    static let file = supportDir.appendingPathComponent("wake.json")
    /// Fleet member's address -> how to wake it, as that Mac last said.
    private static var known: [String: Seen] = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:]
    private static var asked: [String: Date] = [:]

    // MARK: this Mac

    /// How to wake this Mac: the interface macOS routes through, skipping tunnels (Tailscale's utun).
    /// From SystemConfiguration, not getifaddrs: macOS now hands other processes a placeholder hardware
    /// address (02:00:00:00:00:00) there, and hides the ARP table that would name the router.
    static func mine() -> Info? {
        guard let store = SCDynamicStoreCreate(nil, "vitals-agent" as CFString, nil, nil) else { return nil }
        func dict(_ key: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] }
        let primary = dict("State:/Network/Global/IPv4")?["PrimaryService"] as? String ?? "none"
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        let cards = (SCNetworkInterfaceCopyAll() as NSArray as? [SCNetworkInterface] ?? []).reduce(into: [String: String]()) { m, i in
            if let n = SCNetworkInterfaceGetBSDName(i), let a = SCNetworkInterfaceGetHardwareAddressString(i) { m[n as String] = a as String }
        }
        for key in keys.filter({ $0.contains(primary) }) + keys.filter({ !$0.contains(primary) }) {
            guard let s = dict(key), let iface = s["InterfaceName"] as? String,
                  !["utun", "ipsec", "ppp", "bridge", "awdl", "llw", "lo"].contains(where: iface.hasPrefix),
                  let bc = (dict("State:/Network/Interface/\(iface)/IPv4")?["BroadcastAddresses"] as? [String])?.first,
                  let mac = cards[iface].flatMap(normal) else { continue }
            return Info(mac: mac, broadcast: bc, router: (s["ARPResolvedHardwareAddress"] as? String).flatMap(normal), iface: iface)
        }
        return nil
    }

    /// aa:bb:cc:dd:ee:ff, or nil. Strict: six two-digit hex pairs and colons, nothing else.
    static func bytes(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.compactMap { UInt8($0, radix: 16) }
    }

    /// macOS writes some addresses without leading zeros (0:1b:...); one spelling, for comparing.
    private static func normal(_ s: String) -> String? {
        let p = s.lowercased().split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
        return bytes(p) == nil ? nil : p
    }

    // MARK: the other Macs

    /// Asks each awake fleet member for its /summary, itself and over Tailscale, at most every ten
    /// minutes each; called when the page lists the fleet, so it costs nothing while nobody looks.
    static func learn(_ members: [Fleet.Member]) {
        for m in members where !m.me && m.online && asked[m.url].map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            guard let url = URL(string: m.url + "summary") else { continue }
            asked[m.url] = Date()
            URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { data, resp, _ in
                struct Reply: Decodable { var wake: Info? }
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      var w = (try? JSONDecoder().decode(Reply.self, from: data))?.wake, let mac = normal(w.mac) else { return }
                w.mac = mac
                DispatchQueue.main.async {
                    known[m.url] = Seen(name: m.name, info: w, t: Date().timeIntervalSince1970)
                    if let d = try? JSONEncoder().encode(known) {
                        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
                    }
                }
            }.resume()
        }
    }

    // MARK: POST /wake

    /// Checks the request and sends the packet; the status and JSON for the page.
    static func request(_ r: Request) -> (Int, String) {
        let device: String
        switch Control.gate(r, change: true) {
        case .off: return (404, #"{"error":"off"}"#)
        case .refused(let why):
            Control.record("Blocked a wake request from \(r.headers["x-forwarded-for"] ?? "this Mac") (\(r.headers["tailscale-user-login"] ?? "no account")): \(why)", "refused")
            return (403, json(["error": "This device isn't allowed to wake Macs from this one."]))
        case .allowed(let d): device = d
        }
        let mac = r.body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let target = bytes(mac) else { return (400, json(["error": "Send the Mac's hardware address, like aa:bb:cc:dd:ee:ff."])) }
        let members = Fleet.membersNow()
        guard let hit = known.first(where: { k, v in v.info.mac == mac && members.contains { $0.url == k && !$0.me } }) else {
            Control.record("Refused to wake \(mac) from \(device): not one of your Macs that this one has seen", "refused")
            return (403, json(["error": "That isn't one of your Macs that this one has seen."]))
        }
        let seen = hit.value, name = members.first { $0.url == hit.key }?.name ?? seen.name
        guard let here = mine() else {
            Control.record("Couldn't wake \(name) from \(device): this Mac isn't on a local network", "failed")
            return (409, json(["error": "This Mac isn't on a local network, so it can't wake \(name)."]))
        }
        guard seen.info.broadcast == here.broadcast, seen.info.router == nil || here.router == nil || seen.info.router == here.router else {
            Control.record("Couldn't wake \(name) from \(device): it was last seen on another network", "failed")
            return (409, json(["error": "\(name) was last seen on another network. Wake it from a Mac on that network."]))
        }
        if let err = send(target, via: here) {
            Control.record("Couldn't wake \(name) from \(device): \(err)", "failed")
            return (409, json(["error": err]))
        }
        Control.record("Wake \(name) from \(device)")
        return (200, json(["sent": here.broadcast]))
    }

    /// The magic packet to ports 9 and 7 of this Mac's LAN broadcast, three times over a second: UDP
    /// may drop one, and network cards differ in the port they listen on. nil once the first is sent.
    static func send(_ mac: [UInt8], via here: Info) -> String? {
        let packet = [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in mac }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return "Couldn't open a network socket." }
        var on: Int32 = 1, index = if_nametoindex(here.iface)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        // Out of the LAN interface itself, whatever routes Tailscale (or an exit node) has added.
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, here.broadcast, &a.sin_addr) == 1 else { close(fd); return "This Mac's network address looks wrong." }
        func once() -> Int32 {
            for port: UInt16 in [9, 7] {
                a.sin_port = port.bigEndian
                let n = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                if n < 0 { return errno }
            }
            return 0
        }
        let err = once()
        guard err == 0 else {
            close(fd)
            // macOS's Local Network privacy setting refuses it with "no route to host".
            return err == EHOSTUNREACH || err == EPERM
                ? "macOS blocked it: allow vitals-agent in System Settings › Privacy & Security › Local Network."
                : "Couldn't send the wake packet (\(String(cString: strerror(err))))."
        }
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<2 { usleep(400_000); _ = once() }
            close(fd)
        }
        return nil
    }
}
