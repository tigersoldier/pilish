#!/usr/bin/env bash
# run-window-rewrite-bench.sh - Compare full-range and bounded restoration
#
# Usage:
#   ./bench/run-window-rewrite-bench.sh                  # GUI via xvfb
#   ./bench/run-window-rewrite-bench.sh --batch          # secondary batch lane
#   ./bench/run-window-rewrite-bench.sh -c 1 --batch     # quick smoke
#   ./bench/run-window-rewrite-bench.sh --turns 200 --lines-per-turn 20
#   ./bench/run-window-rewrite-bench.sh --out-dir tmp/wr
#
# Each case/variant/iteration runs in a fresh Emacs process.  This keeps JIT
# timers and fontification state from contaminating the A/B comparison.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EMACS_BIN="${EMACS:-emacs}"
if [ -z "${PACKAGE_USER_DIR:-}" ]; then
    EMACS_MAJOR_VERSION=$("$EMACS_BIN" --batch -Q \
        --eval '(princ emacs-major-version)')
    export PACKAGE_USER_DIR="$PROJECT_DIR/.cache/elpa/$EMACS_MAJOR_VERSION"
fi

BATCH=0
REPS=3
TURNS=200
LINES_PER_TURN=20
OUT_DIR=""

usage() {
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

require_arg() {
    local option="$1"
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: $option requires an argument" >&2
        usage >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --batch) BATCH=1; shift ;;
        -c|--count)
            require_arg "$1" "${2:-}"
            REPS="$2"
            shift 2
            ;;
        --turns)
            require_arg "$1" "${2:-}"
            TURNS="$2"
            shift 2
            ;;
        --lines-per-turn)
            require_arg "$1" "${2:-}"
            LINES_PER_TURN="$2"
            shift 2
            ;;
        --out-dir)
            require_arg "$1" "${2:-}"
            OUT_DIR="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for item in "$REPS" "$TURNS" "$LINES_PER_TURN"; do
    if ! [[ "$item" =~ ^[0-9]+$ ]] || [[ "$item" -lt 1 ]]; then
        echo "ERROR: counts and transcript dimensions must be positive integers" >&2
        exit 1
    fi
done

if [[ -z "$OUT_DIR" ]]; then
    if [[ "$BATCH" == "1" ]]; then lane="batch"; else lane="gui"; fi
    OUT_DIR="$PROJECT_DIR/tmp/window-rewrite-bench/$lane"
fi
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$PROJECT_DIR/$OUT_DIR" ;;
esac
while [[ "$OUT_DIR" != "/" && "$OUT_DIR" == */ ]]; do
    OUT_DIR="${OUT_DIR%/}"
done
if [[ -z "$OUT_DIR" || "$OUT_DIR" == "/" ]]; then
    echo "ERROR: refusing unsafe output directory: $OUT_DIR" >&2
    exit 1
fi

BENCH_MARKER="$OUT_DIR/.pilish-window-rewrite-bench"
if [[ -L "$OUT_DIR" ]]; then
    echo "ERROR: refusing symlink output directory: $OUT_DIR" >&2
    exit 1
fi
if [[ -e "$OUT_DIR" && ! -d "$OUT_DIR" ]]; then
    echo "ERROR: refusing to replace non-directory output path: $OUT_DIR" >&2
    exit 1
fi
if [[ -d "$OUT_DIR" && ! -f "$BENCH_MARKER" ]] \
   && find "$OUT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "ERROR: refusing to remove non-empty output directory without benchmark marker: $OUT_DIR" >&2
    exit 1
fi

if [[ "$BATCH" != "1" ]] && ! command -v xvfb-run >/dev/null 2>&1; then
    echo "ERROR: xvfb-run not found. Install xvfb or use --batch." >&2
    exit 1
fi

export PI_WR_BENCH_PROJECT_DIR="$PROJECT_DIR"
EMACS_INIT=(
    -Q -L "$PROJECT_DIR"
    --eval '(setq inhibit-startup-screen t load-prefer-newer t)'
    --eval '(require (quote package))'
    --eval '(let ((dir (getenv "PACKAGE_USER_DIR"))) (when dir (setq package-user-dir (directory-file-name (expand-file-name dir)))))'
    --eval '(package-initialize)'
    --eval '(add-to-list (quote treesit-extra-load-path) (expand-file-name "~/.emacs.d/tree-sitter"))'
    --eval '(let ((project (getenv "PI_WR_BENCH_PROJECT_DIR"))) (setq load-path (cons (expand-file-name project) load-path)))'
    -l "$SCRIPT_DIR/pilish-window-rewrite-bench.el"
)

if [[ "$BATCH" == "1" ]]; then
    MODE="batch"
