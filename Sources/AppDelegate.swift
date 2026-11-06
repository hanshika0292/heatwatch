// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Hanshika Gupta. See LICENSE.

import AppKit

/// Starts HeatWatch at login via a per-user LaunchAgent.
enum LoginItem {
    static let label = "local.heatwatch"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func enable() {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: NSDictionary = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // restart after a crash, not after Quit
            "LimitLoadToSessionType": "Aqua",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.write(to: plistURL)
    }

    static func disable() { try? FileManager.default.removeItem(at: plistURL) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Key {
        static let refresh = "refreshInterval"
        static let showFan = "showFanInMenuBar"
        static let reportHour = "reportHour"
        static let coolingPad = "coolingPad"
        static let lastReport = "lastAutoReportDay"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sensors = Sensors()
    private let recorder = Recorder()
    private let dashboard = DashboardView()
    private let menu = NSMenu()
    private let pastReportsMenu = NSMenu()
    private let defaults = UserDefaults.standard
    private var padItem = NSMenuItem()
    private var loginItem = NSMenuItem()
    private var choiceItems: [(item: NSMenuItem, key: String)] = []
    private var timer: Timer?
    private var history: [HistoryPoint] = []
    private var today = DayStats()
    private var todayKey = ""
    private var menuIsOpen = false
    private var lastProcessSample = Date.distantPast
    private var terminationSignal: DispatchSourceSignal?

    private var refreshInterval: TimeInterval { defaults.double(forKey: Key.refresh) }
    private var reportHour: Int { defaults.integer(forKey: Key.reportHour) }
    private var coolingPad: Bool { defaults.bool(forKey: Key.coolingPad) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: [Key.refresh: 5.0, Key.showFan: true, Key.reportHour: 21, Key.coolingPad: false])
        todayKey = Storage.day(Date())
        Storage.rows(for: todayKey).forEach { today.add($0) }

        buildMenu()
        tick()
        restartTimer()
        openMissedReport()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)

        // launchd stops agents with SIGTERM (logout, reinstall); quit normally so the last window is saved.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.flush(coolingPad: coolingPad).forEach { Storage.append($0.row, day: $0.day) }
    }

