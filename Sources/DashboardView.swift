import AppKit

struct HistoryPoint {
    let date: Date
    let cpu: Double?
    let fan: Double?
    let load: Double?
}

enum Palette {
    static let cpu = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let fan = dynamic(light: 0x1baf7a, dark: 0x199e70)
    static let load = dynamic(light: 0x898781, dark: 0x9c9a92)

    static func status(_ level: HeatLevel) -> NSColor {
        rgb([0x0ca30c, 0xfab219, 0xec835a, 0xd03b3b][level.rawValue])
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// The live panel at the top of the menu: current readings, the last 30 minutes
/// as sparklines, today's running totals and the busiest processes. It only
/// redraws while the menu is open.
final class DashboardView: NSView {
    static let historySpan: TimeInterval = 30 * 60

    var reading: Reading?
    var history: [HistoryPoint] = []
    var today = DayStats()
    /// nil while `ps` is still running.
    var busiest: [ProcessSample]?

    private enum Layout {
        static let width: CGFloat = 300
        static let inset: CGFloat = 14
        static let header: CGFloat = 70
        static let sparkline: CGFloat = 58
        static let gridRow: CGFloat = 18
        static let gridRows = 5
        static let today: CGFloat = 48
        static let busiest: CGFloat = 16 + 3 * 17
        static let rule: CGFloat = 13
        static let height = 10 + header + sparkline * 2 + rule + gridRow * CGFloat(gridRows)
            + rule + today + rule + busiest + 6
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let x = Layout.inset, width = bounds.width - Layout.inset * 2, half = width / 2
        let r = reading
        var y: CGFloat = 10

        // Header: CPU on the left, fan on the right (GPU on a fanless Mac such as a MacBook Air).
        let fanless = r?.fans.isEmpty == true
        caption("CPU", x: x, y: y, width: half)
        caption(fanless ? "GPU" : (r?.fans.count ?? 0) > 1 ? "FANS" : "FAN", x: x + half, y: y, width: half)
        y += 15
        bigValue(r?.cpu.map { "\(Int($0.rounded()))" } ?? "--", unit: "°C", x: x, y: y)
        if fanless {
            bigValue(r?.gpu.map { "\(Int($0.rounded()))" } ?? "--", unit: "°C", x: x + half, y: y)
        } else if let fan = r?.fan, fan.isOff {
            bigValue("Off", unit: "", x: x + half, y: y)
        } else if let fan = r?.fan {
            bigValue(Self.grouped(fan.actual), unit: " rpm", x: x + half, y: y)
        } else {
            bigValue("--", unit: "", x: x + half, y: y)
        }
        y += 32
        let level = HeatLevel(r?.cpu)
        Palette.status(level).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y + 3.5, width: 8, height: 8)).fill()
        var status = level.label
        if r?.isSlowed == true { status += " · slowed" }
        text(status, in: NSRect(x: x + 13, y: y, width: half - 13, height: 16), size: 11.5, color: .secondaryLabelColor)
        if fanless {
            text("No fan on this Mac", in: NSRect(x: x + half, y: y, width: half, height: 16), size: 11.5, color: .secondaryLabelColor)
        } else if let fan = r?.fan, fan.isOff {
            text("Spin up when needed", in: NSRect(x: x + half, y: y, width: half, height: 16), size: 11.5, color: .secondaryLabelColor)
        } else if let fan = r?.fan, let max = fan.max, max > 0 {
            text("\(Int((fan.actual / max * 100).rounded()))% of max (\(Self.grouped(max)))",
                 in: NSRect(x: x + half, y: y, width: half, height: 16), size: 11.5, color: .secondaryLabelColor)
        }
        y += 23

        // Last 30 minutes.
        y = sparkline("CPU temperature · last 30 min", values: history.map { ($0.date, $0.cpu) },
                      range: 30...105, reference: Thresholds.hot, color: Palette.cpu,
                      format: { "\(Int($0.rounded()))°" }, x: x, y: y, width: width)
        if fanless {
            y = sparkline("CPU load · last 30 min", values: history.map { ($0.date, $0.load) },
                          range: 0...100, reference: nil, color: Palette.load,
                          format: { "\(Int($0.rounded()))%" }, x: x, y: y, width: width)
        } else {
            y = sparkline("Fan speed · last 30 min", values: history.map { ($0.date, $0.fan) },
                          range: 0...(r?.fan?.max ?? 7200), reference: nil, color: Palette.fan,
                          format: { Self.grouped($0) }, x: x, y: y, width: width)
        }
        y = rule(at: y, x: x, width: width)

        // Every sensor.
        let cells: [(String, String)] = [
            ("Hottest core", Self.degrees(r?.cpuCores)), ("Palm rest", Self.degrees(r?.palmRest)),
            ("GPU", Self.degrees(r?.gpu)), ("Battery", Self.degrees(r?.battery)),
            r?.chipset != nil ? ("Chipset", Self.degrees(r?.chipset)) : ("SSD", Self.degrees(r?.ssd)),
            ("CPU load", r?.load.map { "\(Int($0.rounded()))%" } ?? "--"),
            ((r?.fans.count ?? 0) > 1 ? "Fans" : "Fan",
             r.map(Self.fanSpeeds) ?? "--"),
            ("Power", r.map { $0.onAC ? "Plugged in" : "Battery" } ?? "--"),
            ("CPU speed", r.map(Self.cpuSpeed) ?? "--"),
            ("Thermal", r.map { ["Nominal", "Fair", "Serious", "Critical"][min(max($0.thermalState, 0), 3)] } ?? "--"),
        ]
        let column = (width - 16) / 2
        for (i, cell) in cells.enumerated() {
            let cellRect = NSRect(x: x + CGFloat(i % 2) * (column + 16), y: y + CGFloat(i / 2) * Layout.gridRow,
                                  width: column, height: Layout.gridRow)
            text(cell.0, in: cellRect, size: 12, color: .secondaryLabelColor)
            text(cell.1, in: cellRect, size: 12, align: .right, digits: true)
        }
        y += Layout.gridRow * CGFloat(Layout.gridRows)
        y = rule(at: y, x: x, width: width)

        // Today so far.
        caption("TODAY", x: x, y: y, width: width)
        text("\(Self.duration(today.minutes)) logged", in: NSRect(x: x, y: y, width: width, height: 14),
             size: 11, color: .tertiaryLabelColor, align: .right, digits: true)
        y += 15
        var peak = "Peak \(Self.degrees(today.peak))"
        if let secs = today.peakSecs { peak += " at \(Self.clock(secs))" }
        text("Avg \(Self.degrees(today.averageCPU)) · \(peak)", in: NSRect(x: x, y: y, width: width, height: 16),
             size: 12, digits: true)
        y += 16
        text("\(Int(Thresholds.hot))°C+ for \(Self.duration(today.hotMinutes)) · CPU slowed \(Self.duration(today.throttledMinutes))",
             in: NSRect(x: x, y: y, width: width, height: 16), size: 11.5, color: .secondaryLabelColor, digits: true)
        y += Layout.today - 31
        y = rule(at: y, x: x, width: width)

        // What's using the CPU.
        caption("BUSIEST RIGHT NOW", x: x, y: y, width: width)
        y += 16
        if let busiest {
            if busiest.isEmpty {
                text("Nothing is using much CPU", in: NSRect(x: x, y: y, width: width, height: 16), size: 12, color: .secondaryLabelColor)
            }
            for process in busiest.prefix(3) {
                let rowRect = NSRect(x: x, y: y, width: width, height: 16)
                text("\(Int(process.cpu.rounded()))% CPU", in: rowRect, size: 12, color: .secondaryLabelColor, align: .right, digits: true)
                text(process.name, in: NSRect(x: x, y: y, width: width - 80, height: 16), size: 12)
                y += 17
            }
        } else {
            text("Checking…", in: NSRect(x: x, y: y, width: width, height: 16), size: 12, color: .secondaryLabelColor)
        }
    }

