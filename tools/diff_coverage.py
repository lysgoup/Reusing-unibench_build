#!/usr/bin/env python3
"""
Coverage DIFF visualization script.

For every target, plot the branch-coverage *difference* over time between each
fuzzer and a baseline fuzzer (default: ``angora``), i.e. ``fuzzer - angora``.

The Y axis is a signed difference and is drawn symmetrically around 0
(``-n .. +n``); the X axis is elapsed time. A positive value at time t means the
fuzzer covered more branches than the baseline at that snapshot; a negative
value means it covered fewer.

Three families of graphs are produced for every target:

  1. per-trial diff  ({target}_{fuzzer}_minus_{baseline}_pertrial_diff.png)
       one faint line per matched trial (fuzzer[trial] - baseline[trial]),
       plus a bold mean-diff line.

  2. trial-averaged diff  ({target}_{fuzzer}_minus_{baseline}_avg_diff.png)
       the mean diff over trials, with a shaded 95% confidence interval
       (Student's t) of the mean across trials.

  3. fuzzer comparison  ({target}_comparison_minus_{baseline}_diff.png)
       every fuzzer's mean diff vs the baseline overlaid on one graph
       (fuzzer1 - baseline, fuzzer2 - baseline, ...).

Input is read from the same place plot_coverage.py uses:

  coverage/
  ├── {fuzzer}/
  │   ├── {target}/
  │   │   ├── {trial_id}/
  │   │   │   └── coverage.log
  │   │   └── ...

If a ``coverage/`` directory is not available, the script falls back to the
pre-parsed data files written by plot_coverage.py under
``graph/data/{target}_{fuzzer}_branch_count.txt``.
"""

import sys
import re
from pathlib import Path
import argparse
from collections import defaultdict

try:
    import matplotlib
    matplotlib.use("Agg")  # headless / no display
    import matplotlib.pyplot as plt
    from matplotlib.ticker import MaxNLocator
except ImportError:
    print("Error: matplotlib is required. Install with: pip install matplotlib")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def _trial_key(trial_id):
    """Sort key for a trial/campaign id: numeric when possible, else string."""
    try:
        return (0, int(trial_id))
    except (TypeError, ValueError):
        return (1, str(trial_id))


def extract_branch_hit_counts(coverage_log_path):
    """
    Extract the branch-hit-count time series from a coverage.log file.

    Format: repeated 3-line blocks (lines / functions / branches). Every 3rd
    line (index 2, 5, 8, ...) reads like:
        branches..: X% (N of M branches)
    We return the ordered list of N values (one per snapshot).
    """
    try:
        with open(coverage_log_path, "r") as f:
            lines = f.readlines()

        branch_counts = []
        for i in range(2, len(lines), 3):
            match = re.search(r"\((\d+) of \d+ branches\)", lines[i])
            if match:
                branch_counts.append(int(match.group(1)))

        return branch_counts if branch_counts else None
    except Exception as e:
        print(f"Error reading {coverage_log_path}: {e}", file=sys.stderr)
        return None


def load_from_coverage_dir(coverage_dir):
    """
    Parse coverage/{fuzzer}/{target}/{trial}/coverage.log.

    Returns: data[target][fuzzer][trial_id] = [counts...]
    """
    coverage_dir = Path(coverage_dir)
    data = defaultdict(lambda: defaultdict(dict))

    for fuzzer_path in sorted(coverage_dir.iterdir()):
        if not fuzzer_path.is_dir():
            continue
        fuzzer_name = fuzzer_path.name

        for target_path in sorted(fuzzer_path.iterdir()):
            if not target_path.is_dir():
                continue
            target_name = target_path.name

            for campaign_path in sorted(target_path.iterdir()):
                if not campaign_path.is_dir():
                    continue
                trial_id = campaign_path.name

                coverage_log = campaign_path / "coverage.log"
                if not coverage_log.exists():
                    continue

                counts = extract_branch_hit_counts(str(coverage_log))
                if counts:
                    data[target_name][fuzzer_name][trial_id] = counts

    return data


