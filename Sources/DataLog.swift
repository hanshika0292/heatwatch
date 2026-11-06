import Foundation

/// One line of the daily CSV: a 30-second window of readings.
struct LogRow {
    var secs: Int               // seconds since local midnight, at the window's end
    var cpu: Double?            // window average
    var cpuPeak: Double?        // hottest single reading in the window
    var cpuProximity: Double?
    var gpu: Double?
    var chipset: Double?
    var battery: Double?
    var palmRest: Double?
    var fan: Double?
    var fanTarget: Double?
    var fanMin: Double?
    var fanMax: Double?
    var load: Double?
    var speedLimit: Int         // lowest in the window
    var thermalState: Int       // highest in the window
    var onAC: Bool
    var coolingPad: Bool
    var topProcesses: String    // "name:cpu|name:cpu", only sampled while hot
    var pressure: Int?          // Apple silicon thermal pressure, highest in the window; nil on Intel

    /// New columns go at the end, so files started with an older header still line up.
    static let header = "time,cpu,cpu_peak,cpu_prox,gpu,chipset,battery,palm_rest,fan,fan_target,fan_min,fan_max,load,speed_limit,thermal_state,on_ac,cooling_pad,top_processes,pressure"

    /// macOS was holding the CPU back to manage heat (keep in step with slowed() in report.html).
    var isSlowed: Bool { speedLimit < 100 || (pressure ?? 0) >= 1 }

    var csvLine: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        let time = String(format: "%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
        return [time, f(cpu), f(cpuPeak), f(cpuProximity), f(gpu), f(chipset), f(battery), f(palmRest),
                f(fan), f(fanTarget), f(fanMin), f(fanMax), f(load), String(speedLimit), String(thermalState),
                onAC ? "1" : "0", coolingPad ? "1" : "0", topProcesses,
                pressure.map(String.init) ?? ""].joined(separator: ",")
    }
}

extension LogRow {
    init?(csv line: Substring, columns: [String: Int]) {
        let values = line.split(separator: ",", omittingEmptySubsequences: false)
        func s(_ name: String) -> String? { columns[name].flatMap { $0 < values.count ? String(values[$0]) : nil } }
        func d(_ name: String) -> Double? { s(name).flatMap(Double.init) }
        guard let parts = s("time")?.split(separator: ":").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        self.init(secs: parts[0] * 3600 + parts[1] * 60 + parts[2],
                  cpu: d("cpu"), cpuPeak: d("cpu_peak"), cpuProximity: d("cpu_prox"), gpu: d("gpu"),
                  chipset: d("chipset"), battery: d("battery"), palmRest: d("palm_rest"),
                  fan: d("fan"), fanTarget: d("fan_target"), fanMin: d("fan_min"), fanMax: d("fan_max"),
                  load: d("load"), speedLimit: s("speed_limit").flatMap { Int($0) } ?? 100,
                  thermalState: s("thermal_state").flatMap { Int($0) } ?? 0,
                  onAC: s("on_ac") == "1", coolingPad: s("cooling_pad") == "1",
                  topProcesses: s("top_processes") ?? "",
                  pressure: s("pressure").flatMap { Int($0) })
    }
}

/// Where logs and reports live: ~/Library/Application Support/HeatWatch
/// (or $HEATWATCH_DATA_DIR, which is handy for testing).
enum Storage {
    static let root: URL = {
        if let custom = ProcessInfo.processInfo.environment["HEATWATCH_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HeatWatch", isDirectory: true)
    }()
    static let logs = root.appendingPathComponent("logs", isDirectory: true)
    static let reports = root.appendingPathComponent("reports", isDirectory: true)

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ date: Date) -> String { dayFormat.string(from: date) }
    static func date(_ day: String) -> Date? { dayFormat.date(from: day) }

    static func secondsSinceMidnight(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    static func logURL(_ day: String) -> URL { logs.appendingPathComponent("\(day).csv") }
    static func reportURL(_ day: String) -> URL { reports.appendingPathComponent("heat-report-\(day).html") }

    /// Days with a log file, newest first.
    static func loggedDays() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
        return names.filter { $0.hasSuffix(".csv") }.map { String($0.dropLast(4)) }.sorted(by: >)
    }

    static func rows(for day: String) -> [LogRow] {
        guard let text = try? String(contentsOf: logURL(day), encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n")
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().split(separator: ",").map(String.init)
        let columns = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return lines.compactMap { LogRow(csv: $0, columns: columns) }
    }

    private static var headerChecked: Set<String> = []

    /// A file started by an older HeatWatch has fewer columns. Older rows simply lack the
    /// new trailing fields, so swapping in the new header is all it takes.
    private static func upgradeHeader(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let end = text.firstIndex(of: "\n") else { return }
        let header = text[..<end]
        guard header != LogRow.header, LogRow.header.hasPrefix(header + ",") else { return }
        try (LogRow.header + text[end...]).write(to: url, atomically: true, encoding: .utf8)
    }

    static func append(_ row: LogRow, day: String) {
        let url = logURL(day)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                try (LogRow.header + "\n").write(to: url, atomically: true, encoding: .utf8)
            } else if !headerChecked.contains(day) {
                try upgradeHeader(url)
            }
            headerChecked.insert(day)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((row.csvLine + "\n").utf8))
        } catch {
            NSLog("HeatWatch: couldn't write log: \(error)")
        }
    }
}

