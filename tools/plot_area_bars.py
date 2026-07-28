#!/usr/bin/env python3
"""
Summary bar chart of the signed coverage-diff AREA (net = pos - neg) for a set
of pairwise fuzzer comparisons, grouped by target.

For every target and every requested pair (A, B), it computes

    net(A, B) = ∫ ( avg(A) - avg(B) ) dt          # == pos - neg

where avg(F) is fuzzer F's mean branch-coverage curve over its trials (the same
avg-vs-avg diff the area plot uses). A positive bar means the LEFT fuzzer of the
pair covered more branches over time; a negative bar means the RIGHT one did.

Two views are produced:

  1. grouped diverging bar   (area_bars.png)
       x-axis: targets (the large category); within each target one bar per
       pair (reusing-angora, angora-storfuzz-angora, reusing-angora-storfuzz, ...).
       y-axis: net area, drawn symmetrically around 0 (-M .. +M).

  2. diverging heatmap       (area_heatmap.png)   [recommended alternative]
       rows = pairs, cols = targets, cell color = net area on a diverging
       colormap centered at 0. Scales to many targets/pairs far better than
       bars and is the cleaner "at a glance" summary when the grid grows.

Input is read exactly like plot_coverage_diff.py (coverage/ dir or the
pre-parsed graph/data/*_branch_count.txt files); this script reuses that
loader, so keep it in the same directory as plot_coverage_diff.py.
"""

import sys
import argparse
from pathlib import Path

try:
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import TwoSlopeNorm, to_rgba
except ImportError:
    print("Error: matplotlib (and numpy) are required. Install with: pip install matplotlib")
    sys.exit(1)

# Reuse the loader / math from the diff script (must sit alongside this file).
from diff_coverage import (
    load_all_data, average_series, diff_series, signed_areas, _trapz,
)


# Which pairwise comparisons to draw, as (left_fuzzer, right_fuzzer, label).
# net > 0  ->  left fuzzer ahead;  net < 0  ->  right fuzzer ahead.
# Edit these names to match your fuzzer directory names.
DEFAULT_PAIRS = [
    ("angora-reusing", "angora",   "reusing - angora"),
    ("angora-storfuzz",       "angora",   "angora-storfuzz - angora"),
    ("angora-reusing", "angora-storfuzz", "reusing - angora-storfuzz"),
]

# Distinct, print-safe colors per pair (extended if more pairs are supplied).
PAIR_COLORS = ["#4C78A8", "#F58518", "#54A24B", "#B279A2", "#E45756",
               "#72B7B2", "#EECA3B", "#9D755D"]


def parse_pairs(spec):
    """Parse '--pairs A/B/label;C/D/label' (label optional -> 'A - B')."""
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


def compute_net_matrix(data, targets, pairs, dx):
    """
    net[(pair_idx, target)]      = net area (branch*h), or None if a fuzzer is missing.
    rel[(pair_idx, target)]      = net normalized by the RIGHT (reference) fuzzer's
                                   coverage-time AUC, in percent -> cross-target
                                   comparable. None if unavailable / ref AUC == 0.
    Also returns per-(target,fuzzer) averaged curves.
    """
    avgs = {}   # avgs[(target, fuzzer)] = mean curve
    for t in targets:
        for fuzzer, trials in data.get(t, {}).items():
            avgs[(t, fuzzer)] = average_series(list(trials.values()))

    net, rel = {}, {}
    for j, (a, b, _label) in enumerate(pairs):
        for t in targets:
            ca, cb = avgs.get((t, a)), avgs.get((t, b))
            if ca and cb:
                d = diff_series(ca, cb)
                n, _pos, _neg = signed_areas(d, dx)
                net[(j, t)] = n
                auc_ref = _trapz(cb, dx)                 # reference coverage-time
                rel[(j, t)] = (100.0 * n / auc_ref) if auc_ref else None
            else:
                net[(j, t)] = None
                rel[(j, t)] = None
    return net, rel, avgs


# ---------------------------------------------------------------------------
# 1) Grouped diverging bar chart
# ---------------------------------------------------------------------------

