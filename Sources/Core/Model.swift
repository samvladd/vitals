import Foundation

// The wire format between the agent (on each Mac) and the menu bar app: one JSON object per line.

let vitalsVersion = "1.1.2"

struct Fan: Codable, Equatable {
    var rpm: Double
    var min: Double
    var max: Double
    var target: Double
    var manual: Bool
}

struct Battery: Codable, Equatable {
    var percent: Double
    var charging: Bool
    var external: Bool
    var adapterWatts: Double?     // the adapter's rating
    var inWatts: Double?          // drawn from the wall right now
    var batteryWatts: Double?     // + charging, - discharging
    var cycles: Int?
    var health: Double?           // % of design capacity
    var minutesLeft: Int?
    var temp: Double?
    // Battery care (Core/Battery.swift); optional so older agents and apps still decode.
    var designMah: Int? = nil     // what it held when new
    var fullMah: Int? = nil       // what a full charge holds now
    var designCycles: Int? = nil  // the cycles it is rated for
    var minutesToFull: Int? = nil
    var minutesToEmpty: Int? = nil
    var held: Bool? = nil         // on power, not charging, not full: a charge limit or Optimized Charging holds it
}

struct Volume: Codable, Equatable {
    var name: String
    var total: Double             // bytes
    var free: Double              // bytes available, purgeable space counted as free (as Finder does)
    var boot: Bool
}

struct Proc: Codable, Equatable {
    var name: String
    var cpu: Double               // % of one core
    var mem: Double               // bytes resident
}

struct Snapshot: Codable {
    var v: String = vitalsVersion
    var t: Double = 0
    var root = false              // the agent can write to the fans

    // CPU
    var cpu: Double?              // % of the whole chip
    var cores: [Double] = []      // % per core, efficiency cores first
    var eCores = 0
    var load: [Double] = []

    // Memory, bytes
    var memTotal: Double = 0
    var memUsed: Double = 0
    var memApp: Double = 0
    var memWired: Double = 0
    var memCompressed: Double = 0
    var memCached: Double = 0
    var swapUsed: Double = 0
    var swapTotal: Double = 0
    var pressure = 1              // 1 normal, 2 warning, 4 critical
    var thermal = 0               // 0 nominal, 1 fair, 2 serious, 3 critical

    // Temperatures, °C
    var tCPU: Double?             // hottest CPU sensor
    var tCPUAvg: Double?
    var tGPU: Double?
    var tSSD: Double?

    // Power, watts
    var wSystem: Double?          // whole machine
    var wCPU: Double?
    var wGPU: Double?
    var wANE: Double?
    var wDRAM: Double?
    var gpu: Double?              // GPU busy %

    var fans: [Fan] = []
    var fanPolicy = "auto"
    var battery: Battery?

    var netIn: Double?            // bytes/s
    var netOut: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var volumes: [Volume] = []
    var procs: [Proc] = []
    var uptime: Double = 0
}

struct MachineInfo: Codable {
    var v: String = vitalsVersion
    var name: String
    var model: String
    var chip: String
    var cores: Int
    var eCores: Int
    var memory: Double
    var os: String
    var screen: String? = nil     // the Screen page's address when `screen on` (Control.swift)
    var dashboard: String? = nil  // the phone dashboard's address when it is set up (Fleet.swift)
}

/// One minute of the logger's record.
struct LogRow: Codable {
    var t: Double
    var w: Double        // mean watts
    var wMax: Double
    var cpu: Double
    var gpu: Double
    var temp: Double?    // nil: no real reading that minute
    var fan: Double
    var mem: Double      // bytes used
    var swap: Double
    var free: Double?    // bytes free on the boot volume; logged from 1.0.7
}

struct DayTotal: Codable {
    var day: String      // yyyy-MM-dd
    var wh: Double
    var peak: Double
    var minutes: Int
}

struct History: Codable {
    var rows: [LogRow]
    var days: [DayTotal]
}
