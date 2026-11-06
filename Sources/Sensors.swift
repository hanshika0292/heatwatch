import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import notify

enum Machine {
    /// True on Apple silicon, even if this copy is running under Rosetta.
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    /// e.g. "Apple M5 Pro" or "Intel(R) Core(TM) i5-7360U CPU @ 2.30GHz".
    static let chip = sysctlString("machdep.cpu.brand_string")
    /// e.g. "Mac17,9" or "MacBookPro14,1".
    static let model = sysctlString("hw.model")

    /// The M3 family lays out its sensors differently from every other Apple chip.
    static let isM3Family = isAppleSilicon && chip.range(of: #"\bM3\b"#, options: .regularExpression) != nil

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}

/// Temperature bands for the "CPU" number HeatWatch shows.
/// - Apple silicon: the average of every CPU sensor. Set from an M5 Pro, which idles
///   around 40–50°C and reached 68°C (hottest core 72°C) after 90 s of all 15 cores busy
///   with its fans still at minimum. Apple lets these chips run hot before it slows them.
/// - Intel: the CPU package sensor. Set from a Core i5-7360U; most Intel Mac CPUs are rated
///   to about 100°C.
enum Thresholds {
    static let warm = Machine.isAppleSilicon ? 70.0 : 75.0
    static let hot = Machine.isAppleSilicon ? 85.0 : 90.0
    static let critical = Machine.isAppleSilicon ? 95.0 : 97.0
    /// At or above this, HeatWatch notes which processes are busiest.
    static let culprit = Machine.isAppleSilicon ? 80.0 : 85.0
    /// Usual CPU temperature at light load (under 15% CPU), and where idle starts to look wrong.
    static let idleNormal = Machine.isAppleSilicon ? 35.0...55.0 : 40.0...60.0
    static let idleWarm = Machine.isAppleSilicon ? 60.0 : 62.0
    static let idleHot = 70.0
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

    /// Apple silicon MacBook Pros switch their fans off entirely when cool.
    var isOff: Bool { actual < 100 }
}

/// macOS's thermal pressure on Apple silicon. Above nominal, macOS is lowering the
/// chip's power to cool it down: the Apple-silicon version of Intel's CPU speed cap.
enum ThermalPressure {
    static let names = ["Nominal", "Moderate", "Heavy", "Trapping", "Sleeping"]
    static func name(_ level: Int) -> String { names[min(max(level, 0), names.count - 1)] }
}

struct Reading {
    var date: Date
    /// Intel: the CPU package sensor. Apple silicon: the average of all CPU sensors.
    var cpu: Double?
    /// The hottest single CPU sensor.
    var cpuCores: Double?
    var cpuProximity: Double?   // Intel only
    var gpu: Double?
    var chipset: Double?        // Intel only
    var ssd: Double?
    var battery: Double?
    var palmRest: Double?
    var fans: [Fan]
    var load: Double?
    /// macOS's CPU speed cap in percent (Intel); below 100 means the CPU is being held back.
    var speedLimit: Int
    /// Apple silicon thermal pressure, 0 nominal … 4 sleeping (see ThermalPressure). nil on Intel.
    var pressure: Int?
    /// ProcessInfo.ThermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
    var thermalState: Int
    var onAC: Bool

    /// All fans as one: the average speed, so a two-fan MacBook Pro logs one number.
    var fan: Fan? {
        guard !fans.isEmpty else { return nil }
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return Fan(actual: mean(fans.map(\.actual)) ?? 0, target: mean(fans.compactMap(\.target)),
                   min: fans.compactMap(\.min).max(), max: fans.compactMap(\.max).max())
    }

    /// True when macOS is holding the CPU back to manage heat.
    var isSlowed: Bool { speedLimit < 100 || (pressure ?? 0) >= 1 }
}

/// Reads every sensor HeatWatch shows. One call costs well under a millisecond.
final class Sensors {
    private let smc = SMC()
    private let host = mach_host_self()
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var pressureToken: Int32?

    // Intel: sensor keys differ between models; use the first one this Mac reports.
    private lazy var intelCPUKey = ["TCXC", "TC0D", "TC0E", "TC0F", "TCAD", "TC0P"].first { temperature($0) != nil }
    private lazy var intelGPUKey = ["TCGC", "TG0D", "TGDD", "TG0P"].first { temperature($0) != nil }
    private lazy var intelCoreKeys = (0...9).flatMap { ["TC\($0)C", "TC\($0)c"] }.filter { temperature($0) != nil }

    /// Apple silicon has dozens of per-core sensors and their keys change with every chip,
    /// so list the SMC's keys once and keep each family:
    /// - M1, M2, M4, M5 and later: "Tp"/"Te" are CPU cores, "Tg" is the GPU. (On an M5 Pro
    ///   all 23 "Tp" sensors rise under CPU load.)
    /// - M3 family: "Te" are efficiency cores, "Tf0x"/"Tf4x" performance cores and
    ///   "Tf1x"/"Tf2x" the GPU.
    /// Key families follow the sensor tables in Stats (github.com/exelban/stats).
    /// Each read takes about 0.2 ms on Apple silicon, so the GPU's dozens of near-identical
    /// sensors are thinned to 8 spread across it. Every CPU sensor is kept, for a true hottest core.
    private lazy var siliconKeys: (cpu: [String], gpu: [String]) = {
        let keys = (smc?.allKeys() ?? []).filter { $0.hasPrefix("T") }
        func family(_ prefixes: [String]) -> [String] {
            keys.filter { key in prefixes.contains { key.hasPrefix($0) } && temperature(key) != nil }
        }
        let cpu = Machine.isM3Family ? family(["Te", "Tf0", "Tf4"]) : family(["Tp", "Te"])
        let gpu = Machine.isM3Family ? family(["Tf1", "Tf2"]) : family(["Tg"])
        let step = max(1, Int((Double(gpu.count) / 8).rounded(.up)))
        return (cpu, stride(from: 0, to: gpu.count, by: step).map { gpu[$0] })
    }()

