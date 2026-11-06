# Third-party notices

HeatWatch has no third-party code or dependencies. It builds only against Apple's
system frameworks (AppKit, IOKit, Foundation).

## Stats

HeatWatch's Apple Silicon sensor key families (which SMC keys belong to the CPU and GPU on
each chip generation, including the M3 family's separate layout) were taken from the sensor
tables in Stats, an open-source macOS system monitor:

- Project: https://github.com/exelban/stats
- File: `Modules/Sensors/values.swift`
- Used in: `Sources/Sensors.swift` (`Sensors.siliconKeys`)

No Stats source code is included. The key names are reproduced here with credit, under
Stats' licence:

```
MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
