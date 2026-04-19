# Benchmark report

Generated from [`benches.jsonl`](./benches.jsonl) (3 run(s)).

**Latest run:** `time=1776620953` · **CPU:** Apple M4 Pro

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
    x-axis ["#1 04-17 17:57", "#2 04-19 18:34", "#3 04-19 18:49"]
    y-axis "overhead ms" 9 --> 15
    line [9.9, 11.1, 10.4]
    line [11.9, 10.4, 11.7]
    line [11.6, 11.3, 10.9]
    line [11.6, 12.2, 11.3]
    line [13.3, 14.2, 13.8]
    line [11.9, 11.7, 12.4]
    line [10.2, 12.0, 10.4]
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
    x-axis ["cpp/bin", "cpp/shebangsy.cpp", "go/bin", "go/gorun.go", "go/shebangsy.go", "go/scriptisto.go", "mojo/bin", "mojo/shebangsy.mojo", "nim/bin", "nim/shebangsy.nim", "python/bin", "python/shebangsy.py", "python/uv.py", "rust/bin", "rust/shebangsy.rs", "swift/bin", "swift/shebangsy.swift", "swift/swift_sh.swift"]
    y-axis "ms" 0 --> 80
    bar [5.2, 15.6, 5.8, 17.0, 17.5, 17.8, 10.8, 21.7, 6.3, 17.6, 16.7, 30.5, 55.8, 5.9, 18.3, 7.3, 17.7, 80.0]
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
    bar [5.8, 16.3, 6.6, 18.0, 18.6, 18.8, 10.8, 22.0, 6.1, 17.8, 16.5, 30.3, 54.3, 6.1, 18.1, 7.0, 17.9, 80.0]
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
    y-axis "overhead ms" 9 --> 15
    bar [10.4, 11.7, 10.9, 11.3, 13.8, 12.4, 10.4]
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
    title "Mean overhead vs bin — all 3 run(s), shebangsy only (lower is better)"
    x-axis ["cpp/shebangsy.cpp", "go/shebangsy.go", "mojo/shebangsy.mojo", "nim/shebangsy.nim", "python/shebangsy.py", "rust/shebangsy.rs", "swift/shebangsy.swift"]
    y-axis "overhead ms" 10 --> 15
    bar [10.5, 11.3, 11.3, 11.7, 13.8, 12.0, 10.9]
```

## Language colors (legend)

Series colors in the charts above follow **language** (first path segment). Use this table to map each language to its **named color** and **hex**.

| Language | Color | Hex |
| --- | --- | --- |
| `cpp` | Blue | `#1d4ed8` |
| `go` | Green | `#15803d` |
| `mojo` | Amber | `#a16207` |
| `nim` | Purple | `#7c3aed` |
| `python` | Red | `#b91c1c` |
| `rust` | Cyan | `#0e7490` |
| `swift` | Indigo | `#4338ca` |
| `other` | Slate | `#64748b` |