/// Collects readings into 30-second windows and turns each into one log row,
/// so the log stays small (about 2,900 rows a day) however often the menu refreshes.
final class Recorder {
    let interval: TimeInterval = 30
    /// Busiest processes seen during the current window (only sampled while hot).
    var hotProcesses: [ProcessSample] = []
    private var window: [Reading] = []
    private var windowStart: Date?

    func add(_ reading: Reading, coolingPad: Bool, refresh: TimeInterval) -> [(day: String, row: LogRow)] {
        var rows: [(day: String, row: LogRow)] = []
        // A long silence means the Mac slept; close the old window where it stopped.
        if let last = window.last, reading.date.timeIntervalSince(last.date) > max(refresh * 3, 60) {
            rows += flush(coolingPad: coolingPad)
            windowStart = nil
        }
        let start = windowStart ?? reading.date.addingTimeInterval(-refresh)
        windowStart = start
        window.append(reading)
        if reading.date.timeIntervalSince(start) >= interval - refresh / 2 {
            rows += flush(coolingPad: coolingPad)
        }
        return rows
    }

    /// Closes the current window now (also used on quit and when the cooling pad is toggled).
    func flush(coolingPad: Bool) -> [(day: String, row: LogRow)] {
        guard let last = window.last else { return [] }
        func average(_ value: (Reading) -> Double?) -> Double? {
            let values = window.compactMap(value)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let top = hotProcesses.map { p -> String in
            let name = p.name.replacingOccurrences(of: "[,|:\\n]", with: " ", options: .regularExpression)
            return "\(name):\(Int(p.cpu.rounded()))"
        }
        let row = LogRow(secs: Storage.secondsSinceMidnight(last.date),
                         cpu: average { $0.cpu },
                         cpuPeak: window.compactMap(\.cpu).max(),
                         cpuProximity: average { $0.cpuProximity },
                         gpu: average { $0.gpu },
                         chipset: average { $0.chipset },
                         battery: average { $0.battery },
                         palmRest: average { $0.palmRest },
                         fan: average { $0.fan?.actual },
                         fanTarget: average { $0.fan?.target },
                         fanMin: last.fan?.min,
                         fanMax: last.fan?.max,
                         load: average { $0.load },
                         speedLimit: window.map(\.speedLimit).min() ?? 100,
                         thermalState: window.map(\.thermalState).max() ?? 0,
                         onAC: last.onAC,
                         coolingPad: coolingPad,
                         topProcesses: top.joined(separator: "|"),
                         pressure: window.compactMap(\.pressure).max())
        window.removeAll()
        hotProcesses = []
        windowStart = last.date
        return [(Storage.day(last.date), row)]
    }
}

struct WeightedMean {
    private(set) var sum = 0.0
    private(set) var weight = 0.0

    mutating func add(_ value: Double?, weight w: Double) {
        guard let value else { return }
        sum += value * w
        weight += w
    }

    var value: Double? { weight > 0 ? sum / weight : nil }
}

/// Running totals for one day. The report page repeats this arithmetic in
/// JavaScript, so keep the two in step.
struct DayStats {
    private(set) var minutes = 0.0
    private(set) var hotMinutes = 0.0
    private(set) var throttledMinutes = 0.0
    private(set) var coolingPadMinutes = 0.0
    private(set) var peak: Double?
    private(set) var peakSecs: Int?
    private var cpu = WeightedMean()
    private var lastSecs: Int?

    var averageCPU: Double? { cpu.value }

    /// How long a row stands for: the gap since the previous row, or a single
    /// 30-second window after a break (sleep, or HeatWatch not running).
    static func rowMinutes(_ secs: Int, after previous: Int?) -> Double {
        guard let previous, secs > previous, secs - previous <= 90 else { return 0.5 }
        return Double(secs - previous) / 60
    }

    mutating func add(_ row: LogRow) {
        let m = Self.rowMinutes(row.secs, after: lastSecs)
        lastSecs = row.secs
        minutes += m
        cpu.add(row.cpu, weight: m)
        if let c = row.cpu, c >= Thresholds.hot { hotMinutes += m }
        if row.isSlowed { throttledMinutes += m }
        if row.coolingPad { coolingPadMinutes += m }
        if let p = row.cpuPeak ?? row.cpu, p > (peak ?? -.infinity) {
            peak = p
            peakSecs = row.secs
        }
    }
}
