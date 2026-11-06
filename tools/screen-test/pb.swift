// pb: this Mac's whole clipboard for the end-to-end test, every item and every type, not only its text.
// e2e.py compiles it into its temp folder (swiftc -o pb pb.swift) and uses it to put the clipboard back
// exactly as it was, pictures and rich text included, and to set or read one type for a test.
//
//   pb save FILE            every item's every type, to FILE (a property list)
//   pb restore FILE         the clipboard as saved
//   pb set TYPE=FILE ...    one item with these types (each from a file); prints the change count
//   pb get TYPE             that type's bytes to stdout (exit 1 when absent)
//   pb types                the types on the clipboard, one a line
//   pb count                the change count
import AppKit

let pb = NSPasteboard.general
let a = CommandLine.arguments.dropFirst()

func items() -> [[String: Data]] {
    (pb.pasteboardItems ?? []).map { item in
        var d: [String: Data] = [:]
        for t in item.types { if let v = item.data(forType: t) { d[t.rawValue] = v } }
        return d
    }
}

func put(_ list: [[String: Data]]) {
    pb.clearContents()
    let objs = list.map { d -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (t, v) in d { item.setData(v, forType: NSPasteboard.PasteboardType(t)) }
        return item
    }
    if !objs.isEmpty { pb.writeObjects(objs) }
}

switch a.first {
case "save":
    let data = try PropertyListSerialization.data(fromPropertyList: items(), format: .binary, options: 0)
    try data.write(to: URL(fileURLWithPath: a.dropFirst().first!))
case "restore":
    let data = try Data(contentsOf: URL(fileURLWithPath: a.dropFirst().first!))
    put(try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Data]] ?? [])
    print(pb.changeCount)
case "set":
    var d: [String: Data] = [:]
    for kv in a.dropFirst() {
        let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
        d[p[0]] = try Data(contentsOf: URL(fileURLWithPath: p[1]))
    }
    put([d])
    print(pb.changeCount)
case "get":
    guard let v = pb.data(forType: NSPasteboard.PasteboardType(a.dropFirst().first!)) else { exit(1) }
    FileHandle.standardOutput.write(v)
case "types": for t in pb.types ?? [] { print(t.rawValue) }
case "count": print(pb.changeCount)
default:
    FileHandle.standardError.write(Data("pb save|restore FILE, set TYPE=FILE..., get TYPE, types, count\n".utf8))
    exit(2)
}
