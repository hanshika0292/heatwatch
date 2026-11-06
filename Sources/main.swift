import AppKit

// Command-line helpers:
//   HeatWatch --probe                          print every sensor reading once
//   HeatWatch --report [YYYY-MM-DD] [--no-open] build a day report (default: today)
//   HeatWatch --enable-login-item              start HeatWatch automatically at login
let arguments = CommandLine.arguments

if arguments.contains("--probe") {
    let sensors = Sensors()
    _ = sensors.read()  // the first read finds the sensors and primes the CPU-load counters
    Thread.sleep(forTimeInterval: 1)
    let start = Date()
    let reading = sensors.read()
    let took = Date().timeIntervalSince(start) * 1000
    print(reading.summary)
    print("\nSensors         \(sensors.inventory)")
    print(String(format: "One reading     %.2f ms", took))
    exit(0)
}

if let flag = arguments.firstIndex(of: "--report") {
    let next = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
    let day = next.hasPrefix("--") || next.isEmpty ? Storage.day(Date()) : next
    do {
        let url = try Report.generate(day: day)
        print(url.path)
        if !arguments.contains("--no-open") { NSWorkspace.shared.open(url) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Report failed: \(error)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--enable-login-item") {
    LoginItem.enable()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