def plot_grouped_bars(out_path, targets, pairs, net):
    n_t, n_p = len(targets), len(pairs)
    if n_t == 0 or n_p == 0:
        print("Nothing to plot (no targets or no pairs).")
        return

    all_vals = [v for v in net.values() if v is not None]
    M = max((abs(v) for v in all_vals), default=1.0) or 1.0

    fig, ax = plt.subplots(figsize=(max(8, 2.6 * n_t + 3), 8))
    group_w = 0.8
    bar_w = group_w / n_p

    for j, (a, b, label) in enumerate(pairs):
        color = PAIR_COLORS[j % len(PAIR_COLORS)]
        xs, hs = [], []
        for i, t in enumerate(targets):
            v = net[(j, t)]
            if v is None:
                continue
            xs.append(i - group_w / 2 + bar_w * (j + 0.5))
            hs.append(v)
        ax.bar(xs, hs, width=bar_w, color=color, label=label,
               edgecolor="black", linewidth=0.6, zorder=3)
        for xi, h in zip(xs, hs):
            ax.annotate(f"{h:+.1f}", (xi, h), ha="center",
                        va="bottom" if h >= 0 else "top",
                        fontsize=9, fontweight="bold", color=color,
                        xytext=(0, 3 if h >= 0 else -3),
                        textcoords="offset points")

    ax.axhline(0, color="black", linewidth=1.1, zorder=2)
    pad = max(0.18 * M, 1.0)
    ax.set_ylim(-(M + pad), M + pad)                 # symmetric around 0
    ax.set_xticks(range(n_t))
    ax.set_xticklabels(targets, fontsize=12)
    ax.set_xlim(-0.5, n_t - 0.5)

    ax.set_ylabel("Net signed area   (pos - neg,  branch*h)")
    ax.set_title("Coverage-diff net area by target\n"
                 "bar up (+): left fuzzer ahead   |   bar down (-): right fuzzer ahead",
                 fontsize=13)
    ax.grid(True, axis="y", alpha=0.3, zorder=0)
    ax.legend(loc="best", framealpha=0.9)

    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out_path.name}")


# ---------------------------------------------------------------------------
# 2) Diverging heatmap (recommended alternative)
# ---------------------------------------------------------------------------

def plot_heatmap(out_path, targets, pairs, values, mode, cell_fmt, cbar_label, title):
    """
    Diverging heatmap of `values[(pair_idx, target)]`.

    mode:
      "global"     - one shared color scale across the whole grid (comparable
                     colors everywhere; small-scale targets can wash out).
      "per_target" - each TARGET COLUMN normalized to its own max|value|, so the
                     within-target winner/margin is always visible. Colors are
                     NOT comparable across columns (no shared colorbar) - read
                     the printed numbers for absolute magnitude.
    """
    n_t, n_p = len(targets), len(pairs)
    if n_t == 0 or n_p == 0:
        return
    grid = [[values[(j, t)] for t in targets] for j in range(n_p)]
    cmap = plt.get_cmap("RdYlGn")           # red (neg) -> green (pos)

    fig, ax = plt.subplots(figsize=(max(7, 1.7 * n_t + 3), 1.1 * n_p + 2.8))

    if mode == "per_target":
        # Build an RGBA image, normalizing each column independently.
        rgba = np.empty((n_p, n_t, 4))
        for i in range(n_t):
            col = [grid[j][i] for j in range(n_p) if grid[j][i] is not None]
            Mc = max((abs(v) for v in col), default=1.0) or 1.0
            cnorm = TwoSlopeNorm(vmin=-Mc, vcenter=0.0, vmax=Mc)
            for j in range(n_p):
                v = grid[j][i]
                rgba[j, i] = to_rgba("lightgray") if v is None else cmap(cnorm(v))
        ax.imshow(rgba, aspect="auto")
        note = "color scale: per target (column-wise) — compare within a column only"
    else:
        all_vals = [v for v in values.values() if v is not None]
        M = max((abs(v) for v in all_vals), default=1.0) or 1.0
        norm = TwoSlopeNorm(vmin=-M, vcenter=0.0, vmax=M)
        plot_grid = [[(v if v is not None else np.nan) for v in row] for row in grid]
        cmap.set_bad(color="lightgray")
        im = ax.imshow(plot_grid, cmap=cmap, norm=norm, aspect="auto")
        cbar = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
        cbar.set_label(cbar_label)
        note = "color scale: shared across all targets"

    ax.set_xticks(range(n_t)); ax.set_xticklabels(targets, fontsize=11, rotation=30, ha="right")
    ax.set_yticks(range(n_p)); ax.set_yticklabels([p[2] for p in pairs], fontsize=11)
    for j in range(n_p):
        for i in range(n_t):
            v = grid[j][i]
            if v is None:
                continue
            ax.text(i, j, cell_fmt(v), ha="center", va="center",
                    fontsize=10, fontweight="bold", color="black")
    ax.set_title(f"{title}\n{note}", fontsize=12)

    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"✓ Created: {out_path.name}")