    // MARK: - Drawing helpers

    private func sparkline(_ title: String, values: [(Date, Double?)], range: ClosedRange<Double>, reference: Double?,
                           color: NSColor, format: (Double) -> String, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        text(title, in: NSRect(x: x, y: y, width: width * 0.68, height: 14), size: 11, color: .secondaryLabelColor)
        let present = values.compactMap(\.1)
        if let lo = present.min(), let hi = present.max() {
            text("\(format(lo))–\(format(hi))", in: NSRect(x: x + width * 0.5, y: y, width: width * 0.5, height: 14),
                 size: 11, color: .tertiaryLabelColor, align: .right, digits: true)
        }
        let chart = NSRect(x: x, y: y + 17, width: width, height: 32)
        let start = Date().addingTimeInterval(-Self.historySpan)
        func px(_ date: Date) -> CGFloat { chart.minX + CGFloat(date.timeIntervalSince(start) / Self.historySpan) * chart.width }
        func py(_ value: Double) -> CGFloat {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            return chart.maxY - CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound)) * chart.height
        }

        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: chart.minX, y: chart.maxY - 1, width: chart.width, height: 1)).fill()
        if let reference {
            NSBezierPath(rect: NSRect(x: chart.minX, y: py(reference).rounded(), width: chart.width, height: 1)).fill()
        }

        // Split at gaps (sleep) so the line doesn't bridge them.
        var segments: [[NSPoint]] = [[]]
        var previous: Date?
        for (date, value) in values {
            if let previous, date.timeIntervalSince(previous) > 45, !(segments.last?.isEmpty ?? true) { segments.append([]) }
            previous = date
            guard let value, date >= start else { continue }
            segments[segments.count - 1].append(NSPoint(x: px(date), y: py(value)))
        }
        for points in segments where points.count > 1 {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: points[0].x, y: chart.maxY))
            points.forEach { area.line(to: $0) }
            area.line(to: NSPoint(x: points[points.count - 1].x, y: chart.maxY))
            area.close()
            color.withAlphaComponent(0.12).setFill()
            area.fill()

            let line = NSBezierPath()
            line.lineWidth = 2
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.move(to: points[0])
            points.dropFirst().forEach { line.line(to: $0) }
            color.setStroke()
            line.stroke()
        }
        if let last = segments.last?.last {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)).fill()
        }
        return y + Layout.sparkline
    }

    private func rule(at y: CGFloat, x: CGFloat, width: CGFloat) -> CGFloat {
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: x, y: y + 5, width: width, height: 1)).fill()
        return y + Layout.rule
    }

    private func caption(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ]
        (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 14), withAttributes: attributes)
    }

    private func bigValue(_ value: String, unit: String, x: CGFloat, y: CGFloat) {
        let number = NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.labelColor])
        number.draw(at: NSPoint(x: x, y: y))
        let unitText = NSAttributedString(string: unit, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        unitText.draw(at: NSPoint(x: x + number.size().width + 1, y: y + 13))
    }

    private func text(_ string: String, in rect: NSRect, size: CGFloat, color: NSColor = .labelColor,
                      align: NSTextAlignment = .left, digits: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        (string as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    // MARK: - Formatting

    /// Each fan's speed, or "Off" when they're all stopped.
    static func fanSpeeds(_ r: Reading) -> String {
        if r.fans.isEmpty { return "None" }
        if r.fans.allSatisfy(\.isOff) { return "Off" }
        return r.fans.map { $0.isOff ? "Off" : grouped($0.actual) }.joined(separator: " · ")
    }

    /// Full speed, Intel's speed cap, or how hard macOS is holding Apple silicon back.
    static func cpuSpeed(_ r: Reading) -> String {
        if r.speedLimit < 100 { return "\(r.speedLimit)%" }
        if let p = r.pressure, p >= 1 { return "Limited" }
        return "Full"
    }

    static func degrees(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°C" } ?? "--" }

    static func grouped(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
    }

    static func clock(_ secs: Int) -> String { String(format: "%02d:%02d", secs / 3600, secs / 60 % 60) }

    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}
