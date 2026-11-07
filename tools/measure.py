#!/usr/bin/env python3
"""Run kitchen's measurement build and summarize its versioned CSV output."""
import argparse
import csv
import io
import json
import math
import statistics
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fabrum", type=Path, help="Local fabrum checkout passed to Zig's --fork")
parser.add_argument("--renderer", type=Path, help="Local renderer checkout passed to Zig's --fork")
parser.add_argument("--out", type=Path, help="Results directory (default: a new temporary directory)")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--frame-policy", choices=("present-once", "batched"), default="present-once")
args = parser.parse_args()
if args.runs < 1:
    parser.error("--runs must be positive")
kitchen = Path(__file__).resolve().parents[1]
work = args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix="kitchen-measure-"))
work.mkdir(parents=True, exist_ok=True)
command = ["zig", "build", "measure", "-Doptimize=ReleaseFast", "-Dphase_timings=true"]
for checkout in (args.fabrum, args.renderer):
    if checkout:
        command += ["--fork", str(checkout.resolve())]
command += ["--", "--overlay", "--quiet", "--bench", "--out", str(work / "snapshots"), "--frame-policy", args.frame_policy.replace("-", "_")]
(work / "metadata.json").write_text(json.dumps({"frame_policy": args.frame_policy, "runs": args.runs, "command": command}, indent=2) + "\n")
print(f"Kitchen measurement results: {work}", flush=True)
rows = []
for run in range(args.runs):
    result = subprocess.run(command, cwd=kitchen, text=True, capture_output=True)
    (work / f"run-{run + 1}.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout + result.stderr)
        raise SystemExit(result.returncode)
    trace = "\n".join(line.removeprefix("TRACE,") for line in result.stdout.splitlines() if line.startswith("TRACE,"))
    current = list(csv.DictReader(io.StringIO(trace)))
    if not current:
        raise SystemExit("Kitchen produced no trace rows")
    for row in current:
        row.update({key: int(value) for key, value in row.items() if key != "step"})
        row["run"] = run + 1
        # Exclusive accounting: frame includes views/layout/commands/reconcile.
        accounted = sum(row[key] for key in ("frame_ns", "damage_ns", "render_ns", "composite_ns", "input_ns", "resize_ns"))
        if accounted > row["total_ns"] or row["frames"] < 1:
            raise SystemExit(f"Invalid matched timing row: {row}")
        row["other_ns"] = row["total_ns"] - accounted
        row["frame_other_ns"] = row["frame_ns"] - sum(row[key] for key in ("views_ns", "layout_ns", "commands_ns", "reconcile_ns"))
        if row["frame_other_ns"] < 0:
            raise SystemExit(f"Overlapping frame phases: {row}")
    covered = {row["step"] for row in current}
    if not {"initial", "hover-green", "type-line", "type-notes", "drag-slider", "scroll-page", "scroll-back", "animation", "resize"} <= covered:
        raise SystemExit("Missing interaction trace coverage")
    if not { (640, 560), (960, 800), (800, 700) } <= {(row["width"], row["height"]) for row in current if row["step"] == "resize"}:
        raise SystemExit("Resize workload did not cover all viewport sizes")
    rows.extend(current)
    print(f"Run {run + 1}: {len(current)} matched updates; damage checks passed", flush=True)
with (work / "frames.csv").open("w", newline="") as output:
    writer = csv.DictWriter(output, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)


def workload(step):
    if step.startswith("type-"):
        return "typing"
    if step.startswith("scroll-"):
        return "scrolling"
    if step.startswith("hover-"):
        return "hover"
    if step == "drag-slider":
        return "dragging"
    if step in ("initial", "animation", "resize"):
        return step
    return "other-input"


summary = {}
for group in dict.fromkeys(workload(row["step"]) for row in rows):
    subset = [row for row in rows if workload(row["step"]) == group]
    totals = sorted(row["total_ns"] for row in subset)
    ns_fields = [key for key in subset[0] if key.endswith("_ns")]
    summary[group] = {
        "updates": len(subset),
        "runtime_frames": sum(row["frames"] for row in subset),
        "median_total_ns": statistics.median(totals),
        "p95_total_ns": totals[math.ceil(len(totals) * .95) - 1],
        "mean_ns": {key: statistics.mean(row[key] for row in subset) for key in ns_fields},
        "mean_commands": statistics.mean(row["commands"] for row in subset),
        "mean_damage_pixels": statistics.mean(row["damage_pixels"] for row in subset),
    }
(work / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
