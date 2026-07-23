#!/usr/bin/env python3
"""
Coverage DIFF visualization script.

For every target, plot the branch-coverage *difference* over time between each
fuzzer and a baseline fuzzer (default: ``angora``), i.e. ``fuzzer - angora``.

The Y axis is a signed difference and is drawn symmetrically around 0
(``-n .. +n``); the X axis is elapsed time. A positive value at time t means the
fuzzer covered more branches than the baseline at that snapshot; a negative
value means it covered fewer.

Two graphs are produced for every target:

  1. signed-area fill  ({target}_{fuzzer}_minus_{baseline}_area.png)
       the avg-vs-avg diff with the region above 0 shaded green ("fuzzer
       ahead", pos) and the region below 0 shaded red ("baseline ahead", neg).
       The net signed area (pos - neg, the time-integral of the diff), pos, and
       neg are annotated on the chart. This is the quantitative "who won, and
       by how much" number, drawn literally as the two areas being compared.

  2. fuzzer comparison  ({target}_comparison_minus_{baseline}_diff.png)
       every fuzzer's mean diff vs the baseline overlaid on one graph as plain
       straight lines (no confidence-interval shading).

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
    import matplotlib.transforms as mtransforms
    from matplotlib.ticker import MaxNLocator
    from matplotlib.colors import TwoSlopeNorm
except ImportError:
    print("Error: matplotlib is required. Install with: pip install matplotlib")
    sys.exit(1)

import math


# ---------------------------------------------------------------------------
# Cross-target relative-area summary (base-fuzzer comparison)
# ---------------------------------------------------------------------------
#
# For a pair (A, B) on a target, the RELATIVE net coverage-area is
#
#     relative(A, B) = 100 * net(A, B) / auc_B
#                    = 100 * (auc_A - auc_B) / auc_B
#                    = 100 * (auc_A / auc_B - 1)      [percent]
#
# where auc_F = ∫ avg_F(t) dt is fuzzer F's coverage-time (area under its mean
# coverage curve) and B is the reference / base fuzzer. This is dimensionless,
# so it is comparable ACROSS targets even when their coverage scales differ by
# orders of magnitude. Positive => A (left) is ahead of the base B (right).

# Pairwise comparisons to summarize, as (left_fuzzer, base_fuzzer, label).
# Edit these names to match your fuzzer directory names, or pass --pairs.
SUMMARY_PAIRS = [
    ("angora-reusing",  "angora",          "reusing - angora"),
    ("angora-storfuzz", "angora",          "storfuzz - angora"),
    ("angora-reusing",  "angora-storfuzz", "reusing - storfuzz"),
]

# Distinct, print-safe colors per pair (cycled if more pairs are supplied).
_PAIR_COLORS = ["#4C78A8", "#F58518", "#54A24B", "#B279A2", "#E45756",
                "#72B7B2", "#EECA3B", "#9D755D"]


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


# ---------------------------------------------------------------------------
# Signed-area (integral) computation
#
# The NET signed area is the trapezoidal integral of the diff series over time:
#     net = ∫ (fuzzer - baseline) dt
# which equals the difference of the two coverage "area under the curve" (AUC)
# values. It decomposes exactly into
#     net = A_plus - A_minus
# where A_plus is the area where the diff is positive (fuzzer ahead) and
# A_minus is the |area| where the diff is negative (baseline ahead). This holds
# exactly because the trapezoidal rule is linear in the samples and
#     diff[i] = max(diff[i], 0) + min(diff[i], 0)   elementwise.
#
# Units: with the y axis in branches and the x axis in HOURS, areas are in
# branch·hours. net / T (total hours) is the time-averaged branch lead, i.e.
# "on average, how many more branches did the fuzzer cover than the baseline".
# ---------------------------------------------------------------------------

def _trapz(y, dx):
    """Trapezoidal integral of a uniformly-sampled series with spacing dx."""
    if len(y) < 2:
        return 0.0
    total = 0.0
    for i in range(len(y) - 1):
        total += (y[i] + y[i + 1]) * 0.5 * dx
    return total


def signed_areas(series, dx):
    """
    Return (net, a_plus, a_minus) for a diff series sampled every dx (hours),
    integrating the piecewise-linear interpolant of the samples EXACTLY.

    net     = ∫ diff dt                      (signed; == a_plus - a_minus)
    a_plus  = ∫ max(diff, 0) dt              (area where fuzzer is ahead)
    a_minus = ∫ max(-diff, 0) dt             (|area| where baseline is ahead)

    Each interval [i, i+1] is integrated on its own. When the segment crosses
    zero between two samples, it is split at the exact crossing point
    (t* at fraction s = a / (a - b) of the cell) instead of at a sample, so the
    positive and negative parts match both the displayed integral formula and
    the interpolate=True shaded fill. Without this split, clipping at samples
    over-counts BOTH a_plus and a_minus by the same amount at every crossing
    (the excess cancels in net, but the individual areas are wrong).
    """
    if not series or len(series) < 2:
        return 0.0, 0.0, 0.0
    a_plus = a_minus = 0.0
    for i in range(len(series) - 1):
        a, b = series[i], series[i + 1]
        if a >= 0 and b >= 0:                       # wholly non-negative
            a_plus += (a + b) * 0.5 * dx
        elif a <= 0 and b <= 0:                     # wholly non-positive
            a_minus += (-(a + b)) * 0.5 * dx
        else:                                       # crosses zero inside cell
            s = a / (a - b)                         # cell fraction before crossing
            if a > 0:                               # positive -> negative
                a_plus += 0.5 * (s * dx) * a
                a_minus += 0.5 * ((1.0 - s) * dx) * (-b)
            else:                                   # negative -> positive
                a_minus += 0.5 * (s * dx) * (-a)
                a_plus += 0.5 * ((1.0 - s) * dx) * b
    net = a_plus - a_minus                          # exact ∫ diff dt
    return net, a_plus, a_minus


def per_trial_net_ci(per_trial, dx):
    """
    95% CI of the NET signed area across matched trials.

    Computes one net-area scalar per trial, then mean ± t*SE. Returns
    (mean_net, half_width, n). half_width is 0 when n < 2 (no band to draw).
    """
    nets = [_trapz(v, dx) for v in per_trial.values() if v]
    n = len(nets)
    if n == 0:
        return 0.0, 0.0, 0
    mean = sum(nets) / n
    if n < 2:
        return mean, 0.0, n
    var = sum((x - mean) ** 2 for x in nets) / (n - 1)
    half = _t_critical_95(n) * (var ** 0.5) / (n ** 0.5)
    return mean, half, n


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
            # Draw from the AVERAGE curves: mean = avg(fuzzer) - avg(baseline),
            # i.e. average each fuzzer's trials first, THEN diff -- not the
            # per-trial-averaged diff. (per_trial is kept only for the
            # per-trial plot and the data files.)
            f_avg = average_series(list(trials.values()))
            b_avg = average_series(list(base_trials.values()))
            mean = diff_series(f_avg, b_avg)
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


def save_area_metrics(diff_data_dir, target, fuzzer, baseline, metrics):
    """
    Write the per-pair signed-area metrics to a small machine-readable file:
        net       <value>
        a_plus    <value>
        a_minus   <value>
        avg_lead  <value>
        ci95_half <value>
        n_trials  <value>
        winner    <name>
    """
    diff_data_dir = Path(diff_data_dir)
    out = diff_data_dir / f"{target}_{fuzzer}_minus_{baseline}_area.txt"
    with open(out, "w") as f:
        f.write(f"net       {metrics['net']:.4f}\n")
        f.write(f"a_plus    {metrics['a_plus']:.4f}\n")
        f.write(f"a_minus   {metrics['a_minus']:.4f}\n")
        f.write(f"avg_lead  {metrics['avg_lead']:.4f}\n")
        f.write(f"ci95_half {metrics['ci_half']:.4f}\n")
        f.write(f"n_trials  {metrics['n_trials']}\n")
        f.write(f"winner    {metrics['winner']}\n")


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


def _mathrm_name(s):
    r"""Sanitize a fuzzer name for use inside a mathtext \mathrm{} group."""
    return r"\mathrm{" + str(s).replace("\\", "").replace("_", r"\_") + "}"


def _area_centroid(tp, vals, sign):
    """
    Area-weighted anchor point for placing a label *inside* a shaded region.

    sign = +1 -> positive region (fuzzer ahead);  sign = -1 -> negative region.
    Returns (x, y) where x is the magnitude-weighted centroid of the region
    (so the label lands in its "heavy" part) and y sits at roughly half the
    region's average height (so it sits centered within the band). Returns None
    when the region is empty.
    """
    xs, ws = [], []
    for x, v in zip(tp, vals):
        if sign > 0 and v > 0:
            xs.append(x); ws.append(v)
        elif sign < 0 and v < 0:
            xs.append(x); ws.append(-v)
    tot = sum(ws)
    if not ws or tot == 0:
        return None
    cx = sum(x * w for x, w in zip(xs, ws)) / tot
    mean_h = tot / len(ws)              # average magnitude over the region
    cy = sign * 0.5 * mean_h            # centered vertically inside the band
    return cx, cy


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

def plot_area_fill(graph_dir, diff_data_dir, target, fuzzer, baseline,
                   entry, interval, log_x):
    """
    Signed-area view: the mean diff curve with the area above 0 shaded green
    ("fuzzer ahead", A+) and the area below 0 shaded red ("baseline ahead",
    A-). The NET signed area (== A+ - A-), A+, A-, the time-averaged lead, and
    the winner are annotated on the chart. When trials are matched, the net
    area also carries a 95% CI computed across per-trial net areas.

    Returns the computed area metrics dict (also written to disk) so the caller
    can aggregate a cross-fuzzer ranking summary.
    """
    mean = entry["mean"]
    if not mean:
        return None

    dx = interval / 60.0  # hours per snapshot
    tp = _time_axis(len(mean), interval)
    # All three numbers come from the MEAN diff curve, so the identity
    # net == A+ - A- holds exactly on what is drawn.
    net, a_plus, a_minus = signed_areas(mean, dx)

    # Spread across trials is kept only for the data/ranking files (not drawn).
    ci_half = 0.0
    n_trials = entry["n_trials"]
    if entry["paired"] and entry["per_trial"]:
        _, ci_half, n_pt = per_trial_net_ci(entry["per_trial"], dx)
        if n_pt >= 1:
            n_trials = n_pt

    T = tp[-1] if tp and tp[-1] > 0 else (len(mean) - 1) * dx
    avg_lead = net / T if T > 0 else 0.0
    winner = fuzzer if net > 0 else (baseline if net < 0 else "tie")

    metrics = {
        "net": net, "a_plus": a_plus, "a_minus": a_minus,
        "avg_lead": avg_lead, "ci_half": ci_half,
        "n_trials": n_trials, "winner": winner,
    }

    fig, ax = plt.subplots(figsize=(12, 8))

    zeros = [0.0] * len(mean)
    # interpolate=True makes the green/red fills meet exactly at zero crossings.
    ax.fill_between(tp, mean, zeros, where=[v >= 0 for v in mean],
                    interpolate=True, color="seagreen", alpha=0.40,
                    label=f"pos  ({fuzzer} ahead)")
    ax.fill_between(tp, mean, zeros, where=[v <= 0 for v in mean],
                    interpolate=True, color="crimson", alpha=0.40,
                    label=f"neg  ({baseline} ahead)")
    ax.plot(tp, mean, color="black", linewidth=1.8, zorder=3)

    ax.axhline(y=0, color="black", linewidth=1.0, linestyle="--", alpha=0.6)

    # Y limits: symmetric around 0 (keeps the baseline centered), but with
    # enough top head-room to seat the headline just above the curve's peak.
    vals = mean
    M0 = max((abs(v) for v in vals), default=10.0) or 10.0
    peak_y = max(vals)
    trough_y = min(vals)
    box_gap = 0.06 * M0                       # vertical gap: peak -> box bottom
    need_top = peak_y + box_gap + 0.15 * M0   # also reserve room for the box
    Mfinal = max(M0, need_top, -trough_y)
    pad = max(0.05 * Mfinal, 3.0)
    ax.set_ylim(-(Mfinal + pad), Mfinal + pad)
    _apply_xaxis(ax, tp, log_x)

    # Exactly three numbers, shown as plain formulas:
    #   (1) pos = <area>       inside the green region
    #   (2) neg = <area>       inside the red region
    #   (3) pos - neg = <net>  as the top-center headline
    total_area = a_plus + a_minus
    pos_anchor = _area_centroid(tp, mean, +1)
    neg_anchor = _area_centroid(tp, mean, -1)

    if pos_anchor and a_plus > 0.01 * total_area:
        ax.annotate(f"pos = {a_plus:.1f}", xy=pos_anchor, ha="center", va="center",
                    fontsize=15, fontweight="bold", color="darkgreen", zorder=5,
                    bbox=dict(boxstyle="round,pad=0.35", facecolor="white",
                              alpha=0.80, edgecolor="seagreen"))
    if neg_anchor and a_minus > 0.01 * total_area:
        ax.annotate(f"neg = {a_minus:.1f}", xy=neg_anchor, ha="center", va="center",
                    fontsize=15, fontweight="bold", color="darkred", zorder=5,
                    bbox=dict(boxstyle="round,pad=0.35", facecolor="white",
                              alpha=0.80, edgecolor="crimson"))

    # Headline (pos - neg): horizontally FIXED at the center of the plot, while
    # its vertical position tracks the curve's highest point (peak_y + gap) so
    # only the y-position varies. A blended transform keeps x centered (axes
    # fraction 0.5) regardless of the x-axis range/scale, with y in data coords.
    net_color = "darkgreen" if net > 0 else ("darkred" if net < 0 else "black")
    trans = mtransforms.blended_transform_factory(ax.transAxes, ax.transData)
    ax.text(0.5, peak_y + box_gap, f"pos - neg = {net:+.1f}",
            transform=trans, ha="center", va="bottom",
            fontsize=15, fontweight="bold", color=net_color, family="monospace",
            zorder=7,
            bbox=dict(boxstyle="round,pad=0.5", facecolor="white", alpha=0.92,
                      edgecolor=net_color, linewidth=1.6))

    # Definition of the two shaded areas as time-integrals of the AVERAGE diff
    # curve: mean(fuzzer) - mean(baseline). Rendered with mathtext so the
    # integral sign is font-independent; the integrand names which two averaged
    # curves are being subtracted.
    F = r"\overline{" + _mathrm_name(fuzzer) + "}"
    B = r"\overline{" + _mathrm_name(baseline) + "}"
    defn = "\n".join([
        r"$\mathrm{pos}=\int \mathrm{max}(" + F + "-" + B + r",\,0)\;dt$   (positive area)",
        r"$\mathrm{neg}=\int \mathrm{max}(" + B + "-" + F + r",\,0)\;dt$   (negative area)",
    ])
    ax.text(0.015, 0.03, defn, transform=ax.transAxes, va="bottom", ha="left",
            fontsize=11.5, color="black", zorder=6, linespacing=1.7,
            bbox=dict(boxstyle="round,pad=0.4", facecolor="white", alpha=0.88,
                      edgecolor="gray"))

    ax.set_xlabel("Time (hours)")
    ax.set_ylabel(f"Branch coverage diff ({fuzzer} - {baseline})")
    ax.set_title(f"{target} - {fuzzer} vs {baseline} - signed coverage-diff area")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="lower right")

    out = graph_dir / f"{target}_{fuzzer}_minus_{baseline}_area.png"
    plt.tight_layout()
    plt.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out.name}  (net={net:+.1f}, A+={a_plus:.1f}, A-={a_minus:.1f})")

    save_area_metrics(diff_data_dir, target, fuzzer, baseline, metrics)
    return metrics


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

        # Mean diff only: a plain straight line, no confidence-interval shading.
        ax.plot(tp, mean, color=color, linewidth=2.0,
                label=f"{fuzzer} - {baseline}")
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
    ax.set_title(f"{target} - fuzzer vs {baseline} - mean branch diff comparison")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best")

    out = graph_dir / f"{target}_comparison_minus_{baseline}_diff.png"
    plt.tight_layout()
    plt.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out.name}")


def save_area_ranking(diff_data_dir, baseline, rows):
    """
    Write a cross-target/cross-fuzzer ranking of the net signed area, sorted by
    net descending (most-improved over baseline first). Columns:
        target  fuzzer  net  ci95_half  a_plus  a_minus  avg_lead  n  winner
    """
    if not rows:
        return
    diff_data_dir = Path(diff_data_dir)
    out = diff_data_dir / f"area_ranking_minus_{baseline}.txt"
    rows_sorted = sorted(rows, key=lambda r: r["net"], reverse=True)
    header = ("target", "fuzzer", "net", "ci95_half",
              "a_plus", "a_minus", "avg_lead", "n", "winner")
    with open(out, "w") as f:
        f.write("\t".join(header) + "\n")
        for r in rows_sorted:
            f.write(
                f"{r['target']}\t{r['fuzzer']}\t{r['net']:.2f}\t{r['ci_half']:.2f}\t"
                f"{r['a_plus']:.2f}\t{r['a_minus']:.2f}\t{r['avg_lead']:.3f}\t"
                f"{r['n_trials']}\t{r['winner']}\n"
            )
    print(f"✓ Created: {out.name}  ({len(rows_sorted)} rows)")


# ---------------------------------------------------------------------------
# Cross-target relative-area summary: parsing, computation, plots
# ---------------------------------------------------------------------------

def parse_summary_pairs(spec):
    """Parse '--pairs A/B/label;C/D/label' (label optional -> 'A - B'). Net = A - B."""
    pairs = []
    for chunk in spec.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = [p.strip() for p in chunk.split("/")]
        if len(parts) < 2:
            print(f"Warning: ignoring bad pair spec: {chunk!r}")
            continue
        a, b = parts[0], parts[1]
        label = parts[2] if len(parts) > 2 and parts[2] else f"{a} - {b}"
        pairs.append((a, b, label))
    return pairs


def compute_pair_stats(data, targets, pairs, dx):
    """
    For each (pair, target) compute a dict of comparison metrics, or None when a
    fuzzer is missing. Metrics (net = ∫(avg_A - avg_B) dt = pos - neg):

      net        raw signed area                       (branch*h)
      pos, neg   gross positive / negative diff areas  (branch*h)
      avg_lead   net / T = time-averaged branch lead   (branches)   [magnitude]
      dominance  100*(pos-neg)/(pos+neg) in [-100,100] (%)          [direction]
      relative   100*net/auc_base = 100*(auc_A/auc_B-1)(%)          [vs full cov]
    """
    avgs = {}
    for t in targets:
        for fuzzer, trials in data.get(t, {}).items():
            avgs[(t, fuzzer)] = average_series(list(trials.values()))

    stats = {}
    for j, (a, b, _label) in enumerate(pairs):
        for t in targets:
            ca, cb = avgs.get((t, a)), avgs.get((t, b))
            if not (ca and cb):
                stats[(j, t)] = None
                continue
            d = diff_series(ca, cb)
            n, pos, neg = signed_areas(d, dx)
            T = (len(d) - 1) * dx if len(d) > 1 else dx
            auc_base = _trapz(cb, dx)
            denom = pos + neg
            # denom == 0 means the two mean curves are identical (pos==neg==0):
            # a genuine tie. dividing by (pos+neg) -- never by neg alone --
            # keeps neg==0 finite: dominance -> +100, posshare -> 100.
            if denom > 0:
                dominance = 100.0 * n / denom          # neg==0 -> +100, pos==0 -> -100
                posshare = 100.0 * pos / denom          # neg==0 -> 100,  pos==0 -> 0
            else:
                dominance, posshare = 0.0, 50.0         # tie
            stats[(j, t)] = {
                "net": n, "pos": pos, "neg": neg,
                "avg_lead": (n / T) if T > 0 else 0.0,
                "dominance": dominance,
                "posshare": posshare,
                "relative": (100.0 * n / auc_base) if auc_base else None,
            }
    return stats, avgs


# Metric registry: how each --metric option is computed, formatted, and scaled.
#   key      : field in the per-cell stats dict
#   fmt      : cell/label formatter
#   ylabel   : bar y-axis / heatmap colorbar label
#   bound    : fixed symmetric limit (dominance is bounded to +-100), else None
#   name     : human title fragment
METRIC_SPECS = {
    "dominance": dict(
        key="dominance", fmt=lambda v: f"{v:+.0f}%", bound=100.0,
        ylabel="Directional dominance  (pos - neg)/(pos + neg)  (%)",
        name="directional dominance (positive vs negative area)"),
    # pos/(pos+neg): the neg==0-safe form of "pos vs neg %". Centered at 50
    # (tie); 100% = neg is 0 (A never behind), 0% = pos is 0 (A never ahead).
    "posshare": dict(
        key="posshare", fmt=lambda v: f"{v:.0f}%", bound=None,
        vmin=0.0, vmax=100.0, center=50.0,
        ylabel="Positive-area share  pos/(pos + neg)  (%)   [50 = tie, 100 = neg is 0]",
        name="positive-area share  pos/(pos+neg)"),
    "avg-lead": dict(
        key="avg_lead", fmt=lambda v: f"{v:+.2f}", bound=None,
        ylabel="Average branch lead  (branches)",
        name="average branch lead"),
    "relative": dict(
        key="relative", fmt=lambda v: f"{v:+.1f}%", bound=None,
        ylabel="Relative net area vs base coverage-time  (%)",
        name="relative net area (% of base coverage-time)"),
    # Hybrid: geometry/color = dominance (bounded, comparable direction),
    # printed number = net area (pos - neg, branch*h) = the magnitude.
    "hybrid": dict(
        key="dominance", fmt=lambda v: f"{v:+.0f}%", bound=100.0,
        ylabel="color: dominance (pos vs neg, %)    |    number: net area (pos - neg)",
        name="dominance (color) + net area pos-neg (number)"),
}


# Spec for the net-area bars (y-axis = magnitude, pos - neg, branch*h).
# symlog: signed log scale (linear near 0, log beyond +-linthresh) so a huge
# target (e.g. tcpdump) and small ones stay visible on one axis.
_NET_SPEC = dict(
    key="net", fmt=lambda v: f"{v:+.1f}", bound=None, center=0.0,
    symlog=True, linthresh=1.0,
    ylabel="Net coverage-diff area   pos - neg   (branch*h)",
    name="net area (pos - neg)")


def _matrix_for(stats, pairs, targets, key):
    """Pull one metric field into vals[(pair_idx, target)] (None-safe)."""
    vals = {}
    for j in range(len(pairs)):
        for t in targets:
            s = stats.get((j, t))
            vals[(j, t)] = None if s is None else s.get(key)
    return vals


def plot_summary_bars(out_path, targets, pairs, vals, spec, text_vals=None, text_fmt=None):
    """
    Grouped diverging bar chart grouped by target. Bar HEIGHT/scale comes from
    `vals`; the printed LABEL comes from `text_vals`/`text_fmt` when given (used
    by the hybrid metric: height = dominance, label = avg branch lead).
    """
    n_t, n_p = len(targets), len(pairs)
    all_vals = [v for v in vals.values() if v is not None]
    if n_t == 0 or n_p == 0 or not all_vals:
        print("Summary bars: nothing to plot (check fuzzer names / metric).")
        return
    tfmt = text_fmt or spec["fmt"]
    ctr = spec.get("center", 0.0)          # bars diverge from this baseline

    fig, ax = plt.subplots(figsize=(max(8, 2.2 * n_t + 3), 8))
    group_w, bar_w = 0.8, 0.8 / n_p
    for j, (a, b, label) in enumerate(pairs):
        color = _PAIR_COLORS[j % len(_PAIR_COLORS)]
        xs, hs, txts = [], [], []
        for i, t in enumerate(targets):
            v = vals[(j, t)]
            if v is None:
                continue
            xs.append(i - group_w / 2 + bar_w * (j + 0.5))
            hs.append(v)
            tv = text_vals[(j, t)] if text_vals is not None else v
            txts.append(tfmt(tv) if tv is not None else "")
        # bars grow up/down from the tie baseline `ctr`
        ax.bar(xs, [h - ctr for h in hs], width=bar_w, bottom=ctr, color=color,
               label=label, edgecolor="black", linewidth=0.6, zorder=3)
        for xi, h, tx in zip(xs, hs, txts):
            ax.annotate(tx, (xi, h), ha="center", va="bottom" if h >= ctr else "top",
                        fontsize=8.5, fontweight="bold", color=color,
                        xytext=(0, 3 if h >= ctr else -3), textcoords="offset points")

    ax.axhline(ctr, color="black", linewidth=1.1, zorder=2)
    if spec.get("symlog"):
        M = max((abs(v) for v in all_vals), default=1.0) or 1.0
        ax.set_yscale("symlog", linthresh=spec.get("linthresh", 1.0))
        ax.set_ylim(-(M * 2.5), M * 2.5)                  # symmetric, headroom for labels
    elif spec.get("vmin") is not None:
        lo, hi = spec["vmin"], spec["vmax"]
        padr = (hi - lo) * 0.08
        ax.set_ylim(lo - padr, hi + padr)
    else:
        M = spec["bound"] or (max((abs(v) for v in all_vals), default=1.0) or 1.0)
        pad = max(0.18 * M, 1.0)
        ax.set_ylim(-(M + pad), M + pad)                  # symmetric around 0
    ax.set_xticks(range(n_t))
    ax.set_xticklabels(targets, fontsize=11, rotation=20, ha="right")
    ax.set_xlim(-0.5, n_t - 0.5)
    ax.set_ylabel(spec["ylabel"] + ("   [symlog scale]" if spec.get("symlog") else ""))
    ax.set_title(f"Coverage comparison by target — {spec['name']}\n"
                 "bar up (+): left fuzzer ahead   |   bar down (-): base fuzzer ahead",
                 fontsize=13)
    ax.grid(True, axis="y", alpha=0.3, zorder=0)
    ax.legend(loc="best", framealpha=0.9)

    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out_path.name}")


def plot_summary_heatmap(out_path, targets, pairs, vals, spec, text_vals=None, text_fmt=None):
    """
    Diverging heatmap (rows=pairs, cols=targets). Cell COLOR comes from `vals`;
    the printed number comes from `text_vals`/`text_fmt` when given (hybrid:
    color = dominance, number = avg branch lead).
    """
    n_t, n_p = len(targets), len(pairs)
    all_vals = [v for v in vals.values() if v is not None]
    if n_t == 0 or n_p == 0 or not all_vals:
        return
    if spec.get("vmin") is not None:
        norm = TwoSlopeNorm(vmin=spec["vmin"], vcenter=spec.get("center", 0.0),
                            vmax=spec["vmax"])
    else:
        M = spec["bound"] or (max((abs(v) for v in all_vals), default=1.0) or 1.0)
        norm = TwoSlopeNorm(vmin=-M, vcenter=0.0, vmax=M)
    tfmt = text_fmt or spec["fmt"]

    grid = [[vals[(j, t)] for t in targets] for j in range(n_p)]
    fig, ax = plt.subplots(figsize=(max(7.5, 1.5 * n_t + 3), 1.25 * n_p + 3.0))
    plot_grid = [[(v if v is not None else math.nan) for v in row] for row in grid]
    cmap = plt.get_cmap("RdYlGn").copy()
    cmap.set_bad(color="#e6e6e6")
    im = ax.imshow(plot_grid, cmap=cmap, norm=norm, aspect="auto")

    # Crisp white gridlines between cells for a clean, publication look.
    ax.set_xticks([x - 0.5 for x in range(n_t + 1)], minor=True)
    ax.set_yticks([y - 0.5 for y in range(n_p + 1)], minor=True)
    ax.grid(which="minor", color="white", linewidth=2.5)
    ax.tick_params(which="minor", length=0)
    ax.tick_params(which="major", length=0)

    ax.set_xticks(range(n_t)); ax.set_xticklabels(targets, fontsize=11.5, rotation=30, ha="right")
    ax.set_yticks(range(n_p)); ax.set_yticklabels([p[2] for p in pairs], fontsize=11.5)

    for j in range(n_p):
        for i in range(n_t):
            cv = grid[j][i]
            if cv is None:
                ax.text(i, j, "n/a", ha="center", va="center",
                        fontsize=9, color="#888888")
                continue
            tv = text_vals[(j, targets[i])] if text_vals is not None else cv
            if tv is None:
                continue
            # Pick black/white text by the cell's luminance for readability.
            r, g, bl, _ = cmap(norm(cv))
            lum = 0.299 * r + 0.587 * g + 0.114 * bl
            tc = "black" if lum > 0.55 else "white"
            ax.text(i, j, tfmt(tv), ha="center", va="center",
                    fontsize=12, fontweight="bold", color=tc)

    ax.set_title(f"Coverage comparison — {spec['name']}\n"
                 "green = left fuzzer ahead   ·   red = base fuzzer ahead   ·   gray = no data",
                 fontsize=12.5, pad=12)
    cbar = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03)
    cbar.set_label(spec["ylabel"], fontsize=10.5)
    cbar.ax.tick_params(labelsize=9)

    plt.tight_layout()
    plt.savefig(out_path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out_path.name}")


def build_summary(data, graph_dir, dx, pairs, metric):
    """Compute and render the cross-target bar + heatmap summary for `metric`."""
    targets = sorted(data.keys())
    if not targets:
        return
    spec = METRIC_SPECS[metric]

    # Report available fuzzers and flag any requested name that is missing.
    by_target = {t: sorted(data.get(t, {}).keys()) for t in targets}
    all_fuzzers = sorted({f for fs in by_target.values() for f in fs})
    print(f"\n[summary] fuzzers found: {all_fuzzers}")
    requested = {f for (a, b, _l) in pairs for f in (a, b)}
    missing = sorted(requested - set(all_fuzzers))
    if missing:
        print(f"  !! requested fuzzer name(s) NOT found: {missing}")
        print(f"     -> fix SUMMARY_PAIRS or pass --pairs using one of: {all_fuzzers}")

    stats, _avgs = compute_pair_stats(data, targets, pairs, dx)
    vals = _matrix_for(stats, pairs, targets, spec["key"])

    # Hybrid: color/height = dominance, printed number = net area (pos - neg).
    text_vals = text_fmt = None
    if metric == "hybrid":
        text_vals = _matrix_for(stats, pairs, targets, "net")
        text_fmt = lambda v: f"{v:+.1f}"

    print(f"[summary] metric={metric}   pairs={[p[2] for p in pairs]}")
    for j, (a, b, label) in enumerate(pairs):
        def _cell(t):
            if vals[(j, t)] is None:
                return f"{t}=--"
            if metric == "hybrid":
                return f"{t}={spec['fmt'](vals[(j,t)])}/{text_fmt(text_vals[(j,t)])}"
            return f"{t}={spec['fmt'](vals[(j,t)])}"
        print(f"  [{label}]  " + "  ".join(_cell(t) for t in targets))

    # Only the summary bar chart is produced (net-area magnitude, symlog y-axis).
    if metric == "hybrid":
        # bars: y-axis = net area magnitude (pos - neg), colored by pair
        plot_summary_bars(graph_dir / "summary_bars.png", targets, pairs,
                          text_vals, _NET_SPEC)
    else:
        plot_summary_bars(graph_dir / "summary_bars.png", targets, pairs, vals, spec)


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
    parser.add_argument("--pairs", default=None,
                        help="Pairs for the relative-%% summary: 'A/B/label;C/D/label' "
                             "(net = A - B, B is the base). Default: the reusing/"
                             "storfuzz/angora comparisons in SUMMARY_PAIRS.")
    parser.add_argument("--metric", default="hybrid",
                        choices=["hybrid", "dominance", "posshare", "avg-lead", "relative"],
                        help="Summary metric: 'hybrid' = color by dominance + number "
                             "= avg branch lead (recommended), 'dominance' = "
                             "(pos-neg)/(pos+neg) in [-100,100]%%, 'posshare' = "
                             "pos/(pos+neg) in [0,100]%% (neg==0 -> 100%%), 'avg-lead' "
                             "= mean branch lead, 'relative' = %% of base coverage-time. "
                             "Default: hybrid.")
    parser.add_argument("--no-summary", action="store_true",
                        help="Skip the cross-target summary bar + heatmap.")
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
    area_rows = []  # for the cross-fuzzer net-area ranking summary

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
            # Only the signed-area graph per fuzzer (per-trial and avg-diff
            # graphs are intentionally not generated).
            metrics = plot_area_fill(graph_dir, diff_data_dir, target, fuzzer,
                                     baseline, entry, interval, log_x)
            if metrics:
                row = dict(metrics)
                row["target"] = target
                row["fuzzer"] = fuzzer
                area_rows.append(row)
            total_graphs += 1

        plot_comparison_diff(graph_dir, target, baseline, results, interval, log_x)
        total_graphs += 1
        targets_done += 1

    save_area_ranking(diff_data_dir, baseline, area_rows)

    # Cross-target summary (base-fuzzer comparison), one bar + one heatmap.
    if not args.no_summary:
        pairs = parse_summary_pairs(args.pairs) if args.pairs else SUMMARY_PAIRS
        build_summary(data, graph_dir, interval / 60.0, pairs, args.metric)

    print(f"\n✓ Done. {targets_done} target(s), {total_graphs} per-target graph(s) "
          f"written to {graph_dir}")
    if skipped_no_baseline:
        print(f"  Skipped (no '{baseline}' data): {', '.join(sorted(skipped_no_baseline))}")


if __name__ == "__main__":
    main()