# HeatWatch

A macOS menu-bar app that shows CPU temperature and fan speed on an Intel MacBook Pro, logs them all day, and writes a daily heat report.

## The problem

Intel MacBook Pros run hot under load, and macOS quietly slows the CPU to keep it under its limit. macOS doesn't show CPU temperature or fan speed anywhere in its interface, so you can't tell if the heat is normal, if the fan is keeping up, or if a fix like a cooling pad helps. HeatWatch was built for a 2017 13-inch MacBook Pro (MacBookPro14,1) after a logic-board replacement, to answer those questions with data.

## Features

**Menu bar**

- Shows the CPU temperature and fan speed, for example `72°  3380 rpm`. You can switch to temperature only.
- The text turns orange at 90°C and red at 97°C. This colour change is the only live alert. HeatWatch doesn't send notifications.

**Live panel** (click the menu-bar item)

- CPU temperature and fan speed, with a status: Normal, Warm, Hot or Very hot. It notes when macOS has slowed the CPU, and shows the fan speed as a percentage of its maximum.
- Charts of CPU temperature and fan speed for the last 30 minutes. Gaps show when the Mac was asleep.
- Every sensor HeatWatch reads: hottest CPU core, CPU proximity, GPU, chipset, palm rest, battery, CPU load, power source (charger or battery), CPU speed cap, and macOS's thermal state.
- Today so far: time logged, average and peak temperature (with the time of the peak), time at 90°C or hotter, and time the CPU was slowed.
- The three busiest apps right now. Helper processes count toward their app, so Chrome's helpers count as Chrome.

**Menu actions**

- **Using Cooling Pad** (⌘P): tick it while a cooling pad is running. Each log row records whether the pad was on.
- **Open Today's Report** (⌘R), **Past Reports** (the last 14 days with data) and **Show Data Folder**.
- **Settings**: menu-bar text, update interval (2, 5 or 10 seconds), daily report time (6 PM to 11 PM, or never), and Launch at Login.

**Daily report**

A self-contained HTML page that opens in your default browser at 9 PM by default, once at least 30 minutes have been logged that day. If the Mac was asleep or off at that time, HeatWatch opens yesterday's report the next time it starts or wakes, as long as yesterday has about 30 minutes of data. The report has:

- A verdict and six key numbers: average CPU, peak CPU, time at 90°C+, time slowed, average fan and idle CPU. Average CPU and time at 90°C+ are compared with the previous logged day.
- Interactive charts for the day: CPU and palm-rest temperature, fan speed, CPU load, and when the cooling pad, charger and CPU slowdowns were active. You can read any moment by hovering, or with the arrow keys.
- Findings in plain language, based on fixed rules. Examples: the fan reading as stopped while the CPU was 70°C or hotter, the fan near full speed while the CPU stayed at 90°C+, high idle temperature, time at 90°C+ and 97°C+, macOS slowdowns, the palm rest or battery reaching 40°C, and `kernel_task` among the busy processes.
- Cooling-pad effect over the last 7 days. Readings are split into three CPU-load bands (under 15%, 15–50%, over 50%), so the pad is only compared against similar work. A band needs at least 10 minutes with and without the pad before it counts.
- Which apps were busiest while the CPU was at 85°C or hotter, and a table of hot spells (a minute or more at 90°C+).
- An hour-by-hour table and a 7-day summary.
- Light and dark mode.

**Command line**

The executable inside the app bundle (`HeatWatch.app/Contents/MacOS/HeatWatch`) takes these flags:

```bash
HeatWatch --probe                            # print every sensor reading once
HeatWatch --report [YYYY-MM-DD] [--no-open]  # build a report (default: today), print its path and open it
HeatWatch --enable-login-item                # write the LaunchAgent that starts HeatWatch at login
```

## How it works

### Data sources

