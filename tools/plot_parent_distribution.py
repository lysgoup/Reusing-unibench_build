#!/usr/bin/env python3
"""
Visualize parent-child relationship distribution from a single parent_map.txt file.
Shows how many children each input produced.

Usage:
    python3 plot_parent_distribution.py /path/to/parent_map.txt
    python3 plot_parent_distribution.py /path/to/parent_map.txt --out result.png
"""

import os
import argparse
from collections import Counter
import matplotlib.pyplot as plt
import numpy as np


def load_parent_map(filepath):
    """Returns:
      all_ids     : sorted list of all input IDs
      child_count : dict[input_id] -> number of children
      seeds       : number of inputs whose parent is 'none'
    """
    all_ids = []
    child_count = Counter()
    seeds = 0

    with open(filepath) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            child_id, parent_id = parts
            all_ids.append(int(child_id))
            if parent_id == "none":
                seeds += 1
            else:
                child_count[int(parent_id)] += 1

    all_ids.sort()
    return all_ids, child_count, seeds


def main():
    parser = argparse.ArgumentParser(
        description="Plot parent distribution from a parent_map.txt file")
    parser.add_argument("input", help="Path to parent_map.txt")
    parser.add_argument("--out", default=None,
                        help="Output PNG path (default: parent_distribution.png in same dir)")
    args = parser.parse_args()

    all_ids, child_count, seeds = load_parent_map(args.input)
    total = len(all_ids)
    generated = total - seeds

    # y값: 각 입력 ID의 자식 수 (parent로 지정된 횟수, 없으면 0)
    y_vals = np.array([child_count.get(i, 0) for i in all_ids])

    title = os.path.abspath(args.input)
    fig, (ax_bar, ax_top) = plt.subplots(1, 2, figsize=(16, 6))
    fig.suptitle(title, fontsize=8)

    # ── 모든 입력 ID별 자식 수 scatter plot ───────────────────────────────
    # 자식이 없는 입력: 작은 회색 점
    zero_ids  = [i for i, v in zip(all_ids, y_vals) if v == 0]
    zero_vals = [0] * len(zero_ids)
    # 자식이 있는 입력: 파란 점 (크기는 자식 수에 비례)
    pos_ids  = [i for i, v in zip(all_ids, y_vals) if v > 0]
    pos_vals = [v for v in y_vals if v > 0]

    ax_bar.scatter(zero_ids, zero_vals, s=2, color="lightgray",
                   linewidths=0, label="no children", zorder=1)
    if pos_vals:
        max_size = 80
        sizes = np.array(pos_vals, dtype=float)
        sizes = sizes / sizes.max() * max_size + 4
        ax_bar.scatter(pos_ids, pos_vals, s=sizes, color="steelblue",
                       linewidths=0, label="has children", zorder=2)
        mean_v = np.mean(y_vals)
        ax_bar.axhline(mean_v, color="tomato", linestyle="--", linewidth=1,
                       label=f"mean={mean_v:.1f}")

    ax_bar.legend(fontsize=8)
    ax_bar.set_title(
        f"total={total}  seeds={seeds}  generated={generated}  unique parents={len(child_count)}",
        fontsize=9)
    ax_bar.set_xlabel("Input ID", fontsize=9)
    ax_bar.set_ylabel("Number of children", fontsize=9)
    ax_bar.set_xlim(all_ids[0] - 0.5, all_ids[-1] + 0.5)

    # ── Top-20 parents ────────────────────────────────────────────────────
    top20 = child_count.most_common(20)
    if top20:
        ids = [str(p) for p, _ in top20]
        vals = [c for _, c in top20]
        bars = ax_top.barh(ids[::-1], vals[::-1], color="steelblue")
        for bar, val in zip(bars, vals[::-1]):
            ax_top.text(bar.get_width() + 0.3, bar.get_y() + bar.get_height() / 2,
                        str(val), va="center", fontsize=7)
        # bar chart와 동일하게 막대 반폭(0.5)만큼 왼쪽 여백 추가
        max_val = vals[0]
        ax_top.set_xlim(-0.5, max_val * 1.1)
    else:
        ax_top.text(0.5, 0.5, "No parent data", ha="center", va="center")

    ax_top.set_xlabel("Number of children", fontsize=9)
    ax_top.set_title("Top-20 parents by child count", fontsize=9)

    plt.tight_layout()
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(args.input)),
                                   "parent_distribution.png")
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"Saved: {out}")
    plt.close()


if __name__ == "__main__":
    main()