def main():
    ap = argparse.ArgumentParser(
        description="Summary bar/heatmap of net coverage-diff area, grouped by target")
    ap.add_argument("workdir", help="Result dir (contains coverage/ or graph/data/)")
    ap.add_argument("--interval", type=int, required=True,
                    help="Measurement interval in minutes (e.g. 10)")
    ap.add_argument("--pairs", default=None,
                    help="'A/B/label;C/D/label' (net = A - B). Default: the three "
                         "reusing/angora-storfuzz/angora comparisons.")
    ap.add_argument("--targets", default=None,
                    help="Comma-separated subset of targets (default: all)")
    ap.add_argument("--color", default="per-target",
                    choices=["global", "per-target", "relative"],
                    help="Heatmap coloring: 'global' (one shared branch*h scale), "
                         "'per-target' (each target column scaled to itself), or "
                         "'relative' (net normalized to %% of the reference fuzzer's "
                         "coverage-time, one shared scale). Default: per-target.")
    args = ap.parse_args()

    if args.interval <= 0:
        print("Error: --interval must be positive.")
        sys.exit(1)

    dx = args.interval / 60.0
    pairs = parse_pairs(args.pairs) if args.pairs else DEFAULT_PAIRS

    data = load_all_data(args.workdir)
    if not data:
        sys.exit(1)

    targets = sorted(data.keys())
    if args.targets:
        want = {t.strip() for t in args.targets.split(",") if t.strip()}
        targets = [t for t in targets if t in want]
    if not targets:
        print("Error: no matching targets.")
        sys.exit(1)

    # Report which fuzzer directory names actually exist, and flag any name
    # referenced by --pairs that is not present (the usual cause of all "--").
    fuzzers_by_target = {t: sorted(data.get(t, {}).keys()) for t in targets}
    all_fuzzers = sorted({f for fs in fuzzers_by_target.values() for f in fs})
    print(f"\nFuzzers found: {all_fuzzers}")
    requested = {f for (a, b, _l) in pairs for f in (a, b)}
    missing = sorted(requested - set(all_fuzzers))
    if missing:
        print(f"  !! requested fuzzer name(s) NOT found: {missing}")
        print(f"     -> fix the name in DEFAULT_PAIRS or pass --pairs using one "
              f"of: {all_fuzzers}")
        # show per-target availability so partial coverage is visible too
        for t in targets:
            print(f"     {t}: {fuzzers_by_target[t]}")

    net, rel, _avgs = compute_net_matrix(data, targets, pairs, dx)

    out_dir = Path(args.workdir).resolve() / "graph" / "diff"
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nTargets: {targets}")
    print(f"Pairs:   {[p[2] for p in pairs]}")
    for j, (a, b, label) in enumerate(pairs):
        row = "  ".join(
            f"{t}={'--' if net[(j,t)] is None else format(net[(j,t)], '+.1f')}"
            for t in targets)
        print(f"  [{label}]  {row}")

    plot_grouped_bars(out_dir / "area_bars.png", targets, pairs, net)

    if args.color == "relative":
        plot_heatmap(out_dir / "area_heatmap.png", targets, pairs, rel,
                     mode="global", cell_fmt=lambda v: f"{v:+.1f}%",
                     cbar_label="net area / reference coverage-time (%)",
                     title="Coverage-diff relative net area (% of reference) "
                           "— green = left ahead, red = right ahead")
    else:
        mode = "per_target" if args.color == "per-target" else "global"
        plot_heatmap(out_dir / "area_heatmap.png", targets, pairs, net,
                     mode=mode, cell_fmt=lambda v: f"{v:+.1f}",
                     cbar_label="net area (branch*h)",
                     title="Coverage-diff net area (pos - neg) "
                           "— green = left ahead, red = right ahead")


if __name__ == "__main__":
    main()