def load_from_graph_data(data_dir):
    """
    Parse the pre-computed graph/data/{target}_{fuzzer}_branch_count.txt files
    that plot_coverage.py writes.

    File format (one trial per line, plus a final 'avg' line we ignore):
        {trial_id} c0 c1 c2 ...
        avg        a0 a1 a2 ...

    Returns: data[target][fuzzer][trial_id] = [counts...]
    """
    data_dir = Path(data_dir)
    data = defaultdict(lambda: defaultdict(dict))

    for data_file in sorted(data_dir.glob("*_branch_count.txt")):
        filename = data_file.stem.replace("_branch_count", "")
        parts = filename.split("_", 1)
        if len(parts) != 2:
            print(f"Warning: could not parse filename: {data_file.name}")
            continue
        target_name, fuzzer_name = parts[0], parts[1]

        try:
            with open(data_file, "r") as f:
                lines = f.readlines()
        except Exception as e:
            print(f"Error reading {data_file}: {e}", file=sys.stderr)
            continue

        for line in lines:
            toks = line.strip().split()
            if not toks or toks[0] == "avg":
                continue
            trial_id = toks[0]
            try:
                counts = [int(float(x)) for x in toks[1:]]
            except ValueError:
                continue
            if counts:
                data[target_name][fuzzer_name][trial_id] = counts

    return data


def load_all_data(workdir):
    """
    Load branch-count series for every target/fuzzer/trial.

    Prefers the authoritative coverage/ directory; falls back to the pre-parsed
    graph/data/ files written by plot_coverage.py.

    Returns: data[target][fuzzer][trial_id] = [counts...]  (plain nested dict)
    """
    workdir = Path(workdir).resolve()
    coverage_dir = workdir / "coverage"
    graph_data_dir = workdir / "graph" / "data"

    if coverage_dir.exists() and any(coverage_dir.iterdir()):
        print(f"✓ Reading coverage data from: {coverage_dir}")
        data = load_from_coverage_dir(coverage_dir)
        if data:
            return {t: {f: dict(tr) for f, tr in fz.items()} for t, fz in data.items()}
        print("  (no usable coverage.log files found; trying graph/data/ ...)")

    if graph_data_dir.exists():
        print(f"✓ Reading coverage data from: {graph_data_dir}")
        data = load_from_graph_data(graph_data_dir)
        if data:
            return {t: {f: dict(tr) for f, tr in fz.items()} for t, fz in data.items()}

    print(
        "Error: no coverage data found. Expected either\n"
        f"  {coverage_dir}/<fuzzer>/<target>/<trial>/coverage.log\n"
        f"  or {graph_data_dir}/<target>_<fuzzer>_branch_count.txt"
    )
    return None


# ---------------------------------------------------------------------------
# Diff computation
# ---------------------------------------------------------------------------

def diff_series(a, b):
    """Elementwise a - b, truncated to the shorter series."""
    n = min(len(a), len(b))
    return [a[i] - b[i] for i in range(n)]


def average_series(series_list):
    """Column-wise mean over the common (minimum) length of all series."""
    series_list = [s for s in series_list if s]
    if not series_list:
        return []
    n = min(len(s) for s in series_list)
    return [sum(s[i] for s in series_list) / len(series_list) for i in range(n)]


# Two-sided Student's t critical values for a 95% confidence interval, indexed
# by degrees of freedom (n - 1). For df > 30 the normal approximation (1.96) is
# close enough. Using the t distribution matters because fuzzing campaigns
# usually have only a handful of trials.
_T95 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
    7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179,
    13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101,
    19: 2.093, 20: 2.086, 21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064,
    25: 2.060, 26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042,
}


def _t_critical_95(n):
    """Two-sided t critical value (95%) for n samples; 0 when n < 2."""
    if n < 2:
        return 0.0
    return _T95.get(n - 1, 1.96)


def confidence_interval_95(series_list):
    """
    Per-column 95% confidence interval of the *mean* across the given series.

    Uses Student's t (df = n-1), appropriate for the small number of trials
    typical of fuzzing campaigns. Returns (low, high, n) truncated to the common
    (minimum) length. With fewer than 2 series the interval is degenerate
    (low == high == mean); n is reported so callers can skip drawing a band.
    """
    series_list = [s for s in series_list if s]
    n = len(series_list)
    if n == 0:
        return [], [], 0
    length = min(len(s) for s in series_list)
    tcrit = _t_critical_95(n)
    low, high = [], []
    for i in range(length):
        col = [s[i] for s in series_list]
        mean = sum(col) / n
        if n >= 2:
            var = sum((x - mean) ** 2 for x in col) / (n - 1)   # sample variance
            half = tcrit * (var ** 0.5) / (n ** 0.5)            # t * standard error
        else:
            half = 0.0
        low.append(mean - half)
        high.append(mean + half)
    return low, high, n


