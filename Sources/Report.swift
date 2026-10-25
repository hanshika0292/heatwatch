import Foundation

/// Builds the self-contained HTML day report. The day's rows go into the page
/// as JSON, and Resources/report.html does the analysis and charting.
enum Report {
    enum Failure: Error { case missingTemplate }

    static func generate(day: String) throws -> URL {
        guard let template = Bundle.main.url(forResource: "report", withExtension: "html") else {
            throw Failure.missingTemplate
        }
        let week = lastSevenDays(endingOn: day)
        let rowsByDay = Dictionary(uniqueKeysWithValues: week.map { ($0, Storage.rows(for: $0)) })
        let payload: [String: Any] = [
            "day": day,
            "generatedAt": String(format: "%02d:%02d", Storage.secondsSinceMidnight(Date()) / 3600,
                                  Storage.secondsSinceMidnight(Date()) / 60 % 60),
            "machine": "\(sysctl("hw.model")) · \(sysctl("machdep.cpu.brand_string"))",
            "logPath": Storage.logURL(day).path,
            "thresholds": ["warm": Thresholds.warm, "hot": Thresholds.hot,
                           "critical": Thresholds.critical, "culprit": Thresholds.culprit],
            "today": columns(rowsByDay[day] ?? []),
            "history": week.map { summary(day: $0, rows: rowsByDay[$0] ?? []) },
            "pad": coolingPadComparison(week.map { rowsByDay[$0] ?? [] }),
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            .replacingOccurrences(of: "</", with: "<\\/")
        let html = try String(contentsOf: template, encoding: .utf8)
            .replacingOccurrences(of: "__REPORT_DATA__", with: json)
        try FileManager.default.createDirectory(at: Storage.reports, withIntermediateDirectories: true)
        let url = Storage.reportURL(day)
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The day and the six before it, oldest first.
    private static func lastSevenDays(endingOn day: String) -> [String] {
        guard let date = Storage.date(day) else { return [day] }
        return (0..<7).reversed().compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: date).map(Storage.day)
        }
    }

    /// The day's rows as columns (one array per field), which keeps the JSON compact.
    private static func columns(_ rows: [LogRow]) -> [String: Any] {
        func col(_ value: (LogRow) -> Double?) -> [Any] {
            rows.map { row -> Any in
                guard let v = value(row) else { return NSNull() }
                return (v * 10).rounded() / 10
            }
        }
        return [
            "t": rows.map(\.secs),
            "cpu": col { $0.cpu },
            "cpuPeak": col { $0.cpuPeak },
            "prox": col { $0.cpuProximity },
            "gpu": col { $0.gpu },
            "chipset": col { $0.chipset },
            "battery": col { $0.battery },
            "palm": col { $0.palmRest },
            "fan": col { $0.fan },
            "fanTarget": col { $0.fanTarget },
            "fanMax": col { $0.fanMax },
            "load": col { $0.load },
            "limit": rows.map(\.speedLimit),
            "thermal": rows.map(\.thermalState),
            "ac": rows.map { $0.onAC ? 1 : 0 },
            "pad": rows.map { $0.coolingPad ? 1 : 0 },
            "top": rows.map(\.topProcesses),
        ]
    }

    private static func summary(day: String, rows: [LogRow]) -> [String: Any] {
        var stats = DayStats()
        rows.forEach { stats.add($0) }
        return ["day": day, "minutes": stats.minutes, "avgCpu": orNull(stats.averageCPU),
                "peak": orNull(stats.peak), "peakAt": orNull(stats.peakSecs), "hotMin": stats.hotMinutes,
                "throttledMin": stats.throttledMinutes, "padMin": stats.coolingPadMinutes]
    }

    /// Average temperatures with and without the cooling pad, split by how busy
    /// the CPU was, so the pad is only compared against similar workloads.
    private static func coolingPadComparison(_ days: [[LogRow]]) -> [[String: Any]] {
        struct Bucket { var minutes = 0.0, cpu = WeightedMean(), fan = WeightedMean(), palm = WeightedMean() }
        var buckets: [String: Bucket] = [:]
        for rows in days {
            var previous: Int?
            for row in rows {
                let m = DayStats.rowMinutes(row.secs, after: previous)
                previous = row.secs
                guard let load = row.load else { continue }
                let workload = load < 15 ? "idle" : load < 50 ? "moderate" : "heavy"
                let key = "\(workload)|\(row.coolingPad ? 1 : 0)"
                var b = buckets[key, default: Bucket()]
                b.minutes += m
                b.cpu.add(row.cpu, weight: m)
                b.fan.add(row.fan, weight: m)
                b.palm.add(row.palmRest, weight: m)
                buckets[key] = b
            }
        }
        return buckets.map { key, b in
            let parts = key.split(separator: "|")
            return ["bucket": String(parts[0]), "pad": parts[1] == "1", "minutes": b.minutes,
                    "cpu": orNull(b.cpu.value), "fan": orNull(b.fan.value), "palm": orNull(b.palm.value)]
        }
    }

    private static func orNull<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