else
    MODE="gui-xvfb"
fi
printf '=== Pilish Window-Rewrite A/B Benchmark ===\n'
printf 'Project: %s\nMode: %s\nTranscript: %d turns x %d lines\nRepetitions: %d\n\n' \
    "$PROJECT_DIR" "$MODE" "$TURNS" "$LINES_PER_TURN" "$REPS"

rm -rf -- "$OUT_DIR"
mkdir -p -- "$OUT_DIR"
touch -- "$BENCH_MARKER"

for case_name in middle short-tail; do
    for variant in full-range bounded; do
        for ((iteration = 1; iteration <= REPS; iteration++)); do
            run_dir="$OUT_DIR/$case_name/$variant/iter-$(printf '%02d' "$iteration")"
            mkdir -p "$run_dir"
            export PI_WR_BENCH_CASE="$case_name"
            export PI_WR_BENCH_VARIANT="$variant"
            export PI_WR_BENCH_ITERATION="$iteration"
            export PI_WR_BENCH_TURNS="$TURNS"
            export PI_WR_BENCH_LINES_PER_TURN="$LINES_PER_TURN"
            export PI_WR_BENCH_OUT_DIR="$run_dir"

            printf '[%s/%s/%s] running\n' "$case_name" "$variant" "$iteration"
            if [[ "$BATCH" == "1" ]]; then
                if ! "$EMACS_BIN" --batch "${EMACS_INIT[@]}" \
                    -f pilish-wr-bench-run-batch \
                    > "$run_dir/stdout.log" 2> "$run_dir/stderr.log"; then
                    cat "$run_dir/stdout.log"
                    cat "$run_dir/stderr.log" >&2
                    exit 1
                fi
            else
                if ! xvfb-run -a env GDK_BACKEND=x11 PATH="$PATH" \
                    "$EMACS_BIN" --geometry 120x40 "${EMACS_INIT[@]}" \
                    --eval '(let ((standard-output (function external-debugging-output))) (condition-case err (kill-emacs (if (pilish-wr-bench--run-one) 0 1)) (error (princ (format "Benchmark error: %s\n" err)) (kill-emacs 1))))' \
                    </dev/null > "$run_dir/stdout.log" 2> "$run_dir/stderr.log"; then
                    cat "$run_dir/stdout.log"
                    cat "$run_dir/stderr.log" >&2
                    exit 1
                fi
            fi
        done
    done
done

python3 - "$OUT_DIR" "$MODE" "$REPS" "$TURNS" "$LINES_PER_TURN" <<'PY'
from __future__ import annotations

import csv
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

out = Path(sys.argv[1])
mode = sys.argv[2]
reps = int(sys.argv[3])
turns = int(sys.argv[4])
lines_per_turn = int(sys.argv[5])
rows: list[dict[str, Any]] = []

for result_path in sorted(out.glob("**/result.json")):
    with result_path.open(encoding="utf-8") as handle:
        result = json.load(handle)
    rows.append(
        {
            "case": result.get("case"),
            "variant": result.get("variant"),
            "iteration": result.get("iteration"),
            "ok": result.get("ok") is True,
            "restoreMs": float(result.get("restoreMs") or 0),
            "timerDelta": int(result.get("timerCountDelta") or 0),
            "timerAfter": int(result.get("timerCountAfter") or 0),
            "gcCount": int(result.get("gcCount") or 0),
            "gcMs": float(result.get("gcMs") or 0),
            "bufferLines": int(result.get("bufferLines") or 0),
            "bodyHeight": int(result.get("bodyHeight") or 0),
            "restoreBranch": result.get("restoreBranch") or "",
            "expectedBranch": result.get("expectedBranch") or "",
            "windowStart": result.get("windowStart"),
            "windowEnd": result.get("windowEnd"),
            "pointRow": result.get("pointRow"),
            "viewportOk": result.get("viewportPreserved") is True,
            "markdownGrammarAvailable": result.get("markdownGrammarAvailable") is True,
            "error": result.get("error") or "",
            "resultPath": str(result_path),
        }
    )

csv_path = out / "summary.csv"


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1)]


groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
for row in rows:
    groups[(str(row["case"]), str(row["variant"]))].append(row)

pairs: dict[tuple[str, Any], dict[str, dict[str, Any]]] = defaultdict(dict)
for row in rows:
    pairs[(str(row["case"]), row["iteration"])][str(row["variant"])] = row
for (case_name, iteration), pair in pairs.items():
    full_range = pair.get("full-range")
    bounded = pair.get("bounded")
    if full_range and bounded and (
        full_range["windowStart"] != bounded["windowStart"]
        or full_range["pointRow"] != bounded["pointRow"]
    ):
        error = (
            f"viewport differs between algorithms at iteration {iteration}: "
            f"start {full_range['windowStart']} vs {bounded['windowStart']}, "
            f"point row {full_range['pointRow']} vs {bounded['pointRow']}"
        )
        for row in (full_range, bounded):
            row["ok"] = False
            row["error"] = error