| Reading | Source |
|---|---|
| Temperatures | SMC keys, read through IOKit (details below) |
| Fan speed | SMC keys `FNum` (fan count) and `F0Ac`, `F0Tg`, `F0Mn`, `F0Mx` (actual, target, min and max rpm), and the same for other fans |
| CPU load | `host_statistics(HOST_CPU_LOAD_INFO)`, from the change in CPU ticks since the previous sample |
| CPU speed cap | `IOPMCopyCPUPowerStatus`, key `CPU_Speed_Limit`. Below 100% means macOS is slowing the CPU |
| Thermal state | `ProcessInfo.thermalState` (nominal, fair, serious, critical) |
| Power source | `IOPSCopyPowerSourcesInfo` and `IOPSGetProvidingPowerSourceType` |
| Busiest apps | `/bin/ps -Aco pcpu=,comm=`, run on a background queue |
| Machine name in the report | `sysctl` values `hw.model` and `machdep.cpu.brand_string` |

**SMC.** The System Management Controller owns the temperature sensors and fan controller on Intel Macs. `SMC.swift` is a small read-only client. It opens the `AppleSMC` IOKit service and calls its user client with `IOConnectCallStructMethod`, passing a Swift struct laid out like the kernel's 80-byte `SMCKeyData_t`. For each four-character key it first asks for the data size and type (and caches the answer), then reads the bytes. It decodes `flt` (float), `ui8`/`ui16`/`ui32` (unsigned integers), and the `sp..`/`fp..` fixed-point types.

**Sensor keys.** Keys differ between Mac models, so CPU and GPU try a list and use the first key that returns a value:

- CPU: `TCXC`, `TC0D`, `TC0E`, `TC0F`, `TC0P`
- GPU: `TCGC`, `TG0D`, `TG0P`
- CPU cores: `TC1C` to `TC8C` (the panel shows the hottest)
- CPU proximity `TC0P`, chipset `TPCD`, battery `TB0T`, palm rest `Ts0P`

A missing sensor often reports a placeholder such as -127°C, so any value outside 0–130°C counts as missing.

### Permissions

- No sudo, no root, no privileged helper and no entitlements. The SMC read calls it uses work as a normal user. HeatWatch doesn't use `powermetrics`.
- It only reads. It never writes SMC keys and doesn't control the fans.
- It makes no network connections. It writes data only to your home folder, or to `HEATWATCH_DATA_DIR` if you set it.

### Sampling and logging

- HeatWatch takes a reading every 5 seconds by default. The timer allows macOS to shift wake-ups by up to 20% to save energy.
- Readings are grouped into 30-second windows. Each window becomes one CSV row with the average temperatures, the hottest single CPU reading, the lowest speed cap, the highest thermal state, the power source, the cooling-pad flag and the busiest apps. That is at most about 2,900 rows (about 200 KB) a day.
- If no reading arrives for a while (the Mac slept), the open window is closed where it stopped, so sleep doesn't stretch the data.
- `ps` only runs when the CPU is at 85°C or hotter (at most once per 30-second window) or when you open the menu.
- When launchd stops the app (logout or reinstall), it quits normally and writes the last partial window.

### Heat levels

These thresholds are hard-coded in `Sensors.swift` for the Core i5-7360U, which is rated to 100°C.

| Level | CPU temperature |
|---|---|
| Normal | below 75°C |
| Warm | 75°C to under 90°C |
| Hot | 90°C to under 97°C (orange in the menu bar) |
| Very hot | 97°C and above (red in the menu bar) |

At 85°C and above, HeatWatch records which apps are busiest.

### Report generation

`Report.swift` loads the CSV logs for the chosen day and the six days before it. It computes day summaries and the cooling-pad comparison, then serialises everything to JSON. It puts that JSON into `Resources/report.html` in place of `__REPORT_DATA__` and saves the result as one standalone file. All charts and findings are drawn by plain JavaScript and inline SVG in that template. The day totals are calculated in both Swift (`DayStats`) and JavaScript, and the two are kept in step.

### Launch at login

Launch at Login writes a per-user LaunchAgent to `~/Library/LaunchAgents/local.heatwatch.plist`. It sets `RunAtLoad`, and `KeepAlive` with `SuccessfulExit: false`, so launchd restarts HeatWatch after a crash but not after you quit it. Only one copy runs at a time. A second copy exits on launch.