def compute_target_diffs(fuzzers_data, baseline):
    """
    For one target, compute diffs of every non-baseline fuzzer vs the baseline.

    fuzzers_data: {fuzzer: {trial_id: [counts...]}}

    Returns: {fuzzer: {
        'per_trial': {trial_id: [diff...]},   # matched trials only
        'mean':      [mean diff...],          # mean of matched per-trial diffs
        'ci_low':    [...], 'ci_high': [...], # 95% CI of the mean across trials
        'n_trials':  int,                     # number of matched trials (0 if unpaired)
        'paired':    bool,                    # True if matched-trial based
    }}
    or None if the baseline is absent for this target.
    """
    if baseline not in fuzzers_data:
        return None

    base_trials = fuzzers_data[baseline]
    results = {}

    for fuzzer, trials in fuzzers_data.items():
        if fuzzer == baseline:
            continue

        common = sorted(
            set(trials.keys()) & set(base_trials.keys()), key=_trial_key
        )

        if common:
            per_trial = {
                t: diff_series(trials[t], base_trials[t]) for t in common
            }
            diff_list = [per_trial[t] for t in common]
            mean = average_series(diff_list)
            ci_low, ci_high, n_trials = confidence_interval_95(diff_list)
            paired = True
        else:
            # No shared trial ids: fall back to (avg fuzzer) - (avg baseline).
            # A per-trial CI is undefined here, so the band collapses to the mean.
            f_avg = average_series(list(trials.values()))
            b_avg = average_series(list(base_trials.values()))
            per_trial = {}
            mean = diff_series(f_avg, b_avg)
            ci_low, ci_high, n_trials = list(mean), list(mean), 0
            paired = False
            print(
                f"  Warning: no shared trial ids between '{fuzzer}' and "
                f"'{baseline}'; using averaged (unpaired) diff."
            )

        if not mean:
            print(f"  Warning: empty diff for '{fuzzer}' vs '{baseline}'; skipping.")
            continue

        results[fuzzer] = {
            "per_trial": per_trial,
            "mean": mean,
            "ci_low": ci_low,
            "ci_high": ci_high,
            "n_trials": n_trials,
            "paired": paired,
        }

    return results


# ---------------------------------------------------------------------------
# Persisting diff data
# ---------------------------------------------------------------------------

def save_diff_data(diff_data_dir, target, fuzzer, baseline, entry):
    """
    Write a diff data file mirroring the branch_count.txt layout:
        {trial_id} d0 d1 d2 ...
        avg        m0 m1 m2 ...
    """
    diff_data_dir = Path(diff_data_dir)
    out = diff_data_dir / f"{target}_{fuzzer}_minus_{baseline}_diff.txt"

    with open(out, "w") as f:
        for trial_id in sorted(entry["per_trial"].keys(), key=_trial_key):
            vals = entry["per_trial"][trial_id]
            f.write(trial_id + "".join(f" {v}" for v in vals) + "\n")
        if entry["mean"]:
            f.write("avg" + "".join(f" {m:.2f}" for m in entry["mean"]) + "\n")


# ---------------------------------------------------------------------------
# Plot helpers
# ---------------------------------------------------------------------------

def _time_axis(num_points, interval):
    """Elapsed-time axis (hours) for num_points snapshots at `interval` minutes."""
    return [i * interval / 60 for i in range(num_points)]


def _apply_symmetric_ylim(ax, all_values):
    """Set a symmetric Y range (-M .. +M) so 0 is centered, with a margin."""
    if not all_values:
        return
    m = max(abs(v) for v in all_values)
    if m == 0:
        m = 10.0
    pad = max(m * 0.1, 5.0)
    ax.set_ylim(-(m + pad), (m + pad))


def _apply_xaxis(ax, time_points, log_x):
    if not time_points:
        return
    if log_x and len(time_points) > 1:
        ax.set_xscale("log")
        ax.set_xlim(
            time_points[1] if time_points[0] == 0 else time_points[0],
            time_points[-1],
        )
    else:
        ax.set_xlim(0, time_points[-1] if time_points[-1] > 0 else 1)
        ax.xaxis.set_major_locator(MaxNLocator(integer=True))


# ---------------------------------------------------------------------------
# Plotters
# ---------------------------------------------------------------------------

