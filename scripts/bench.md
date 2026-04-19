# Benchmark harness (`bench.py`)

This document describes [`bench.py`](./bench.py): what it measures, why it is shaped that way, and how the pieces connect. For day-to-day commands, see the benchmark section in the repo README, or run `just bench` (full run) and `just bench-report` (report only) from the repo root.

## What it does

`bench.py` is the single entry point for **automated comparative benchmarks** of shebangsy runners and related baselines across languages. It:

1. Ensures artifacts exist via `./scripts/build.sh`.
2. Runs every configured bench command once (**preflight**) so obvious failures surface before long hyperfine sessions.
3. Invokes **[hyperfine](https://github.com/sharkdp/hyperfine)** with `--shell=none` for the main command set, for several **rounds** with **alternating forward/reversed order** to reduce ordering bias.
4. Optionally runs a **second hyperfine pass** for `slow_apps` with fewer repeats per command.
5. Merges hyperfine JSON exports into **per-command mean times** (seconds internally), converts to **milliseconds**, and groups results into a nested **`language → asset → ms`** object.
6. **Appends one JSON object per bench run** to `benches.jsonl` (timestamp, CPU label, results).
7. Regenerates **`benches-report.md`** (Mermaid charts plus a language color legend) and replaces the first **```mermaid** block under **`### Results`** in `README.md` with the “mean time over all runs” chart.

**Report only:** `./scripts/bench.py --regenerate-report` (or **`just bench-report`**) runs `run_report` against the current `benches.jsonl` and skips build, preflight, and hyperfine. A full `just bench` / default `bench.py` invocation still ends by calling `run_report` after appending a new jsonl row.

## Why it is designed this way

- **Same tree, comparable numbers**: Commands are rooted under `scripts/bench-assets/<lang>/` so paths and grouping stay stable across machines and commits.
- **Baselines**: Compiled `bin` targets and plain **interpreter** invocations (e.g. `python3 …/shebangsy.py`) sit in the same hyperfine list where configured. Interpreter lines are **aliased** in results to a synthetic `./scripts/bench-assets/<lang>/bin` key so charts can compare “script vs bin” per language without duplicating legend rows for two different spellings of the same idea.
- **Fairness knobs**: Multiple hyperfine rounds with reversed order, warmup runs, and many measured runs per command reduce noise and slot-order effects. Slow apps get their own pass so the main grid stays fast while still recording heavier cases.
- **History and communication**: `benches.jsonl` is append-only **evidence**; Markdown + Mermaid charts make trends visible in the repo without a separate dashboard.
- **Optional macOS QoS**: When `CPU_TASKPOLICY_HIGH` is true, commands run under `taskpolicy -c high -- …`; the prefix is stripped when grouping so jsonl keys do not change.

## Prerequisites

- `hyperfine` on `PATH` (install hint is printed if missing).
- Bench assets listed in `BENCH_LANGUAGE_META` present on disk under `scripts/bench-assets/`.
- Successful `./scripts/build.sh` from the repo root (dist binaries on `PATH` for the bench process).

## Main configuration surface

| Area | Where | Role |
|------|--------|------|
| Per-language apps and colors | `BENCH_LANGUAGE_META` in `bench.py` | Defines `apps`, optional `slow_apps`, optional interpreter baseline, and chart colors for reports. |
| Hyperfine counts | `HYPERFINE_*` constants | Rounds, warmup, runs per command, slow-pass runs. |
| CPU QoS | `CPU_TASKPOLICY_HIGH` | Optional `taskpolicy -c high` wrapper (see above). |

Interpreter baseline commands are normalized and mapped through **`COMMAND_ALIASES`** (built at import time) plus **`_merge_slow_interpreter_aliases()`** for slow-app interpreter lines, so they group under the same synthetic `bin` key as the main baseline when applicable.

## Artifacts

| Path | Direction | Meaning |
|------|-----------|---------|
| `benches.jsonl` | Append | One line per run: `time`, `cpu`, `results` (nested ms map). |
| `benches-report.md` | Overwrite | Human-readable report with multiple Mermaid charts and a color legend. |
| `README.md` | Patch one fence | `### Results` section: first mermaid fence replaced with the all-runs mean-time chart. |

---

## Diagram: end-to-end flow

```mermaid
flowchart TD
  subgraph entry["Entry"]
    M[main]
    M -->|default| RB[run_bench]
    M -->|--regenerate-report| RR[run_report]
  end

  subgraph bench["run_bench"]
    B[build.sh]
    PF[Preflight each command]
    HF[Hyperfine main rounds]
    SL[Hyperfine slow_apps pass]
    AG[Aggregate means to nested results]
    JL[Append benches.jsonl]
    B --> PF --> HF --> SL --> AG --> JL
  end

  subgraph report["run_report"]
    L[Load benches.jsonl]
    CH[Build Mermaid charts and legend]
    W1[Write benches-report.md]
    W2[Patch README Results chart]
    L --> CH --> W1
    CH --> W2
  end

  RB --> B
  JL --> RR
  RR --> L
```

---

## Diagram: `run_bench` sequence

```mermaid
flowchart LR
  subgraph discover["Discover commands"]
    A1[Walk BENCH_LANGUAGE_META apps]
    A2[Add interpreter baseline cmds if needed]
    A3[Collect slow_apps cmds if files exist]
    A1 --> A2 --> A3
  end

  subgraph hf["Hyperfine"]
    R1[Round 1 forward order]
    R2[Round 2 reversed]
    Rn[More rounds alternate]
    R1 --> R2 --> Rn
    S[Slow pass optional]
    Rn --> S
  end

  subgraph post["Post-process"]
    E[Export JSON per pass]
    M[Map command string to grouping key]
    V[Mean per command across samples]
    G[Group to lang and asset ms]
    E --> M --> V --> G
  end

  discover --> PF[Preflight]
  PF --> hf
  hf --> post
  post --> J[Append jsonl]
  J --> RP[run_report]
```

---

## Diagram: from hyperfine command string to jsonl `results`

Hyperfine reports each benchmark command as a string. That string is **normalized**, **taskpolicy-stripped** if applicable, looked up in **alias tables**, then parsed for **`./scripts/bench-assets/...`** path segments to produce **`language`** and **`asset`** keys in the nested JSON.

```mermaid
flowchart TD
  H["Hyperfine result.command"]
  S["_strip_cpu_taskpolicy_high_prefix"]
  N["_normalize_hyperfine_command"]
  A["COMMAND_ALIASES + slow merge"]
  P["_bench_asset_parts or other bucket"]
  O["Nested results lang to asset to ms"]

  H --> S --> N --> A
  A -->|"alias hit"| K["Synthetic path e.g. .../lang/bin"]
  A -->|"no alias"| K2["Original stripped command"]
  K --> P
  K2 --> P
  P --> O
```

---

## Diagram: `run_report` inputs and outputs

```mermaid
flowchart LR
  J[benches.jsonl]
  J --> LR[run_report reads and sorts rows]

  LR --> C1[Overhead vs bin over time line chart]
  LR --> C2[Latest run absolute bars]
  LR --> C3[All-runs mean absolute bars]
  LR --> C4[Shebangsy overhead bars latest and mean]
  LR --> LG[Language color legend]

  C3 --> RM[README mermaid under Results]
  C1 --> BR[benches-report.md]
  C2 --> BR
  C3 --> BR
  C4 --> BR
  LG --> BR
```

Charts use **Mermaid `xychart-beta`** blocks: absolute-time bars share a horizontal bar helper with a fixed ms cap for scale; overhead charts use **script ms minus same-language `bin` ms** for assets whose filenames include `shebangsy` (where `bin` exists in that run).

---

## Related paths

- Script: [`bench.py`](./bench.py)
- Assets: `scripts/bench-assets/<lang>/…`
- Build: `scripts/build.sh`
