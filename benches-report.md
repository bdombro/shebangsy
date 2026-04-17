# Benchmark report

Generated from [`benches.jsonl`](./benches.jsonl) (5 run(s)).

**Latest run:** `time=1776445495` · **CPU:** Apple M4 Pro

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
    x-axis ["#1 04-17 16:08", "#2 04-17 17:57", "#3 04-17 18:00", "#4 04-17 18:03", "#5 04-17 18:04"]
    y-axis "overhead ms" 7 --> 15
    line [12.4, 9.9, 10.1, 11.2, 13.7]
    line [11.7, 11.9, 10.2, 9.9, 10.9]
    line [8.9, 11.6, 9.2, 10.7, 11.0]
    line [10.2, 11.6, 10.2, 11.8, 11.8]
    line [12.6, 13.3, 11.2, 10.8, 13.2]
    line [9.1, 11.9, 7.9, 12.3, 12.3]
    line [9.3, 10.2, 9.3, 10.3, 12.6]
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
    bar [6.4, 20.1, 7.8, 18.7, 20.4, 20.8, 11.0, 22.0, 6.8, 18.6, 16.9, 30.1, 56.1, 6.8, 19.1, 7.2, 19.8, 80.0]
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
    bar [5.7, 17.2, 7.0, 17.9, 19.1, 19.1, 10.6, 20.9, 5.9, 17.0, 16.7, 28.9, 55.2, 5.9, 16.6, 6.3, 16.7, 80.0]
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
    bar [13.7, 10.9, 11.0, 11.8, 13.2, 12.3, 12.6]
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
    title "Mean overhead vs bin — all 5 run(s), shebangsy only (lower is better)"
    x-axis ["cpp/shebangsy.cpp", "go/shebangsy.go", "mojo/shebangsy.mojo", "nim/shebangsy.nim", "python/shebangsy.py", "rust/shebangsy.rs", "swift/shebangsy.swift"]
    y-axis "overhead ms" 9 --> 13
    bar [11.5, 10.9, 10.3, 11.1, 12.2, 10.7, 10.3]
```
