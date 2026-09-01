#!/usr/bin/env python3
"""
Stitches each target's per-day offline coverage_over_time.csv (produced by
measure_coverage.sh) across the whole angora/libafl/aflplusplus saturation
rotation (day1_angora, day2_libafl, day3_aflpp, day4_angora, ...) into one
continuous branch-coverage-over-time line per target, with 24h background
bands colored by which fuzzer was running that day.

Coverage totals (branches_covered/branches_total) differ per target, so this
writes one PNG per target rather than one combined chart -- see
rotation_coverage_<target>.png under the output dir (default: the rotation
root itself, saturation_rotate/).

Usage:
    tools/plot_rotation_coverage.py [ROTATION_DIR] [-o OUTPUT_DIR]

    ROTATION_DIR  directory containing day1_<fuzzer>, day2_<fuzzer>, ...
                  (default: /data2/projects/reusing/seed/saturation_rotate)
    -o OUTPUT_DIR where to write the PNGs (default: ROTATION_DIR itself)
"""

import argparse
import re
import sys
from pathlib import Path

try:
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError as e:
    print(f"Error: {e.name} is required. Install with: pip install numpy matplotlib")
    sys.exit(1)

DEFAULT_ROTATION_DIR = "/data2/projects/reusing/seed/saturation_rotate"
DAY_RE = re.compile(r"^day(\d+)_(angora|libafl|aflpp)$")

# fuzzer -> (coverage subdir name, display label, categorical color).
# Colors are the dataviz skill's default categorical palette, slots 1-3
# (blue/orange/aqua) -- documented as passing all-pairs CVD + normal-vision
# checks in both light and dark mode, so this exact 3-color set is used as-is.
FUZZER_INFO = {
    "angora":  ("angora",             "Angora",  "#2a78d6"),
    "libafl":  ("forkserver_libafl",  "LibAFL",  "#eb6834"),
    "aflpp":   ("aflplusplus",        "AFL++",   "#1baf7a"),
}

HOURS_PER_DAY = 24.0

# Same fixed-bottom / spread-capped-top margin logic as plot_coverage.py's
# set_ylim_with_margin, so these graphs read at the same visual scale instead
# of hugging the top of the frame.
BOTTOM_MARGIN = 20


def set_ylim_with_margin(ax, all_values):
    if not all_values:
        return
    min_val = min(all_values)
    max_val = max(all_values)
    spread = max_val - min_val
    spread_cap = max(spread * 0.5, 1)

    bottom_margin = min(BOTTOM_MARGIN, spread_cap)
    top_margin = min(max(max_val * 0.03, 10), spread_cap)

    ax.set_ylim(min_val - bottom_margin, max_val + top_margin)


def discover_days(rotation_dir: Path):
    """Return sorted [(day_num, fuzzer_key), ...] for dayN_<fuzzer> dirs found."""
    days = []
    for entry in rotation_dir.iterdir():
        if not entry.is_dir():
            continue
        m = DAY_RE.match(entry.name)
        if not m:
            continue
        day_num, fuzzer_key = int(m.group(1)), m.group(2)
        days.append((day_num, fuzzer_key, entry))
    days.sort(key=lambda t: t[0])
    return days


def target_key(name: str) -> str:
    return name.replace("-", "_")


def is_stale(csv_path: Path) -> bool:
    """
    True if cumulative_inputs is exactly constant across the whole file --
    the signature of a coverage measurement that never actually saw new
    inputs (e.g. day2_libafl's csvs, measured before archive_queue.sh's
    id:* filter bug was fixed: the live archives it replays are themselves
    all-empty deltas beyond the iter_0000 baseline, so re-measuring today
    can't recover it either). Treated as "no coverage result" and skipped.
    (Not just non-increasing: day1_angora's ffmpeg csv has two iter=0 rows
    with cumulative_inputs 1096 then 1057, a real non-determinism blip, not
    a frozen/stale measurement -- so a plain max<=first check would wrongly
    drop it too.)
    """
    try:
        with open(csv_path) as f:
            header = f.readline().strip().split(",")
            i_cum = header.index("cumulative_inputs")
            values = []
            for line in f:
                parts = line.strip().split(",")
                if len(parts) <= i_cum:
                    continue
                values.append(float(parts[i_cum]))
    except (OSError, ValueError):
        return True
    if len(values) < 2:
        return False
    return all(v == values[0] for v in values)


def collect_target_series(days):
    """
    Returns {target: [(day_num, fuzzer_key, csv_path), ...]} sorted by day_num,
    scanning coverage/<fuzzer_subdir>/<target>/0/coverage_over_time.csv under
    each day's directory. A day whose csv is stale (see is_stale) is dropped
    from that target's series entirely, same as if the file didn't exist --
    the chart just skips that stretch instead of drawing a flat wrong line.
    """
    series = {}
    for day_num, fuzzer_key, day_dir in days:
        subdir, _, _ = FUZZER_INFO[fuzzer_key]
        cov_root = day_dir / "coverage" / subdir
        if not cov_root.is_dir():
            continue
        for target_dir in sorted(cov_root.iterdir()):
            if not target_dir.is_dir():
                continue
            csv_path = target_dir / "0" / "coverage_over_time.csv"
            if not csv_path.is_file() or is_stale(csv_path):
                continue
            key = target_key(target_dir.name)
            series.setdefault(key, []).append((day_num, fuzzer_key, csv_path))
    for key in series:
        series[key].sort(key=lambda t: t[0])
    return series