def plot_per_trial_diff(graph_dir, target, fuzzer, baseline, entry, interval, log_x):
    """One faint line per matched trial + bold mean diff line."""
    per_trial = entry["per_trial"]
    mean = entry["mean"]
    if not per_trial and not mean:
        return

    fig, ax = plt.subplots(figsize=(12, 8))
    all_values = []

    for trial_id in sorted(per_trial.keys(), key=_trial_key):
        vals = per_trial[trial_id]
        if not vals:
            continue
        tp = _time_axis(len(vals), interval)
        ax.plot(tp, vals, color="steelblue", alpha=0.35, linewidth=1.3,
                marker="o", markersize=2)
        all_values.extend(vals)

    # When there are no shared trial ids the "mean" is really an avg-vs-avg diff.
    mean_label = "mean diff" if entry["paired"] else "avg-vs-avg diff"
    if mean:
        tp = _time_axis(len(mean), interval)
        ax.plot(tp, mean, color="crimson", linewidth=2.2, label=mean_label,
                marker="o", markersize=2.5)
        all_values.extend(mean)

    ax.axhline(y=0, color="black", linewidth=1.0, linestyle="--", alpha=0.6)
    _apply_symmetric_ylim(ax, all_values)

    num_points = max(
        [len(v) for v in per_trial.values()] + [len(mean)] + [1]
    )
    _apply_xaxis(ax, _time_axis(num_points, interval), log_x)

    ax.set_xlabel("Time (hours)")
    ax.set_ylabel(f"Branch coverage diff ({fuzzer} - {baseline})")
    ax.set_title(f"{target} - {fuzzer} vs {baseline} - per-trial branch diff")
    ax.grid(True, alpha=0.3)

    # Build the legend from what was actually drawn (no phantom entries when
    # the per-trial fallback produced only a mean line).
    handles, labels = [], []
    if per_trial:
        handles.append(plt.Line2D([0], [0], color="steelblue", linewidth=1.3))
        labels.append("each trial")
    if mean:
        handles.append(plt.Line2D([0], [0], color="crimson", linewidth=2.2))
        labels.append(mean_label)
    if handles:
        ax.legend(handles, labels, loc="best")

    out = graph_dir / f"{target}_{fuzzer}_minus_{baseline}_pertrial_diff.png"
    plt.tight_layout()
    plt.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out.name}")


def plot_avg_diff(graph_dir, target, fuzzer, baseline, entry, interval, log_x):
    """Mean diff line with a shaded 95% confidence interval across trials."""
    mean = entry["mean"]
    if not mean:
        return

    ci_low = entry["ci_low"]
    ci_high = entry["ci_high"]

    fig, ax = plt.subplots(figsize=(12, 8))
    all_values = list(mean)

    tp_mean = _time_axis(len(mean), interval)

    if entry["paired"] and entry["n_trials"] >= 2 and ci_low and ci_high:
        n = min(len(ci_low), len(ci_high))
        tp_band = _time_axis(n, interval)
        ax.fill_between(tp_band, ci_low[:n], ci_high[:n],
                        color="crimson", alpha=0.15,
                        label=f"95% CI (n={entry['n_trials']})")
        all_values.extend(ci_low[:n])
        all_values.extend(ci_high[:n])

    label = "mean diff" if entry["paired"] else "avg-vs-avg diff"
    ax.plot(tp_mean, mean, color="crimson", linewidth=2.2, label=label,
            marker="o", markersize=2.5)

    ax.axhline(y=0, color="black", linewidth=1.0, linestyle="--", alpha=0.6)
    _apply_symmetric_ylim(ax, all_values)
    _apply_xaxis(ax, tp_mean, log_x)

    ax.set_xlabel("Time (hours)")
    ax.set_ylabel(f"Branch coverage diff ({fuzzer} - {baseline})")
    ax.set_title(f"{target} - {fuzzer} vs {baseline} - mean branch diff over trials")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best")

    out = graph_dir / f"{target}_{fuzzer}_minus_{baseline}_avg_diff.png"
    plt.tight_layout()
    plt.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out.name}")


