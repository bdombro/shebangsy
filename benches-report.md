# Benchmark report

Generated from [`benches.jsonl`](./benches.jsonl) (13 run(s)).

**Latest run:** `time=1776443886` · **CPU:** Apple M4 Pro

## Overhead vs `bin` over time

Each line is **mean ms − same-language `bin` ms** for assets whose filename includes `shebangsy` (other runners are omitted). Use it to spot **regressions**: a line drifting **up** means shebangsy is slower vs the compiled baseline; **down** is better vs `bin`.

```mermaid
---
config:
  themeVariables:
    xyChart:
      backgroundColor: "#e8eaed"
      plotColorPalette: "#1d4ed8, #15803d, #a16207, #7c3aed, #b91c1c, #0e7490, #4338ca"
      titleColor: "#111318"
      xAxisLabelColor: "#2d3139"
      yAxisLabelColor: "#2d3139"
      xAxisTitleColor: "#1a1d24"
      yAxisTitleColor: "#1a1d24"
      xAxisLineColor: "#9aa0ab"
      yAxisLineColor: "#9aa0ab"
      xAxisTickColor: "#5c6370"
      yAxisTickColor: "#5c6370"
---
xychart-beta
    title "Overhead vs bin: script ms minus lang/bin (lower is better)"
    x-axis ["#1 04-17 16:08", "#2 04-17 16:09", "#3 04-17 16:10", "#4 04-17 16:20", "#5 04-17 16:26", "#6 04-17 16:29", "#7 04-17 16:46", "#8 04-17 16:47", "#9 04-17 16:47", "#10 04-17 16:48", "#11 04-17 16:50", "#12 04-17 17:04", "#13 04-17 17:38"]
    y-axis "overhead ms" 5 --> 16
    line [12.4, 11.8, 11.0, 12.0, 10.9, 11.0, 9.2, 6.8, 6.9, 10.3, 10.7, 8.2, 11.1]
    line [11.7, 9.3, 11.3, 8.6, 12.1, 10.5, 9.1, 8.6, 7.1, 7.8, 10.2, 8.3, 11.5]
    line [8.9, 9.7, 11.5, 9.5, 9.1, 9.9, 9.6, 8.8, 8.5, 9.1, 9.3, 7.8, 12.3]
    line [10.2, 10.1, 12.4, 10.1, 10.5, 10.0, 11.0, 8.2, 6.2, 9.2, 10.0, 8.1, 12.1]
    line [12.6, 12.1, 11.6, 10.8, 11.6, 12.8, 11.3, 9.7, 6.5, 9.7, 11.8, 9.7, 14.2]
    line [9.1, 12.5, 9.7, 11.6, 10.1, 10.5, 11.0, 8.5, 7.7, 8.3, 8.6, 8.2, 12.3]
    line [9.3, 10.5, 9.0, 9.0, 9.0, 9.0, 10.4, 8.6, 7.2, 9.9, 10.8, 7.6, 11.0]
```

## Absolute time (ms) - most recent run

Bars are ordered **by language** (A–Z), then **by time ascending** within each language (lower ms first). Axis labels are `lang/asset`; large values are clipped for scale.

```mermaid
---
config:
  themeVariables:
    xyChart:
      backgroundColor: "#e8eaed"
      plotColorPalette: "#1d4ed8, #1d4ed8, #15803d, #15803d, #15803d, #15803d, #a16207, #a16207, #7c3aed, #7c3aed, #b91c1c, #b91c1c, #b91c1c, #0e7490, #0e7490, #4338ca, #4338ca, #4338ca"
      titleColor: "#111318"
      xAxisLabelColor: "#2d3139"
      yAxisLabelColor: "#2d3139"
      xAxisTitleColor: "#1a1d24"
      yAxisTitleColor: "#1a1d24"
      xAxisLineColor: "#9aa0ab"
      yAxisLineColor: "#9aa0ab"
      xAxisTickColor: "#5c6370"
      yAxisTickColor: "#5c6370"
---
xychart-beta horizontal
    title "Latest run — mean time (ms) per app"
    x-axis ["cpp/bin", "cpp/shebangsy.cpp", "go/bin", "go/shebangsy.go", "go/gorun.go", "go/scriptisto.go", "mojo/bin", "mojo/shebangsy.mojo", "nim/bin", "nim/shebangsy.nim", "python/bin", "python/shebangsy.py", "python/uv.py", "rust/bin", "rust/shebangsy.rs", "swift/bin", "swift/shebangsy.swift", "swift/swift_sh.swift"]
    y-axis "ms" 0 --> 80
    bar [5.4, 16.5, 6.5, 18.0, 20.0, 21.2, 10.7, 23.0, 6.1, 18.2, 16.4, 30.6, 56.4, 6.2, 18.5, 6.8, 17.8, 80.0]
```