    // MARK: - Sampling

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = refreshInterval * 0.2   // lets macOS batch wake-ups to save energy
        RunLoop.main.add(t, forMode: .common)  // keep updating while the menu is open
        timer = t
    }

    private func tick() {
        let reading = sensors.read()
        history.append(HistoryPoint(date: reading.date, cpu: reading.cpu, fan: reading.fan?.actual, load: reading.load))
        history.removeAll { reading.date.timeIntervalSince($0.date) > DashboardView.historySpan }

        // While it's hot, note what's running (once per log row).
        if let cpu = reading.cpu, cpu >= Thresholds.culprit,
           reading.date.timeIntervalSince(lastProcessSample) >= recorder.interval {
            lastProcessSample = reading.date
            ProcessSampler.top { [weak self] in self?.recorder.hotProcesses = $0 }
        }
        record(recorder.add(reading, coolingPad: coolingPad, refresh: refreshInterval))

        updateStatusTitle(reading)
        dashboard.reading = reading
        dashboard.history = history
        dashboard.today = today
        if menuIsOpen { dashboard.needsDisplay = true }
        openScheduledReport(now: reading.date)
    }

    private func record(_ rows: [(day: String, row: LogRow)]) {
        for (day, row) in rows {
            Storage.append(row, day: day)
            if day != todayKey {
                todayKey = day
                today = DayStats()
            }
            today.add(row)
        }
    }

    private func updateStatusTitle(_ reading: Reading) {
        var title = reading.cpu.map { "\(Int($0.rounded()))°" } ?? "--°"
        if defaults.bool(forKey: Key.showFan), let fan = reading.fan {
            title += "  \(Int(fan.actual.rounded())) rpm"
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]
        switch HeatLevel(reading.cpu) {
        case .critical: attributes[.foregroundColor] = NSColor.systemRed
        case .hot: attributes[.foregroundColor] = NSColor.systemOrange
        default: break
        }
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    @objc private func didWake() { openMissedReport() }

    // MARK: - Reports

    private func openScheduledReport(now: Date) {
        guard reportHour >= 0, Calendar.current.component(.hour, from: now) >= reportHour,
              defaults.string(forKey: Key.lastReport) != todayKey, today.minutes >= 30 else { return }
        defaults.set(todayKey, forKey: Key.lastReport)
        openReport(day: todayKey)
    }

    /// If the Mac was asleep or off at report time yesterday, open that report now.
    private func openMissedReport() {
        guard reportHour >= 0, let date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }
        let yesterday = Storage.day(date)
        guard (defaults.string(forKey: Key.lastReport) ?? "") < yesterday,
              Storage.rows(for: yesterday).count >= 60 else { return }
        defaults.set(yesterday, forKey: Key.lastReport)
        openReport(day: yesterday)
    }

    private func openReport(day: String) {
        do {
            NSWorkspace.shared.open(try Report.generate(day: day))
        } catch {
            NSLog("HeatWatch: couldn't build the report for \(day): \(error)")
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        let dashboardItem = NSMenuItem()
        dashboardItem.view = dashboard
        menu.addItem(dashboardItem)
        menu.addItem(.separator())

        padItem = item("Using Cooling Pad", #selector(toggleCoolingPad), key: "p")
        menu.addItem(padItem)
        menu.addItem(.separator())

        menu.addItem(item("Open Today's Report", #selector(openTodaysReport), key: "r"))
        let past = NSMenuItem(title: "Past Reports", action: nil, keyEquivalent: "")
        pastReportsMenu.delegate = self
        past.submenu = pastReportsMenu
        menu.addItem(past)
        menu.addItem(item("Show Data Folder", #selector(showDataFolder)))
        menu.addItem(.separator())

        let settings = NSMenu()
        settings.addItem(choices("Menu Bar Shows", key: Key.showFan, action: #selector(setMenuBarStyle(_:)),
                                 options: [("Temperature and Fan Speed", true), ("Temperature Only", false)]))
        settings.addItem(choices("Update Every", key: Key.refresh, action: #selector(setRefresh(_:)),
                                 options: [("2 Seconds", 2.0), ("5 Seconds", 5.0), ("10 Seconds", 10.0)]))
        settings.addItem(choices("Open Daily Report At", key: Key.reportHour, action: #selector(setReportHour(_:)),
                                 options: (18...23).map { ("\($0 - 12) PM", $0) } + [("Never (Open It From the Menu)", -1)]))
        settings.addItem(.separator())
        loginItem = item("Launch at Login", #selector(toggleLaunchAtLogin))
        settings.addItem(loginItem)
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(item("Quit HeatWatch", #selector(quit), key: "q"))

        statusItem.menu = menu
        markSettings()
    }

    private func item(_ title: String, _ action: Selector, key: String = "", value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = value
        return item
    }

    private func choices(_ title: String, key: String, action: Selector, options: [(String, Any)]) -> NSMenuItem {
        let submenu = NSMenu()
        for (label, value) in options {
            let option = item(label, action, value: value)
            submenu.addItem(option)
            choiceItems.append((option, key))
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func markSettings() {
        for (item, key) in choiceItems {
            let current = defaults.object(forKey: key) as? NSObject
            item.state = current?.isEqual(item.representedObject) == true ? .on : .off
        }
        padItem.state = coolingPad ? .on : .off
        loginItem.state = LoginItem.isEnabled ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = true
        markSettings()
        dashboard.busiest = nil
        dashboard.needsDisplay = true
        ProcessSampler.top(minimumCPU: 1) { [weak self] processes in
            self?.dashboard.busiest = processes
            self?.dashboard.needsDisplay = true
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuIsOpen = false }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === pastReportsMenu else { return }
        menu.removeAllItems()
        let days = Storage.loggedDays().prefix(14)
        if days.isEmpty {
            let empty = NSMenuItem(title: "No Data Yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for day in days {
            menu.addItem(item(Self.dayLabel(day), #selector(openPastReport(_:)), value: day))
        }
    }

    private static func dayLabel(_ day: String) -> String {
        guard let date = Storage.date(day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    // MARK: - Actions

    @objc private func toggleCoolingPad() {
        // Close the current window first so no log row mixes pad-on and pad-off time.
        record(recorder.flush(coolingPad: coolingPad))
        defaults.set(!coolingPad, forKey: Key.coolingPad)
        markSettings()
    }

    @objc private func openTodaysReport() { openReport(day: Storage.day(Date())) }

    @objc private func openPastReport(_ sender: NSMenuItem) {
        if let day = sender.representedObject as? String { openReport(day: day) }
    }

    @objc private func showDataFolder() {
        try? FileManager.default.createDirectory(at: Storage.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Storage.root)
    }

    @objc private func setMenuBarStyle(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject, forKey: Key.showFan)
        if let reading = dashboard.reading { updateStatusTitle(reading) }
    }

    @objc private func setRefresh(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject, forKey: Key.refresh)
        restartTimer()
    }

    @objc private func setReportHour(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject, forKey: Key.reportHour)
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.isEnabled ? LoginItem.disable() : LoginItem.enable()
        markSettings()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