if rows:
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

summary = [
    "# Pilish window-rewrite A/B benchmark",
    "",
    "Synthetic Markdown transcript; timings are diagnostic, with no pass/fail threshold.",
    "",
    f"- Mode: `{mode}`; repetitions: `{reps}`",
    f"- Transcript: `{turns}` turns × `{lines_per_turn}` lines per turn",
    "- Full-range uses whole-range screen-line counts and recentering; bounded uses production restore code.",
    "- Each measurement ran in a fresh Emacs process; GUI/xvfb is primary because JIT-lock and font metrics matter.",
    f"- Markdown tree-sitter grammar available on all runs: `{bool(rows) and all(row['markdownGrammarAvailable'] for row in rows)}`",
    "- p95 uses nearest-rank and is omitted when fewer than 20 successful samples are available.",
    "",
    "| viewport | variant | median restore ms | p95 restore ms (n≥20) | max restore ms | median timer delta | median GC ms | buffer lines | successful runs |",
    "|---|---|---:|---:|---:|---:|---:|---:|---:|",
]
print("\nA/B summary")
print("viewport     variant  median-ms  p95-ms  max-ms  timers-med  GC-ms  lines  ok")
comparison_notes: list[str] = []
for case_name in ("middle", "short-tail"):
    for variant in ("full-range", "bounded"):
        items = groups.get((case_name, variant), [])
        good = [row for row in items if row["ok"]]
        if not good:
            print(f"{case_name:<12} {variant:<7} no successful runs")
            summary.append(f"| {case_name} | {variant} | n/a | n/a | n/a | n/a | n/a | n/a | 0/{len(items)} |")
            continue
        times = [float(row["restoreMs"]) for row in good]
        timers = [float(row["timerDelta"]) for row in good]
        gc_ms = [float(row["gcMs"]) for row in good]
        median_ms = statistics.median(times)
        p95_ms = percentile(times, 0.95) if len(times) >= 20 else None
        p95_text = f"{p95_ms:.2f}" if p95_ms is not None else "n/a"
        max_ms = max(times)
        print(f"{case_name:<12} {variant:<7} {median_ms:9.2f} {p95_text:>7} {max_ms:7.2f} {statistics.median(timers):11.0f} {statistics.median(gc_ms):6.2f} {good[0]['bufferLines']:6d} {len(good)}/{len(items)}")
        summary.append(
            f"| {case_name} | {variant} | {median_ms:.2f} | {p95_text} | {max_ms:.2f} | "
            f"{statistics.median(timers):.0f} | {statistics.median(gc_ms):.2f} | "
            f"{good[0]['bufferLines']} | {len(good)}/{len(items)} |"
        )
    full_range = groups.get((case_name, "full-range"), [])
    bounded = groups.get((case_name, "bounded"), [])
    full_range_times = [float(row["restoreMs"]) for row in full_range if row["ok"]]
    bounded_times = [float(row["restoreMs"]) for row in bounded if row["ok"]]
    if full_range_times and bounded_times:
        full_range_median = statistics.median(full_range_times)
        bounded_median = statistics.median(bounded_times)
        comparison_notes.append(
            f"- `{case_name}` median restore time: full-range "
            f"`{full_range_median:.2f} ms`; bounded `{bounded_median:.2f} ms`."
        )

failed = [row for row in rows if not row["ok"]]
summary.extend(["", *comparison_notes, "", "## Artifacts", "", f"- CSV: `{csv_path}`", "- Per-run JSON: `CASE/ALGORITHM/iter-NN/result.json`"])
if failed:
    summary.extend(["", "## Failed runs", ""])
    for row in failed:
        summary.append(f"- {row['case']} {row['variant']} iter {row['iteration']}: {row['error'] or 'correctness check failed'} ({row['resultPath']})")
summary_path = out / "summary.md"
summary_path.write_text("\n".join(summary) + "\n", encoding="utf-8")
print(f"\nWrote {csv_path}")
print(f"Wrote {summary_path}")
if not rows:
    print("ERROR: no benchmark result rows found", file=sys.stderr)
    raise SystemExit(1)
incomplete = any(
    len(groups.get((case_name, variant), [])) != reps
    for case_name in ("middle", "short-tail")
    for variant in ("full-range", "bounded")
)
if failed or incomplete:
    print("ERROR: benchmark run or result matrix incomplete", file=sys.stderr)
    raise SystemExit(1)
PY