## Absolute time (ms) — mean of all runs

**Mean ms per app** across every row in `benches.jsonl`. A run contributes a sample only if that app appears in that row’s results. Same ordering and cap as the latest-run chart.

```mermaid
---
config:
  themeVariables:
    xyChart:
      backgroundColor: "#e8eaed"
      plotColorPalette: "#1d4ed8, #1d4ed8, #15803d, #15803d, #15803d, #15803d, #a16207, #a16207, #7c3aed, #7c3aed, #b91c1c, #b91c1c, #b91c1c, #0e7490, #0e7490, #4338ca, #4338ca, #4338ca"
      titleColor: "#111318"
      xAxisLabelColor: "#2d3139"
      yAxisLabelColor: "#2d3139"
      xAxisTitleColor: "#1a1d24"
      yAxisTitleColor: "#1a1d24"
      xAxisLineColor: "#9aa0ab"
      yAxisLineColor: "#9aa0ab"
      xAxisTickColor: "#5c6370"
      yAxisTickColor: "#5c6370"
---
xychart-beta horizontal
    title "Mean time (ms) per app — all time"
    x-axis ["cpp/bin", "cpp/shebangsy.cpp", "go/bin", "go/shebangsy.go", "go/gorun.go", "go/scriptisto.go", "mojo/bin", "mojo/shebangsy.mojo", "nim/bin", "nim/shebangsy.nim", "python/bin", "python/shebangsy.py", "python/uv.py", "rust/bin", "rust/shebangsy.rs", "swift/bin", "swift/shebangsy.swift", "swift/swift_sh.swift"]
    y-axis "ms" 0 --> 80
    bar [5.4, 15.6, 6.3, 16.0, 17.7, 18.4, 10.1, 19.6, 5.2, 15.0, 16.5, 27.6, 53.7, 5.6, 15.5, 5.9, 15.3, 80.0]
```

## Overhead vs `bin` (shebangsy only)

Bars are ordered **by language** (A–Z), then **by overhead ascending** (lower first).

**Mean ms − same-language `bin` ms** for the latest row; same filename filter as the overhead line chart.

```mermaid
---
config:
  themeVariables:
    xyChart:
      backgroundColor: "#e8eaed"
      plotColorPalette: "#1d4ed8, #15803d, #a16207, #7c3aed, #b91c1c, #0e7490, #4338ca"
      titleColor: "#111318"
      xAxisLabelColor: "#2d3139"
      yAxisLabelColor: "#2d3139"
      xAxisTitleColor: "#1a1d24"
      yAxisTitleColor: "#1a1d24"
      xAxisLineColor: "#9aa0ab"
      yAxisLineColor: "#9aa0ab"
      xAxisTickColor: "#5c6370"
      yAxisTickColor: "#5c6370"
---
xychart-beta horizontal
    title "Latest run — overhead vs bin (shebangsy only, lower is better)"
    x-axis ["cpp/shebangsy.cpp", "go/shebangsy.go", "mojo/shebangsy.mojo", "nim/shebangsy.nim", "python/shebangsy.py", "rust/shebangsy.rs", "swift/shebangsy.swift"]
    y-axis "overhead ms" 10 --> 15
    bar [11.1, 11.5, 12.3, 12.1, 14.2, 12.3, 11.0]
```

## Overhead vs `bin` — mean of all runs (shebangsy only)

**Mean of (script ms − bin ms)** across every row in `benches.jsonl`. Averaging includes only runs where that overhead is defined; same filename filter and bar ordering as the latest overhead chart above.

```mermaid
---
config:
  themeVariables:
    xyChart:
      backgroundColor: "#e8eaed"
      plotColorPalette: "#1d4ed8, #15803d, #a16207, #7c3aed, #b91c1c, #0e7490, #4338ca"
      titleColor: "#111318"
      xAxisLabelColor: "#2d3139"
      yAxisLabelColor: "#2d3139"
      xAxisTitleColor: "#1a1d24"
      yAxisTitleColor: "#1a1d24"
      xAxisLineColor: "#9aa0ab"
      yAxisLineColor: "#9aa0ab"
      xAxisTickColor: "#5c6370"
      yAxisTickColor: "#5c6370"
---
xychart-beta horizontal
    title "Mean overhead vs bin — all 13 run(s), shebangsy only (lower is better)"
    x-axis ["cpp/shebangsy.cpp", "go/shebangsy.go", "mojo/shebangsy.mojo", "nim/shebangsy.nim", "python/shebangsy.py", "rust/shebangsy.rs", "swift/shebangsy.swift"]
    y-axis "overhead ms" 8 --> 12
    bar [10.2, 9.7, 9.5, 9.9, 11.1, 9.9, 9.4]
```