### Where data lives

- Logs: `~/Library/Application Support/HeatWatch/logs/YYYY-MM-DD.csv`
- Reports: `~/Library/Application Support/HeatWatch/reports/heat-report-YYYY-MM-DD.html`
- Settings: user defaults for the bundle ID `local.heatwatch`
- Set `HEATWATCH_DATA_DIR` to use a different data folder, for example when testing.

CSV columns: `time, cpu, cpu_peak, cpu_prox, gpu, chipset, battery, palm_rest, fan, fan_target, fan_min, fan_max, load, speed_limit, thermal_state, on_ac, cooling_pad, top_processes`.

## Tech stack

- Swift and AppKit: `NSStatusItem`, `NSMenu`, and a custom `NSView` drawn with `NSBezierPath` for the live panel
- IOKit: the SMC user client, IOPM (CPU power status) and IOPS (power sources)
- Mach `host_statistics` for CPU load
- launchd LaunchAgent for launch at login
- HTML, CSS, plain JavaScript and inline SVG for the report
- Built with `swiftc` from a shell script. There is no Xcode project, Swift package or third-party dependency.

## Build and run

**Requirements**

- An Intel Mac running macOS 12 Monterey or later
- Swift 5.7 or later: Xcode 14 or later, or just the Command Line Tools (`xcode-select --install`). Xcode itself isn't needed.

**Build and try it**

```bash
./build.sh                    # compiles into build/HeatWatch.app and signs it ad hoc
open build/HeatWatch.app      # runs it from the build folder
build/HeatWatch.app/Contents/MacOS/HeatWatch --probe   # check what your Mac reports
```

**Install**

```bash
./install.sh     # builds, copies to ~/Applications, starts it now and at every login
./uninstall.sh   # stops it, removes the app and the LaunchAgent, keeps your logs and reports
```

`install.sh` doesn't need sudo. It stops any running copy, copies the app to `~/Applications`, writes the LaunchAgent and starts it with `launchctl bootstrap`.

## Project structure

```
Sources/
  main.swift            Entry point and command-line flags
  AppDelegate.swift     Menu-bar item, menu, settings, sampling timer, report scheduling, login item
  DashboardView.swift   The live panel shown in the menu
  Sensors.swift         Reads every sensor into a Reading; heat thresholds; ps sampler
  SMC.swift             Minimal read-only SMC client over IOKit
  DataLog.swift         30-second windows, CSV storage, daily totals
  Report.swift          Builds the HTML report from 7 days of logs
Resources/
  report.html           Report template: findings and charts in plain JavaScript and SVG
Info.plist              Bundle settings; LSUIElement hides the Dock icon
build.sh                Compiles with swiftc and signs ad hoc
install.sh              Builds, installs to ~/Applications and registers the LaunchAgent
uninstall.sh            Stops the app and removes it and its LaunchAgent; keeps data
```

## Status and limitations

- A personal tool at version 1.0. It was built and used on one machine: a 13-inch 2017 MacBook Pro (MacBookPro14,1, Core i5-7360U).
- Intel only. Apple Silicon Macs use different SMC sensor keys and aren't supported. `build.sh` targets the current machine's architecture, but HeatWatch has only been run on Intel.
- Sensors differ by model. CPU and GPU try several keys. CPU proximity, palm rest, chipset and battery use one key each and show `--` if your Mac doesn't have it. Run `--probe` to see what yours reports.
- Only the first fan is shown, logged and reported. On models with two fans, `--probe` lists both.
- The heat thresholds and the report's advice are tuned for the original machine. For example, the report treats 40–60°C as a normal idle temperature, and some findings mention checking thermal paste after a logic-board repair. To use other values, edit `Thresholds` in `Sensors.swift` and the text in `Resources/report.html`.
- There are no notifications. The menu-bar colour and the daily report are the only alerts.
- You have to tick the cooling-pad setting yourself. HeatWatch can't detect a pad.
- There are no automated tests and no signed or notarized release. Build it from source.
