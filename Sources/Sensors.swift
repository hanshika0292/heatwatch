import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Temperature bands for this Mac's CPU (Intel Core i5-7360U, rated to 100°C).
enum Thresholds {
    static let warm = 75.0
    static let hot = 90.0
    static let critical = 97.0
    /// At or above this, HeatWatch notes which processes are busiest.
    static let culprit = 85.0
}

enum HeatLevel: Int {
    case normal, warm, hot, critical

    init(_ cpu: Double?) {
        guard let cpu else { self = .normal; return }
        if cpu >= Thresholds.critical { self = .critical }
        else if cpu >= Thresholds.hot { self = .hot }
        else if cpu >= Thresholds.warm { self = .warm }
        else { self = .normal }
    }

    var label: String { ["Normal", "Warm", "Hot", "Very hot"][rawValue] }
}

struct Fan {
    var actual: Double
    var target: Double?
    var min: Double?
    var max: Double?
}

struct Reading {
    var date: Date
    var cpu: Double?
    var cpuCores: Double?
    var cpuProximity: Double?
    var gpu: Double?
    var chipset: Double?
    var battery: Double?
    var palmRest: Double?
    var fans: [Fan]
    var load: Double?
    /// macOS's CPU speed cap in percent; below 100 means the CPU is being held back.
    var speedLimit: Int
    /// ProcessInfo.ThermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
    var thermalState: Int
    var onAC: Bool

    var fan: Fan? { fans.first }
}

/// Reads every sensor HeatWatch shows. One call costs well under a millisecond.
final class Sensors {
    private let smc = SMC()
    private let host = mach_host_self()
    private var lastTicks: (busy: UInt64, total: UInt64)?

    // Sensor keys differ between Mac models; use the first one this Mac reports.
    private lazy var cpuKey = ["TCXC", "TC0D", "TC0E", "TC0F", "TC0P"].first { temperature($0) != nil }
    private lazy var gpuKey = ["TCGC", "TG0D", "TG0P"].first { temperature($0) != nil }
    private lazy var coreKeys = (1...8).map { "TC\($0)C" }.filter { temperature($0) != nil }

    func read() -> Reading {
        Reading(date: Date(),
                cpu: cpuKey.flatMap(temperature),
                cpuCores: coreKeys.compactMap(temperature).max(),
                cpuProximity: temperature("TC0P"),
                gpu: gpuKey.flatMap(temperature),
                chipset: temperature("TPCD"),
                battery: temperature("TB0T"),
                palmRest: temperature("Ts0P"),
                fans: fans(),
                load: cpuLoad(),
                speedLimit: speedLimit(),
                thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                onAC: onACPower())
    }

    private func temperature(_ key: String) -> Double? {
        // Missing sensors report placeholders like -127°C.
        guard let value = smc?.read(key), value > 0, value < 130 else { return nil }
        return value
    }

    private func fans() -> [Fan] {
        guard let smc, let count = smc.read("FNum"), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let actual = smc.read("F\(i)Ac") else { return nil }
            return Fan(actual: max(actual, 0), target: smc.read("F\(i)Tg"),
                       min: smc.read("F\(i)Mn"), max: smc.read("F\(i)Mx"))
        }
    }

    /// Whole-machine CPU use since the previous call, in percent.
    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks  // user, system, idle, nice
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let total = busy + UInt64(ticks.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total, busy >= last.busy else { return nil }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }

    private func speedLimit() -> Int {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyCPUPowerStatus(&status) == kIOReturnSuccess,
              let info = status?.takeRetainedValue() as? [String: Any],
              let limit = info["CPU_Speed_Limit"] as? Int else { return 100 }
        return limit
    }

    private func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == "AC Power"
    }
}

extension Reading {
    /// Plain-text dump for `HeatWatch --probe`.
    var summary: String {
        func t(_ v: Double?) -> String { v.map { String(format: "%.1f°C", $0) } ?? "n/a" }
        var lines = [
            "CPU package     \(t(cpu))",
            "CPU cores max   \(t(cpuCores))",
            "CPU proximity   \(t(cpuProximity))",
            "GPU             \(t(gpu))",
            "Chipset         \(t(chipset))",
            "Battery         \(t(battery))",
            "Palm rest       \(t(palmRest))",
        ]
        for (i, f) in fans.enumerated() {
            lines.append(String(format: "Fan %d           %.0f rpm (target %.0f, range %.0f–%.0f)",
                                i + 1, f.actual, f.target ?? 0, f.min ?? 0, f.max ?? 0))
        }
        if fans.isEmpty { lines.append("Fan             none reported") }
        lines.append("CPU load        \(load.map { String(format: "%.0f%%", $0) } ?? "n/a")")
        lines.append("CPU speed cap   \(speedLimit)%")
        lines.append("Thermal state   \(["nominal", "fair", "serious", "critical"][min(max(thermalState, 0), 3)])")
        lines.append("Power           \(onAC ? "charger" : "battery")")
        return lines.joined(separator: "\n")
    }
}

struct ProcessSample {
    let name: String
    let cpu: Double
}

enum ProcessSampler {
    /// The busiest processes right now, via a one-shot `ps` (~20 ms, only run on demand).
    /// Helper processes are merged into their app, so Chrome's renderers count as Chrome.
    static func top(limit: Int = 3, minimumCPU: Double = 5, completion: @escaping ([ProcessSample]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-Aco", "pcpu=,comm="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = FileHandle.nullDevice
            var totals: [String: Double] = [:]
            if (try? ps.run()) != nil {
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                ps.waitUntilExit()
                for line in output.split(separator: "\n") {
                    let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                    guard fields.count == 2, let cpu = Double(fields[0]) else { continue }
                    totals[displayName(String(fields[1])), default: 0] += cpu
                }
            }
            let result = totals.filter { $0.value >= minimumCPU }
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { ProcessSample(name: $0.key, cpu: $0.value) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func displayName(_ command: String) -> String {
        if let helper = command.range(of: " Helper") { return String(command[..<helper.lowerBound]) }
        if command.hasPrefix("com.apple.WebKit") { return "Safari (web pages)" }
        return command
    }
}