def plot_comparison_diff(graph_dir, target, baseline, results, interval, log_x):
    """Overlay every fuzzer's mean diff vs the baseline on one graph."""
    fuzzers = sorted(results.keys())
    if not fuzzers:
        return

    fig, ax = plt.subplots(figsize=(12, 8))
    colors = ["red", "blue", "green", "orange", "purple", "brown", "pink", "gray"]
    all_values = []

    for idx, fuzzer in enumerate(fuzzers):
        entry = results[fuzzer]
        mean = entry["mean"]
        if not mean:
            continue
        color = colors[idx % len(colors)]
        tp = _time_axis(len(mean), interval)

        if entry["paired"] and entry["n_trials"] >= 2 and entry["ci_low"] and entry["ci_high"]:
            n = min(len(entry["ci_low"]), len(entry["ci_high"]))
            ax.fill_between(_time_axis(n, interval),
                            entry["ci_low"][:n], entry["ci_high"][:n],
                            color=color, alpha=0.10)

        ax.plot(tp, mean, color=color, linewidth=2.0,
                label=f"{fuzzer} - {baseline}", marker="o", markersize=2.5)
        all_values.extend(mean)

    if not all_values:
        plt.close(fig)
        return

    ax.axhline(y=0, color="black", linewidth=1.0, linestyle="--", alpha=0.6)
    _apply_symmetric_ylim(ax, all_values)

    num_points = max(len(results[f]["mean"]) for f in fuzzers)
    _apply_xaxis(ax, _time_axis(num_points, interval), log_x)

    ax.set_xlabel("Time (hours)")
    ax.set_ylabel(f"Branch coverage diff (fuzzer - {baseline})")
    ax.set_title(f"{target} - fuzzer vs {baseline} - mean branch diff comparison "
                 f"(shaded = 95% CI)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best")

    out = graph_dir / f"{target}_comparison_minus_{baseline}_diff.png"
    plt.tight_layout()
    plt.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out.name}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate signed branch-coverage diff graphs (fuzzer - baseline) over time"
    )
    parser.add_argument("workdir", help="Result directory path (contains coverage/ or graph/data/)")
    parser.add_argument("--interval", type=int, required=True,
                        help="Measurement interval in minutes (e.g. 10)")
    parser.add_argument("--baseline", default="angora",
                        help="Baseline fuzzer to subtract (default: angora)")
    parser.add_argument("--fuzzers", default=None,
                        help="Comma-separated subset of fuzzers to diff against the baseline "
                             "(default: all non-baseline fuzzers)")
    parser.add_argument("--log-x", action="store_true",
                        help="Use log scale on the x-axis")
    args = parser.parse_args()

    workdir = Path(args.workdir).resolve()
    interval = args.interval
    baseline = args.baseline
    log_x = args.log_x
    fuzzer_filter = (
        {x for x in (f.strip() for f in args.fuzzers.split(",")) if x}
        if args.fuzzers else None
    )

    if interval <= 0:
        print("Error: --interval must be a positive integer.")
        sys.exit(1)

    data = load_all_data(workdir)
    if not data:
        sys.exit(1)

    # Output directories.
    graph_dir = workdir / "graph" / "diff"
    diff_data_dir = graph_dir / "data"
    graph_dir.mkdir(parents=True, exist_ok=True)
    diff_data_dir.mkdir(parents=True, exist_ok=True)
    print(f"✓ Diff graph directory: {graph_dir}")
    print(f"✓ Diff data directory:  {diff_data_dir}")

    total_graphs = 0
    targets_done = 0
    skipped_no_baseline = []

    for target in sorted(data.keys()):
        fuzzers_data = data[target]

        if baseline not in fuzzers_data:
            skipped_no_baseline.append(target)
            continue

        results = compute_target_diffs(fuzzers_data, baseline)
        if not results:
            continue

        if fuzzer_filter is not None:
            results = {f: e for f, e in results.items() if f in fuzzer_filter}
            if not results:
                continue

        print(f"\n[{target}]  baseline={baseline}  fuzzers={sorted(results.keys())}")

        for fuzzer in sorted(results.keys()):
            entry = results[fuzzer]
            save_diff_data(diff_data_dir, target, fuzzer, baseline, entry)
            plot_per_trial_diff(graph_dir, target, fuzzer, baseline, entry, interval, log_x)
            plot_avg_diff(graph_dir, target, fuzzer, baseline, entry, interval, log_x)
            total_graphs += 2

        plot_comparison_diff(graph_dir, target, baseline, results, interval, log_x)
        total_graphs += 1
        targets_done += 1

    print(f"\n✓ Done. {targets_done} target(s), {total_graphs} graph(s) written to {graph_dir}")
    if skipped_no_baseline:
        print(f"  Skipped (no '{baseline}' data): {', '.join(sorted(skipped_no_baseline))}")


if __name__ == "__main__":
    main()

