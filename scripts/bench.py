#!/usr/bin/env python3
"""Hyperfine bench shebangsy vs baselines; jsonl, report+README charts, per-language color legend.

Design and diagrams: see ``scripts/bench.md`` in this repo.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any


_BENCH_ASSETS_PREFIX = "./scripts/bench-assets/"

## Number of full hyperfine passes (each pass runs every bench command once).
## Order alternates forward / reversed each round to reduce ordering bias.
HYPERFINE_BENCHMARK_ROUNDS = 4

## Hyperfine ``--warmup`` runs per command before measured runs (each pass).
HYPERFINE_WARMUP_RUNS = 1

## Hyperfine ``--runs`` per command within each pass.
HYPERFINE_RUNS_PER_COMMAND = 20

## ``slow_apps`` (same tree as ``apps``): one extra hyperfine pass with this many ``--runs``.
HYPERFINE_SLOW_RUNS = 10

## If True, run each benchmark command as ``taskpolicy -c high -- <cmd>`` (macOS ``taskpolicy(1)``).
## Wrapped prefixes are stripped when grouping hyperfine results so jsonl keys stay stable.
CPU_TASKPOLICY_HIGH = False

_CPU_TASKPOLICY_HIGH_PREFIX = "taskpolicy -c high -- "


# Prefix bench command for high-QoS task policy when CPU_TASKPOLICY_HIGH is set.
def _with_cpu_taskpolicy_high(cmd: str) -> str:
	if not CPU_TASKPOLICY_HIGH:
		return cmd
	return f"{_CPU_TASKPOLICY_HIGH_PREFIX}{cmd}"


# Undo _with_cpu_taskpolicy_high so alias normalization and asset paths match unwrapped commands.
def _strip_cpu_taskpolicy_high_prefix(cmd: str) -> str:
	if cmd.startswith(_CPU_TASKPOLICY_HIGH_PREFIX):
		return cmd[len(_CPU_TASKPOLICY_HIGH_PREFIX) :]
	return cmd


# Per-language bench and report metadata. Dict order is the order of main assets in hyperfine.
#
# Keys (all optional except ``apps``):
# - ``apps``: filenames under ``scripts/bench-assets/<lang>/`` (main hyperfine set; may be ``[]``).
# - ``slow_apps``: filenames under ``scripts/bench-assets/<lang>/`` (second hyperfine pass only).
# - ``interpreter`` + ``baseline_script``: plain-interpreter baseline for ``baseline_script`` under
#   ``<lang>/``; hyperfine runs that command and results are grouped under ``<lang>/bin`` (alias).
#   Omit ``bin`` from ``apps`` when there is no real ``bin`` file (e.g. Python); if ``bin`` is in
#   ``apps``, the duplicate interpreter command is not added.
# - ``chart_color_hex``: Mermaid ``plotColorPalette`` per language (merged with defaults below).
# - ``chart_color_name``: Human-readable label for the same hue (report legend, accessibility).
BENCH_LANGUAGE_META_DEFAULTS: dict[str, str] = {
	"chart_color_hex": "#64748b",
	"chart_color_name": "Slate",
}
BENCH_LANGUAGE_META: dict[str, dict[str, Any]] = {
	"cpp": {
		"apps": ["bin", "shebangsy.cpp"],
		"chart_color_hex": "#1d4ed8",
		"chart_color_name": "Blue",
	},
	"go": {
		"apps": ["bin", "gorun.go", "scriptisto.go", "shebangsy.go"],
		"chart_color_hex": "#15803d",
		"chart_color_name": "Green",
	},
	"mojo": {
		"apps": ["bin", "shebangsy.mojo"],
		"chart_color_hex": "#a16207",
		"chart_color_name": "Amber",
	},
	"nim": {
		"apps": ["bin", "shebangsy.nim"],
		"chart_color_hex": "#7c3aed",
		"chart_color_name": "Purple",
	},
	"python": {
		"apps": ["shebangsy.py"],
		"interpreter": "python3",
		"baseline_script": "shebangsy.py",
		"slow_apps": ["uv.py"],
		"chart_color_hex": "#b91c1c",
		"chart_color_name": "Red",
	},
	"rust": {
		"apps": ["bin", "shebangsy.rs"],
		"chart_color_hex": "#0e7490",
		"chart_color_name": "Cyan",
	},
	"swift": {
		"apps": ["bin", "shebangsy.swift"],
		"slow_apps": ["swift_sh.swift"],
		"chart_color_hex": "#4338ca",
		"chart_color_name": "Indigo",
	},
}


# Merge defaults with BENCH_LANGUAGE_META[lang] so every row shares the same config shape.
def _bench_language_meta(lang: str) -> dict[str, Any]:
	row: dict[str, Any] = dict(BENCH_LANGUAGE_META_DEFAULTS)
	row.update(BENCH_LANGUAGE_META.get(lang, {}))
	return row


# Hyperfine cmd line: interpreter + script path (plain baseline, grouped under lang/bin).
def _interpreted_baseline_hyperfine_cmd(
	lang: str, interpreter: str, script: str
) -> str:
	return f'{interpreter} ./scripts/bench-assets/{lang}/{script}'


# Synthetic ./scripts/bench-assets/<lang>/bin path key for interpreter baseline rows.
def _interpreted_baseline_report_path(lang: str) -> str:
	return f"./scripts/bench-assets/{lang}/bin"


# Canonical command key: posix shlex split then single-space join for stable alias lookup.
def _normalize_hyperfine_command(cmd: str) -> str:
	stripped = cmd.strip()
	if not stripped:
		return ""
	try:
		parts = shlex.split(stripped, posix=True)
	except ValueError:
		return " ".join(stripped.split())
	return " ".join(parts)


# Map normalized interpreter baseline cmds to ./scripts/bench-assets/<lang>/bin aliases.
def _build_command_aliases() -> dict[str, str]:
	aliases: dict[str, str] = {}
	for lang, spec in BENCH_LANGUAGE_META.items():
		interpreter = spec.get("interpreter")
		baseline_script = spec.get("baseline_script")
		if not interpreter or not baseline_script:
			continue
		hf = _interpreted_baseline_hyperfine_cmd(lang, interpreter, baseline_script)
		report = _interpreted_baseline_report_path(lang)
		aliases[_normalize_hyperfine_command(hf)] = report
	return aliases


COMMAND_ALIASES: dict[str, str] = _build_command_aliases()


# If cmd is under bench-assets, return (lang, asset filename); else None.
def _bench_asset_parts(command_name: str) -> tuple[str, str] | None:
	if not command_name.startswith(_BENCH_ASSETS_PREFIX):
		return None
	tail = command_name[len(_BENCH_ASSETS_PREFIX) :]
	if tail.startswith("slow/"):
		rest = tail[len("slow/") :]
		slash = rest.find("/")
		if slash == -1:
			return ("bench-assets", rest)
		return (rest[:slash], rest[slash + 1 :])
	slash = tail.find("/")
	if slash == -1:
		return ("bench-assets", tail)
	return (tail[:slash], tail[slash + 1 :])


# Flatten nested lang->{asset:ms} to single dict with lang/asset keys for chart code.
def _flatten_results(results: dict[str, dict[str, float]]) -> dict[str, float]:
	flat: dict[str, float] = {}
	for lang, assets in results.items():
		for asset, ms in assets.items():
			flat[f"{lang}/{asset}"] = float(ms)
	return flat


# Sanitize chart axis token: strip chars that break Mermaid x-axis [...] lists.
def _mermaid_axis_label(key: str) -> str:
	return key.replace(",", "_").replace("]", ")").replace("[", "(")


# Distinct hues for lines/bars on a light gray chart background (`themeVariables.xyChart`).
# Each entry is ``(hex, human-readable name)`` for Mermaid and for the overhead legend table.
_SERIES_PALETTE: tuple[tuple[str, str], ...] = (
	("#1d4ed8", "Blue"),
	("#b91c1c", "Red"),
	("#15803d", "Green"),
	("#a16207", "Amber"),
	("#7c3aed", "Purple"),
	("#0e7490", "Cyan"),
	("#c2410c", "Orange"),
	("#be185d", "Pink"),
	("#4338ca", "Indigo"),
	("#0f766e", "Teal"),
	("#854d0e", "Bronze"),
	("#6d28d9", "Violet"),
	("#166534", "Forest green"),
	("#9f1239", "Rose"),
	("#075985", "Steel blue"),
	("#a21caf", "Fuchsia"),
	("#b45309", "Gold"),
	("#115e59", "Dark teal"),
	("#9d174d", "Plum"),
	("#1e40af", "Navy"),
)


# plotColorPalette hexes in flat_keys order, each from that row's language chart_color_hex.
def _plot_color_palette_csv_for_flat_keys(flat_keys: list[str]) -> str:
	# Language segment of a lang/asset key, or 'other' if no slash.
	def _language_from_flat_key(flat_key: str) -> str:
		lang, _, _ = flat_key.partition("/")
		return lang if lang else "other"

	if not flat_keys:
		return BENCH_LANGUAGE_META_DEFAULTS["chart_color_hex"]
	return ", ".join(
		_bench_language_meta(_language_from_flat_key(k))["chart_color_hex"] for k in flat_keys
	)


# Mermaid xyChart YAML block: gray theme + plotColorPalette string for series colors.
def _mermaid_xychart_frontmatter(
	*,
	series_count: int,
	plot_color_palette_csv: str | None = None,
) -> str:
	# Return count hex colors by cycling _SERIES_PALETTE (non-language-colored charts).
	def _series_colors(count: int) -> list[str]:
		if count <= 0:
			return []
		pal = _SERIES_PALETTE
		return [pal[i % len(pal)][0] for i in range(count)]

	# Comma-separated hex list for Mermaid plotColorPalette (series order, count bars/lines).
	def _plot_color_palette_csv(count: int) -> str:
		if count <= 0:
			return "#6b7280"
		return ", ".join(_series_colors(count))

	palette = (
		plot_color_palette_csv
		if plot_color_palette_csv is not None
		else _plot_color_palette_csv(series_count)
	)
	return "\n".join(
		[
			"---",
			"config:",
			"  themeVariables:",
			"    xyChart:",
			'      backgroundColor: "#e8eaed"',
			f'      plotColorPalette: "{palette}"',
			'      titleColor: "#111318"',
			'      xAxisLabelColor: "#2d3139"',
			'      yAxisLabelColor: "#2d3139"',
			'      xAxisTitleColor: "#1a1d24"',
			'      yAxisTitleColor: "#1a1d24"',
			'      xAxisLineColor: "#9aa0ab"',
			'      yAxisLineColor: "#9aa0ab"',
			'      xAxisTickColor: "#5c6370"',
			'      yAxisTickColor: "#5c6370"',
			"---",
		]
	)


# One row: asset ms minus bin ms for lang, or None if bin/asset timing missing.
def _overhead_ms_for_run(row: dict, lang: str, asset: str) -> float | None:
	results = row.get("results")
	if not isinstance(results, dict):
		return None
	assets = results.get(lang)
	if not isinstance(assets, dict):
		return None
	bin_ms = assets.get("bin")
	asset_ms = assets.get(asset)
	if bin_ms is None or asset_ms is None:
		return None
	return float(asset_ms) - float(bin_ms)


## Max ms on the “Latest run — mean time” bar chart (values clamped for scale).
_MERMAID_BAR_LATEST_MAX_MS = 80


# Order bar rows: languages A-Z, then ascending value within each language cluster.
def _sort_bar_items_by_language_cluster(
	items: list[tuple[str, float]],
) -> list[tuple[str, float]]:
	by_lang: dict[str, list[tuple[str, float]]] = {}
	for key, val in items:
		lang, _, _ = key.partition("/")
		if not lang:
			lang = "other"
		by_lang.setdefault(lang, []).append((key, val))
	for row in by_lang.values():
		row.sort(key=lambda kv: kv[1])
	out: list[tuple[str, float]] = []
	for lang in sorted(by_lang.keys()):
		out.extend(by_lang[lang])
	return out


# Horizontal xyChart bars: title + clustered lang/asset keys vs capped ms (shared renderer).
def _mermaid_horizontal_bar_absolute_time(
	chart_title: str, items: list[tuple[str, float]]
) -> str:
	ordered = _sort_bar_items_by_language_cluster(items)
	names = [k for k, _ in ordered]
	labels = [json.dumps(_mermaid_axis_label(k)) for k in names]
	cap = float(_MERMAID_BAR_LATEST_MAX_MS)
	values = [min(round(v, 1), cap) for _, v in ordered]
	ymax = int(cap)
	x_lit = ", ".join(labels)
	nums = ", ".join(str(v) for v in values)
	palette_csv = _plot_color_palette_csv_for_flat_keys(names)
	chart_body = "\n".join(
		[
			"```mermaid",
			_mermaid_xychart_frontmatter(
				series_count=len(names),
				plot_color_palette_csv=palette_csv,
			),
			"xychart-beta horizontal",
			f'    title "{chart_title}"',
			f"    x-axis [{x_lit}]",
			f'    y-axis "ms" 0 --> {ymax}',
			f"    bar [{nums}]",
			"```",
		]
	)
	return chart_body


# One results dict -> (lang/asset, overhead ms) pairs for filenames containing 'shebangsy'.
def _latest_shebangsy_overhead_pairs(last_results: object) -> list[tuple[str, float]]:
	pairs: list[tuple[str, float]] = []
	if not isinstance(last_results, dict):
		return pairs
	for lang, assets in last_results.items():
		if not isinstance(assets, dict) or "bin" not in assets:
			continue
		bin_ms = float(assets["bin"])
		for asset, ms in assets.items():
			if asset == "bin" or "shebangsy" not in str(asset).lower():
				continue
			pairs.append((f"{lang}/{asset}", float(ms) - bin_ms))
	return pairs


# Write benches-report.md (charts + color legend) and patch README ### Results mermaid chart.
def run_report(root_dir: Path) -> int:
	# Load non-empty lines from benches.jsonl as dicts sorted by time ascending.
	def _load_benches_jsonl(path: Path) -> list[dict]:
		if not path.is_file():
			return []
		rows: list[dict] = []
		with path.open(encoding="utf-8") as handle:
			for line in handle:
				line = line.strip()
				if not line:
					continue
				rows.append(json.loads(line))
		rows.sort(key=lambda row: int(row["time"]))
		return rows

	# Report footer markdown: each lang -> human color name + hex (decode chart hues without order).
	def _language_color_legend_markdown() -> str:
		lines = [
			"## Language colors (legend)",
			"",
			"Series colors in the charts above follow **language** (first path segment). Use this table to "
			"map each language to its **named color** and **hex**.",
			"",
			"| Language | Color | Hex |",
			"| --- | --- | --- |",
		]
		for lang in sorted(BENCH_LANGUAGE_META.keys()):
			meta = _bench_language_meta(lang)
			human = str(meta.get("chart_color_name", "Slate"))
			hx = str(meta.get("chart_color_hex", "#64748b"))
			lines.append(f"| `{lang}` | {human} | `{hx}` |")
		lines.append(
			f"| `other` | {BENCH_LANGUAGE_META_DEFAULTS['chart_color_name']} | "
			f"`{BENCH_LANGUAGE_META_DEFAULTS['chart_color_hex']}` |"
		)
		lines.append("")
		return "\n".join(lines)

	# Replace first ```mermaid block after ### Results in README with chart; 0 ok else 1.
	def _patch_readme_results_chart(readme_path: Path, chart: str) -> int:
		try:
			text = readme_path.read_text(encoding="utf-8")
		except OSError as exc:
			print(f"bench.py: cannot read {readme_path}: {exc}", file=sys.stderr)
			return 1

		lines = text.splitlines(keepends=True)
		results_idx: int | None = None
		for i, line in enumerate(lines):
			if line.rstrip("\r\n") == "### Results":
				results_idx = i
				break
		if results_idx is None:
			print(
				f"bench.py: {readme_path.name}: missing '### Results' heading",
				file=sys.stderr,
			)
			return 1

		fence_start: int | None = None
		for j in range(results_idx + 1, len(lines)):
			if lines[j].lstrip().startswith("```mermaid"):
				fence_start = j
				break
		if fence_start is None:
			print(
				f"bench.py: {readme_path.name}: no ```mermaid fence after '### Results'",
				file=sys.stderr,
			)
			return 1

		fence_end: int | None = None
		for k in range(fence_start + 1, len(lines)):
			if lines[k].strip() == "```":
				fence_end = k
				break
		if fence_end is None:
			print(
				f"bench.py: {readme_path.name}: unclosed ```mermaid fence after "
				"'### Results'",
				file=sys.stderr,
			)
			return 1

		new_chart = chart.rstrip() + "\n"
		updated = "".join(lines[:fence_start] + [new_chart] + lines[fence_end + 1 :])
		try:
			readme_path.write_text(updated, encoding="utf-8")
		except OSError as exc:
			print(f"bench.py: cannot write {readme_path}: {exc}", file=sys.stderr)
			return 1
		return 0

	# Mermaid line chart: shebangsy minus bin (ms) vs bench run index; empty/placeholder if no data.
	def _mermaid_line_chart_overhead_vs_bin(records: list[dict]) -> str:
		# Sorted lang/asset keys for shebangsy* assets where that lang has bin in results (line chart).
		def _overhead_series_keys(rows: list[dict]) -> list[str]:
			keys: set[str] = set()
			for row in rows:
				results = row.get("results")
				if not isinstance(results, dict):
					continue
				for lang, assets in results.items():
					if not isinstance(assets, dict) or "bin" not in assets:
						continue
					for asset in assets:
						if asset == "bin" or "shebangsy" not in asset.lower():
							continue
						keys.add(f"{lang}/{asset}")
			return sorted(keys)

		empty_chart = "\n".join(
			[
				"```mermaid",
				_mermaid_xychart_frontmatter(series_count=1),
				"xychart-beta",
				'    title "No data yet"',
				'    x-axis ["-"]',
				'    y-axis "overhead ms" 0 --> 1',
				"    line [0]",
				"```",
			]
		)
		if not records:
			return empty_chart

		x_labels: list[str] = []
		for index, row in enumerate(records):
			ts = int(row["time"])
			stamp = datetime.fromtimestamp(ts).strftime("%m-%d %H:%M")
			x_labels.append(f"#{index + 1} {stamp}")

		series_names = _overhead_series_keys(records)
		if not series_names:
			return "\n".join(
				[
					"```mermaid",
					_mermaid_xychart_frontmatter(series_count=1),
					"xychart-beta",
					'    title "No bin baseline in data (need lang/bin per run)"',
					'    x-axis ["-"]',
					'    y-axis "overhead ms" 0 --> 1',
					"    line [0]",
					"```",
				]
			)

		series_rows: list[list[float]] = []
		for key in series_names:
			lang, _, asset = key.partition("/")
			last: float | None = None
			col: list[float] = []
			for row in records:
				delta = _overhead_ms_for_run(row, lang, asset)
				if delta is not None:
					last = delta
				if last is None:
					col.append(0.0)
				else:
					col.append(last)
			series_rows.append(col)

		flat_vals = [v for col in series_rows for v in col]
		lo = min(flat_vals)
		hi = max(flat_vals)
		span = max(hi - lo, 1e-6)
		pad = max(span * 0.1, 0.5)
		ymin = math.floor(lo - pad)
		ymax = math.ceil(hi + pad)
		if ymin == ymax:
			ymax = ymin + 1

		x_lit = ", ".join(json.dumps(_mermaid_axis_label(lbl)) for lbl in x_labels)
		palette_csv = _plot_color_palette_csv_for_flat_keys(series_names)
		lines_out: list[str] = [
			"```mermaid",
			_mermaid_xychart_frontmatter(
				series_count=len(series_names),
				plot_color_palette_csv=palette_csv,
			),
			"xychart-beta",
			'    title "Overhead vs bin: script ms minus lang/bin (lower is better)"',
			f"    x-axis [{x_lit}]",
			f'    y-axis "overhead ms" {ymin} --> {ymax}',
		]
		for col in series_rows:
			nums = ", ".join(str(round(v, 1)) for v in col)
			lines_out.append(f"    line [{nums}]")
		lines_out.append("```")
		return "\n".join(lines_out)

	# Latest jsonl record: horizontal bars of every app mean ms, or empty-state chart.
	def _mermaid_bar_latest(records: list[dict]) -> str:
		empty = "\n".join(
			[
				"```mermaid",
				_mermaid_xychart_frontmatter(series_count=1),
				"xychart-beta horizontal",
				'    title "No data yet"',
				'    x-axis ["-"]',
				'    y-axis "ms" 0 --> 1',
				"    bar [0]",
				"```",
			]
		)
		if not records:
			return empty

		flat = _flatten_results(records[-1]["results"])
		if not flat:
			return empty

		return _mermaid_horizontal_bar_absolute_time(
			"Latest run — mean time (ms) per app", list(flat.items())
		)

	# Horizontal bars: per-app mean ms over all loaded records (README Results + report).
	def _mermaid_bar_absolute_time_all_runs_mean(records: list[dict]) -> str:
		# Mean ms per lang/asset over last n bench rows (key omitted in a row skips that sample).
		def _absolute_time_mean_last_n(rows: list[dict], n: int) -> list[tuple[str, float]]:
			if not rows or n <= 0:
				return []
			window = rows[-min(n, len(rows)) :]
			keys: set[str] = set()
			for row in window:
				res = row.get("results")
				if not isinstance(res, dict):
					continue
				keys.update(_flatten_results(res).keys())
			items: list[tuple[str, float]] = []
			for key in keys:
				samples: list[float] = []
				for row in window:
					res = row.get("results")
					if not isinstance(res, dict):
						continue
					flat = _flatten_results(res)
					if key in flat:
						samples.append(float(flat[key]))
				if not samples:
					continue
				items.append((key, statistics.mean(samples)))
			return items

		placeholder = "\n".join(
			[
				"```mermaid",
				_mermaid_xychart_frontmatter(series_count=1),
				"xychart-beta horizontal",
				'    title "No timing rows in recent runs"',
				'    x-axis ["-"]',
				'    y-axis "ms" 0 --> 1',
				"    bar [0]",
				"```",
			]
		)
		if not records:
			return placeholder

		n = len(records)
		items = _absolute_time_mean_last_n(records, n)
		if not items:
			return placeholder

		title = f"Mean time (ms) per app — all time"
		return _mermaid_horizontal_bar_absolute_time(title, items)

	# Horizontal bars: mean shebangsy-vs-bin overhead over all runs, shebangsy assets only.
	def _mermaid_bar_shebangsy_overhead_all_runs_mean(records: list[dict]) -> str:
		# Mean (asset - bin) ms per shebangsy asset over last n rows where overhead is defined.
		def _shebangsy_overhead_mean_last_n(rows: list[dict], n: int) -> list[tuple[str, float]]:
			if not rows or n <= 0:
				return []
			window = rows[-min(n, len(rows)) :]
			keys: set[str] = set()
			for row in window:
				for key, _ in _latest_shebangsy_overhead_pairs(row.get("results")):
					keys.add(key)
			items: list[tuple[str, float]] = []
			for key in keys:
				lang, _, asset = key.partition("/")
				samples: list[float] = []
				for row in window:
					delta = _overhead_ms_for_run(row, lang, asset)
					if delta is not None:
						samples.append(delta)
				if not samples:
					continue
				items.append((key, statistics.mean(samples)))
			return items

		placeholder = "\n".join(
			[
				"```mermaid",
				_mermaid_xychart_frontmatter(series_count=1),
				"xychart-beta horizontal",
				'    title "No shebangsy overhead rows in recent runs"',
				'    x-axis ["-"]',
				'    y-axis "overhead ms" 0 --> 1',
				"    bar [0]",
				"```",
			]
		)
		if not records:
			return placeholder

		n = len(records)
		items = _sort_bar_items_by_language_cluster(
			_shebangsy_overhead_mean_last_n(records, n)
		)
		if not items:
			return placeholder

		names = [k for k, _ in items]
		labels = [json.dumps(_mermaid_axis_label(k)) for k in names]
		values = [round(v, 1) for _, v in items]
		lo = min(values)
		hi = max(values)
		span = max(hi - lo, 1e-6)
		pad = max(span * 0.1, 0.5)
		ymin = math.floor(lo - pad)
		ymax = math.ceil(hi + pad)
		if ymin == ymax:
			ymax = ymin + 1

		x_lit = ", ".join(labels)
		nums = ", ".join(str(v) for v in values)
		title = (
			f"Mean overhead vs bin — all {n} run(s), shebangsy only (lower is better)"
		)
		palette_csv = _plot_color_palette_csv_for_flat_keys(names)
		chart_body = "\n".join(
			[
				"```mermaid",
				_mermaid_xychart_frontmatter(
					series_count=len(names),
					plot_color_palette_csv=palette_csv,
				),
				"xychart-beta horizontal",
				f'    title "{title}"',
				f"    x-axis [{x_lit}]",
				f'    y-axis "overhead ms" {ymin} --> {ymax}',
				f"    bar [{nums}]",
				"```",
			]
		)
		return chart_body

	# Latest row only: horizontal bars of shebangsy overhead vs bin (same filter as line chart).
	def _mermaid_bar_latest_shebangsy_overhead(records: list[dict]) -> str:
		placeholder = "\n".join(
			[
				"```mermaid",
				_mermaid_xychart_frontmatter(series_count=1),
				"xychart-beta horizontal",
				'    title "No shebangsy overhead rows (need bin + shebangsy asset)"',
				'    x-axis ["-"]',
				'    y-axis "overhead ms" 0 --> 1',
				"    bar [0]",
				"```",
			]
		)
		if not records:
			return placeholder

		items = _sort_bar_items_by_language_cluster(
			_latest_shebangsy_overhead_pairs(records[-1].get("results"))
		)
		if not items:
			return placeholder

		names = [k for k, _ in items]
		labels = [json.dumps(_mermaid_axis_label(k)) for k in names]
		values = [round(v, 1) for _, v in items]
		lo = min(values)
		hi = max(values)
		span = max(hi - lo, 1e-6)
		pad = max(span * 0.1, 0.5)
		ymin = math.floor(lo - pad)
		ymax = math.ceil(hi + pad)
		if ymin == ymax:
			ymax = ymin + 1

		x_lit = ", ".join(labels)
		nums = ", ".join(str(v) for v in values)
		palette_csv = _plot_color_palette_csv_for_flat_keys(names)
		chart_body = "\n".join(
			[
				"```mermaid",
				_mermaid_xychart_frontmatter(
					series_count=len(names),
					plot_color_palette_csv=palette_csv,
				),
				"xychart-beta horizontal",
				'    title "Latest run — overhead vs bin (shebangsy only, lower is better)"',
				f"    x-axis [{x_lit}]",
				f'    y-axis "overhead ms" {ymin} --> {ymax}',
				f"    bar [{nums}]",
				"```",
			]
		)
		return chart_body

	jsonl_path = root_dir / "benches.jsonl"
	records = _load_benches_jsonl(jsonl_path)
	readme_path = root_dir / "README.md"
	chart = _mermaid_bar_absolute_time_all_runs_mean(records)
	readme_rc = _patch_readme_results_chart(readme_path, chart)
	if readme_rc != 0:
		return readme_rc

	report_path = root_dir / "benches-report.md"

	lines: list[str] = [
		"# Benchmark report",
		"",
		f"Generated from [`benches.jsonl`](./benches.jsonl) ({len(records)} run(s)).",
		"",
	]
	if records:
		last = records[-1]
		lines.extend(
			[
				f"**Latest run:** `time={last['time']}` · **CPU:** {last.get('cpu', '?')}",
				"",
			]
		)

	lines.extend(
		[
			"## Overhead vs `bin` over time",
			"",
			"Each line is **mean ms − same-language `bin` ms** for assets whose filename includes "
			"`shebangsy` (other runners are omitted). "
			"Use it to spot **regressions**: a line drifting **up** means shebangsy is slower vs the "
			"compiled baseline; **down** is better vs `bin`.",
			"",
			_mermaid_line_chart_overhead_vs_bin(records),
			"",
			"## Absolute time (ms) - most recent run",
			"",
			"Bars are ordered **by language** (A–Z), then **by time ascending** within each language "
			"(lower ms first). Axis labels are `lang/asset`; large values are clipped for scale.",
			"",
			_mermaid_bar_latest(records),
			"",
			"## Absolute time (ms) — mean of all runs",
			"",
			"**Mean ms per app** across every row in `benches.jsonl`. A run contributes a sample only if "
			"that app appears in that row’s results. Same ordering and cap as the latest-run chart.",
			"",
			_mermaid_bar_absolute_time_all_runs_mean(records),
			"",
			"## Overhead vs `bin` (shebangsy only)",
			"",
			"Bars are ordered **by language** (A–Z), then **by overhead ascending** (lower first).",
			"",
			"**Mean ms − same-language `bin` ms** for the latest row; same filename filter as the "
			"overhead line chart.",
			"",
			_mermaid_bar_latest_shebangsy_overhead(records),
			"",
			"## Overhead vs `bin` — mean of all runs (shebangsy only)",
			"",
			"**Mean of (script ms − bin ms)** across every row in `benches.jsonl`. Averaging includes only "
			"runs where that overhead is defined; same filename filter and bar ordering as the latest "
			"overhead chart above.",
			"",
			_mermaid_bar_shebangsy_overhead_all_runs_mean(records),
			"",
		]
	)

	lines.append(_language_color_legend_markdown())

	report_path.write_text("\n".join(lines), encoding="utf-8")
	print(f"bench.py: wrote {report_path.relative_to(root_dir)}")
	print(f"bench.py: wrote {readme_path.relative_to(root_dir)} (Results chart)")
	return 0


# build.sh, preflight cmds, hyperfine main+slow rounds, append benches.jsonl, then run_report.
def run_bench(root_dir: Path) -> int:
	# Echo captured child stdout/stderr to stderr after subprocess.check failures.
	def _print_subprocess_failure(exc: subprocess.CalledProcessError) -> None:
		if exc.stdout:
			sys.stderr.write(exc.stdout)
		if exc.stderr:
			sys.stderr.write(exc.stderr)

	# COMMAND_ALIASES plus slow_app interpreter invocations -> same lang/bin grouping key.
	def _merge_slow_interpreter_aliases() -> dict[str, str]:
		out = dict(COMMAND_ALIASES)
		for lang, spec in BENCH_LANGUAGE_META.items():
			interpreter = spec.get("interpreter")
			slow_apps = spec.get("slow_apps") or []
			if not interpreter or not slow_apps:
				continue
			report = _interpreted_baseline_report_path(lang)
			for app in slow_apps:
				hf = f'{interpreter} ./scripts/bench-assets/{lang}/{app}'
				out[_normalize_hyperfine_command(hf)] = report
		return out

	# Slow-pass hyperfine cmds (./asset and interpreter form) for existing slow_apps files only.
	def _collect_slow_benchmark_commands(repo_root: Path) -> list[str]:
		cmds: list[str] = []
		slow_assets_root = repo_root / "scripts" / "bench-assets"
		for lang, spec in BENCH_LANGUAGE_META.items():
			slow_apps = spec.get("slow_apps") or []
			interpreter = spec.get("interpreter")
			for app in slow_apps:
				path = slow_assets_root / lang / app
				if not path.is_file():
					continue
				rel = path.relative_to(repo_root)
				cmds.append(f"./{rel}")
				if interpreter:
					cmds.append(f'{interpreter} ./scripts/bench-assets/{lang}/{app}')
		return sorted(dict.fromkeys(cmds))

	# JSON leaf key: bench-assets asset name, or whole command if not under that tree.
	def _json_key_for_command(command_name: str) -> str:
		parts = _bench_asset_parts(command_name)
		if parts is None:
			return command_name
		return parts[1]

	# Short host id for jsonl metadata: sysctl on Darwin else platform.processor/machine.
	def _cpu_label() -> str:
		if sys.platform == "darwin":
			for key in ("machdep.cpu.brand_string", "hw.model"):
				try:
					completed = subprocess.run(
						["sysctl", "-n", key],
						capture_output=True,
						text=True,
						check=True,
					)
					label = completed.stdout.strip()
					if label:
						return label
				except (subprocess.CalledProcessError, FileNotFoundError):
					continue
		proc = platform.processor()
		if proc:
			return proc
		return platform.machine() or "unknown"

	# Append each result mean from one hyperfine --export-json into means_by_command lists.
	def _append_hyperfine_export_to_means(
		export_path: Path,
		means_by_command: dict[str, list[float]],
		command_aliases: dict[str, str],
	) -> None:
		# Map hyperfine command string to grouped path (alias hit) or original cmd.
		def _hyperfine_command_for_grouping(
			cmd: str, aliases: dict[str, str] | None = None
		) -> str:
			table = COMMAND_ALIASES if aliases is None else aliases
			stripped = _strip_cpu_taskpolicy_high_prefix(cmd)
			norm = _normalize_hyperfine_command(stripped)
			return table.get(norm, stripped)

		with export_path.open("r", encoding="utf-8") as file_handle:
			benchmark_data = json.load(file_handle)
		for result in benchmark_data["results"]:
			command_name = _hyperfine_command_for_grouping(
				result["command"], command_aliases
			)
			means_by_command.setdefault(command_name, []).append(result["mean"])

	bin_dir = root_dir / "dist"

	try:
		subprocess.run(
			["./scripts/build.sh"],
			cwd=root_dir,
			check=True,
			capture_output=True,
			text=True,
		)
	except subprocess.CalledProcessError as exc:
		_print_subprocess_failure(exc)
		return exc.returncode

	hyperfine = shutil.which("hyperfine")
	if hyperfine is None:
		print(
			"bench.py: hyperfine not found. Install it first (brew install hyperfine).",
			file=sys.stderr,
		)
		return 1

	command_paths: list[Path] = []
	assets_root = root_dir / "scripts" / "bench-assets"
	for lang, spec in BENCH_LANGUAGE_META.items():
		apps = spec.get("apps") or []
		if not isinstance(apps, list):
			print(
				f"bench.py: BENCH_LANGUAGE_META[{lang!r}]['apps'] must be a list",
				file=sys.stderr,
			)
			return 1
		for app in apps:
			path = assets_root / lang / app
			if not path.is_file():
				print(
					f"bench.py: missing bench asset (listed in BENCH_LANGUAGE_META): {path}",
					file=sys.stderr,
				)
				return 1
			command_paths.append(path)

	environment = os.environ.copy()
	environment["PATH"] = f"{bin_dir}:{environment['PATH']}"

	benchmark_commands = [
		f"./{p.relative_to(root_dir)}" for p in command_paths
	]

	for lang, spec in BENCH_LANGUAGE_META.items():
		interpreter = spec.get("interpreter")
		baseline_script = spec.get("baseline_script")
		if not interpreter or not baseline_script:
			continue
		report_bin = _interpreted_baseline_report_path(lang)
		if report_bin in benchmark_commands:
			continue
		script_path = assets_root / lang / baseline_script
		if not script_path.is_file():
			continue
		benchmark_commands.append(
			_interpreted_baseline_hyperfine_cmd(lang, interpreter, baseline_script)
		)

	command_aliases = _merge_slow_interpreter_aliases()
	for lang, spec in BENCH_LANGUAGE_META.items():
		for app in spec.get("slow_apps") or []:
			slow_path = assets_root / lang / app
			if not slow_path.is_file():
				print(
					"bench.py: missing slow bench asset (listed in BENCH_LANGUAGE_META): "
					f"{slow_path}",
					file=sys.stderr,
				)
				return 1

	slow_benchmark_commands = _collect_slow_benchmark_commands(root_dir)

	preflight_cmds = [
		_with_cpu_taskpolicy_high(c)
		for c in (benchmark_commands + slow_benchmark_commands)
	]
	print("bench.py: preflight: starting (running each command once)", flush=True)
	for bench_cmd in preflight_cmds:
		print(f"bench.py: preflight: {bench_cmd}", flush=True)
		try:
			subprocess.run(
				shlex.split(bench_cmd),
				cwd=root_dir,
				env=environment,
				check=True,
				capture_output=True,
				text=True,
			)
		except subprocess.CalledProcessError as exc:
			print(
				f"bench.py: command failed during preflight (exit {exc.returncode}): {bench_cmd}",
				file=sys.stderr,
			)
			_print_subprocess_failure(exc)
			return exc.returncode

	means_by_command: dict[str, list[float]] = {}

	# Alternate command order each round (forward / reversed / …) so first/last slots swap
	# between runs and ordering effects partially cancel in the mean.
	benchmark_order_base = list(benchmark_commands)
	for round_idx in range(HYPERFINE_BENCHMARK_ROUNDS):
		round_commands = [
			_with_cpu_taskpolicy_high(c)
			for c in (
				list(reversed(benchmark_order_base))
				if round_idx % 2 == 1
				else list(benchmark_order_base)
			)
		]

		order_note = " (reversed order)" if round_idx % 2 == 1 else ""
		print(
			f"Running benchmark round {round_idx + 1} of {HYPERFINE_BENCHMARK_ROUNDS}{order_note}"
		)

		with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as export_file:
			export_path = Path(export_file.name)

		command = [
			hyperfine,
			"--warmup",
			str(HYPERFINE_WARMUP_RUNS),
			"--runs",
			str(HYPERFINE_RUNS_PER_COMMAND),
			"--shell=none",
			f"--export-json={export_path}",
			*round_commands,
		]

		try:
			try:
				subprocess.run(
					command,
					cwd=root_dir,
					env=environment,
					check=True,
					capture_output=True,
					text=True,
				)
			except subprocess.CalledProcessError as exc:
				_print_subprocess_failure(exc)
				return exc.returncode

			_append_hyperfine_export_to_means(export_path, means_by_command, command_aliases)
		finally:
			export_path.unlink(missing_ok=True)

	if slow_benchmark_commands:
		print(
			"Running slow benchmarks (single round, "
			f"{HYPERFINE_SLOW_RUNS} runs per command)"
		)
		with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as export_file:
			slow_export_path = Path(export_file.name)
		slow_command = [
			hyperfine,
			"--warmup",
			str(HYPERFINE_WARMUP_RUNS),
			"--runs",
			str(HYPERFINE_SLOW_RUNS),
			"--shell=none",
			f"--export-json={slow_export_path}",
			*[_with_cpu_taskpolicy_high(c) for c in slow_benchmark_commands],
		]
		try:
			try:
				subprocess.run(
					slow_command,
					cwd=root_dir,
					env=environment,
					check=True,
					capture_output=True,
					text=True,
				)
			except subprocess.CalledProcessError as exc:
				_print_subprocess_failure(exc)
				return exc.returncode
			_append_hyperfine_export_to_means(
				slow_export_path, means_by_command, command_aliases
			)
		finally:
			slow_export_path.unlink(missing_ok=True)

	mean_by_command = {
		command_name: statistics.mean(samples)
		for command_name, samples in means_by_command.items()
	}

	grouped: dict[str, dict[str, float]] = {}
	for command_name, mean_seconds in mean_by_command.items():
		ms = round(mean_seconds * 1000, 1)
		parts = _bench_asset_parts(command_name)
		if parts is not None:
			language, asset_key = parts
		else:
			language, asset_key = "other", _json_key_for_command(command_name)
		grouped.setdefault(language, {})[asset_key] = ms

	payload = {
		language: dict(sorted(grouped[language].items(), key=lambda item: item[1]))
		for language in sorted(grouped.keys())
	}
	out_text = json.dumps(payload, indent=2)
	print(out_text)

	record = {
		"time": int(time.time()),
		"cpu": _cpu_label(),
		"results": payload,
	}
	jsonl_path = root_dir / "benches.jsonl"
	with jsonl_path.open("a", encoding="utf-8") as jsonl_file:
		jsonl_file.write(json.dumps(record, ensure_ascii=False) + "\n")

	return run_report(root_dir)


# Resolve repo root from scripts/ and return run_bench exit code.
def main() -> int:
	script_dir = Path(__file__).resolve().parent
	root_dir = script_dir.parent
	parser = argparse.ArgumentParser(
		description="Run hyperfine benchmarks or regenerate the markdown report from benches.jsonl.",
	)
	parser.add_argument(
		"--regenerate-report",
		action="store_true",
		help=(
			"Write benches-report.md and update README ### Results chart from existing "
			"benches.jsonl without running benchmarks."
		),
	)
	args = parser.parse_args()
	if args.regenerate_report:
		return run_report(root_dir)
	return run_bench(root_dir)


if __name__ == "__main__":
	raise SystemExit(main())
