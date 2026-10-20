import Foundation
import IOKit

// Minimal client for the System Management Controller (the chip that owns sensors and fans).
// Reading works for any user; writing (fan control) needs root.

struct SMCKeyData {
    struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    var key: UInt32 = 0
    var vers = Vers()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

extension String {
    var fourCC: UInt32 { utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    init(fourCC v: UInt32) {
        self = String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? "????"
    }
}

final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyData.KeyInfo] = [:]

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }
    deinit { IOServiceClose(conn) }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    func info(_ key: UInt32) -> SMCKeyData.KeyInfo? {
        if let i = infoCache[key] { return i }
        var input = SMCKeyData(); input.key = key; input.data8 = 9
        guard let out = call(&input) else { return nil }
        infoCache[key] = out.keyInfo
        return out.keyInfo
    }

    func bytes(_ key: String) -> (type: String, data: [UInt8])? {
        let k = key.fourCC
        guard let i = info(k), i.dataSize > 0 else { return nil }
        var input = SMCKeyData(); input.key = k; input.keyInfo.dataSize = i.dataSize; input.data8 = 5
        guard var out = call(&input) else { return nil }
        let data = withUnsafeBytes(of: &out.bytes) { Array($0.prefix(Int(i.dataSize))) }
        return (String(fourCC: i.dataType), data)
    }

    /// Decodes the common numeric SMC types into a Double.
    func value(_ key: String) -> Double? {
        guard let (type, d) = bytes(key) else { return nil }
        switch type {
        case "flt " where d.count >= 4:
            return Double(d.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "ui8 ", "flag": return d.first.map(Double.init)
        case "ui16" where d.count >= 2: return Double(UInt16(d[0]) << 8 | UInt16(d[1]))
        case "ui32" where d.count >= 4: return Double(d.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "si8 ": return d.first.map { Double(Int8(bitPattern: $0)) }
        case "si16" where d.count >= 2: return Double(Int16(bitPattern: UInt16(d[0]) << 8 | UInt16(d[1])))
        case "sp78" where d.count >= 2: return Double(Int16(bitPattern: UInt16(d[0]) << 8 | UInt16(d[1]))) / 256
        case "fpe2" where d.count >= 2: return Double(UInt16(d[0]) << 8 | UInt16(d[1])) / 4
        case "ioft" where d.count >= 8: return Double(d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 65536
        default: return nil
        }
    }

    func write(_ key: String, _ data: [UInt8]) -> Bool {
        let k = key.fourCC
        guard let i = info(k), Int(i.dataSize) == data.count else { return false }
        var input = SMCKeyData(); input.key = k; input.keyInfo.dataSize = i.dataSize; input.data8 = 6
        withUnsafeMutableBytes(of: &input.bytes) { buf in for (n, b) in data.enumerated() { buf[n] = b } }
        return call(&input) != nil
    }

    func write(_ key: String, float v: Float) -> Bool {
        write(key, withUnsafeBytes(of: v) { Array($0) })
    }

    func allKeys() -> [String] {
        guard let n = value("#KEY") else { return [] }
        return (0..<Int(n)).compactMap { idx in
            var input = SMCKeyData(); input.data8 = 8; input.data32 = UInt32(idx)
            return call(&input).map { String(fourCC: $0.key) }
        }
    }
}