def read_csv(csv_path: Path):
    """Returns (elapsed_hours[], branches_covered[]) for one campaign's csv."""
    hours, covered = [], []
    with open(csv_path) as f:
        header = f.readline()
        cols = header.strip().split(",")
        try:
            i_elapsed = cols.index("elapsed_seconds")
            i_cov = cols.index("branches_covered")
        except ValueError:
            return np.array([]), np.array([])
        for line in f:
            parts = line.strip().split(",")
            if len(parts) <= max(i_elapsed, i_cov):
                continue
            try:
                hours.append(float(parts[i_elapsed]) / 3600.0)
                covered.append(float(parts[i_cov]))
            except ValueError:
                continue
    return np.array(hours), np.array(covered)


def build_continuous(entries):
    """
    entries: [(day_num, fuzzer_key, csv_path), ...] sorted by day_num for one target.
    Returns (x_hours[], y_branches_covered[]) with a NaN inserted wherever the
    day sequence has a gap, so the line breaks instead of misleadingly
    bridging missing/skipped days.
    """
    xs, ys = [], []
    prev_day = None
    for day_num, _fuzzer_key, csv_path in entries:
        if prev_day is not None and day_num != prev_day + 1:
            xs.append(np.nan)
            ys.append(np.nan)
        h, covered = read_csv(csv_path)
        if h.size == 0:
            prev_day = day_num
            continue
        xs.extend((day_num - 1) * HOURS_PER_DAY + h)
        ys.extend(covered)
        prev_day = day_num
    return np.array(xs), np.array(ys)


def plot_target(target: str, entries, days, output_dir: Path):
    x, y = build_continuous(entries)
    if x.size == 0:
        return False

    fig, ax = plt.subplots(figsize=(12, 8))

    # Background bands: one per day, colored by that day's fuzzer, using the
    # GLOBAL day list (not just days this target has data for) so every
    # target's chart shares the same x-axis reference frame.
    seen_fuzzers = set()
    for day_num, fuzzer_key, _dir in days:
        _subdir, label, color = FUZZER_INFO[fuzzer_key]
        start = (day_num - 1) * HOURS_PER_DAY
        ax.axvspan(start, start + HOURS_PER_DAY, color=color, alpha=0.10, lw=0)
        seen_fuzzers.add(fuzzer_key)

    ax.plot(x, y, color="#0b0b0b", lw=2, solid_capstyle="round")

    ax.set_xlabel("Hours since rotation start")
    ax.set_ylabel("Branches covered")
    ax.set_title(f"{target} -- branch coverage across the saturation rotation")
    max_hour = max((d[0] for d in days), default=1) * HOURS_PER_DAY
    ax.set_xlim(0, max_hour)
    set_ylim_with_margin(ax, [v for v in y if not np.isnan(v)])
    ax.grid(True, alpha=0.3)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    # Legend: one swatch per fuzzer actually present in the global day range.
    from matplotlib.patches import Patch
    handles = [
        Patch(facecolor=FUZZER_INFO[k][2], alpha=0.35, label=FUZZER_INFO[k][1])
        for k in ("angora", "libafl", "aflpp") if k in seen_fuzzers
    ]
    ax.legend(handles=handles, loc="lower right", frameon=False)

    fig.tight_layout()
    out_path = output_dir / f"rotation_coverage_{target}.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rotation_dir", nargs="?", default=DEFAULT_ROTATION_DIR,
                     help=f"directory with day1_<fuzzer>, day2_<fuzzer>, ... (default: {DEFAULT_ROTATION_DIR})")
    ap.add_argument("-o", "--output-dir", default=None,
                     help="where to write PNGs (default: rotation_dir itself)")
    args = ap.parse_args()

    rotation_dir = Path(args.rotation_dir)
    output_dir = Path(args.output_dir) if args.output_dir else rotation_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    days = discover_days(rotation_dir)
    if not days:
        print(f"[ERROR] no day<N>_<angora|libafl|aflpp> directories found under {rotation_dir}")
        sys.exit(1)

    print(f"[INFO] rotation: {', '.join(f'day{n}_{f}' for n, f, _ in days)}")

    series = collect_target_series(days)
    if not series:
        print("[ERROR] no coverage_over_time.csv files found under any day's coverage/<fuzzer>/<target>/0/")
        sys.exit(1)

    written = 0
    for target in sorted(series):
        if plot_target(target, series[target], days, output_dir):
            written += 1
            print(f"[INFO] wrote {output_dir / f'rotation_coverage_{target}.png'}")
        else:
            print(f"[WARN] {target}: no usable data points, skipped")

    print(f"[INFO] done: {written}/{len(series)} target graphs written to {output_dir}")


if __name__ == "__main__":
    main()