    /// Fan count and speed range don't change, so they're read once.
    private lazy var fanRanges: [(min: Double?, max: Double?)] = {
        guard let smc, let count = smc.read("FNum"), count > 0, count < 10 else { return [] }
        return (0..<Int(count)).map { (smc.read("F\($0)Mn"), smc.read("F\($0)Mx")) }
    }()

    init() {
        if Machine.isAppleSilicon {
            var token: Int32 = 0
            if notify_register_check("com.apple.system.thermalpressurelevel", &token) == 0 { pressureToken = token }
        }
    }

    deinit { if let pressureToken { notify_cancel(pressureToken) } }

    /// One line for `--probe`: which sensors were found.
    var inventory: String {
        if Machine.isAppleSilicon {
            return "\(Machine.chip) (\(Machine.model)) · \(siliconKeys.cpu.count) CPU sensors, \(siliconKeys.gpu.count) GPU sensors, \(fanRanges.count) fans"
        }
        return "\(Machine.chip) (\(Machine.model)) · CPU key \(intelCPUKey ?? "none"), \(intelCoreKeys.count) core sensors, \(fanRanges.count) fans"
    }

    func read() -> Reading {
        let cpu: Double?, hottest: Double?, gpu: Double?
        if Machine.isAppleSilicon {
            let cores = siliconKeys.cpu.compactMap(temperature)
            cpu = Self.mean(cores)
            hottest = cores.max()
            gpu = Self.mean(siliconKeys.gpu.compactMap(temperature))
        } else {
            cpu = intelCPUKey.flatMap(temperature)
            hottest = intelCoreKeys.compactMap(temperature).max()
            gpu = intelGPUKey.flatMap(temperature)
        }
        return Reading(date: Date(),
                       cpu: cpu,
                       cpuCores: hottest,
                       cpuProximity: temperature("TC0P"),
                       gpu: gpu,
                       chipset: temperature("TPCD"),
                       ssd: temperature("TH0x"),
                       battery: temperature("TB0T"),
                       palmRest: temperature("Ts0P"),
                       fans: fans(),
                       load: cpuLoad(),
                       speedLimit: speedLimit(),
                       pressure: thermalPressure(),
                       thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                       onAC: onACPower())
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func temperature(_ key: String) -> Double? {
        // Missing sensors report placeholders like -127°C.
        guard let value = smc?.read(key), value > 0, value < 130 else { return nil }
        return value
    }

    private func fans() -> [Fan] {
        guard let smc else { return [] }
        return fanRanges.enumerated().compactMap { i, range in
            guard let actual = smc.read("F\(i)Ac") else { return nil }
            return Fan(actual: max(actual, 0), target: smc.read("F\(i)Tg"), min: range.min, max: range.max)
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

    /// Intel only; Apple silicon doesn't report a speed cap (see thermalPressure).
    private func speedLimit() -> Int {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyCPUPowerStatus(&status) == kIOReturnSuccess,
              let info = status?.takeRetainedValue() as? [String: Any],
              let limit = info["CPU_Speed_Limit"] as? Int else { return 100 }
        return limit
    }

    private func thermalPressure() -> Int? {
        guard let pressureToken else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(pressureToken, &state) == 0 else { return nil }
        return Int(state)
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
            Machine.isAppleSilicon ? "CPU average     \(t(cpu))" : "CPU package     \(t(cpu))",
            "Hottest core    \(t(cpuCores))",
            "GPU             \(t(gpu))",
        ]
        if Machine.isAppleSilicon {
            lines.append("SSD             \(t(ssd))")
        } else {
            lines += ["CPU proximity   \(t(cpuProximity))", "Chipset         \(t(chipset))"]
        }
        lines += ["Battery         \(t(battery))", "Palm rest       \(t(palmRest))"]
        for (i, f) in fans.enumerated() {
            lines.append(String(format: "Fan %d           %.0f rpm (target %.0f, range %.0f–%.0f)",
                                i + 1, f.actual, f.target ?? 0, f.min ?? 0, f.max ?? 0))
        }
        if fans.isEmpty { lines.append("Fan             none reported") }
        lines.append("CPU load        \(load.map { String(format: "%.0f%%", $0) } ?? "n/a")")
        if let pressure {
            lines.append("Thermal pressure \(ThermalPressure.name(pressure).lowercased())")
        } else {
            lines.append("CPU speed cap   \(speedLimit)%")
        }
        lines.append("Thermal state   \(["nominal", "fair", "serious", "critical"][min(max(thermalState, 0), 3)])")
        lines.append("Power           \(onAC ? "plugged in" : "battery")")
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
