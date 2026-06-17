import argparse
import os
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D


def read_branch_data(filepath):
    data = {}
    with open(filepath) as f:
        for line in f:
            parts = line.split()
            if parts[0] == "avg":
                continue
            trial_id = int(parts[0])
            data[trial_id] = list(map(int, parts[1:]))
    return data


def compute_ratios(data_dir):
    graph_data_dir = os.path.join(data_dir, "graph", "data")

    programs = sorted(
        f.replace("_angora_branch_count.txt", "")
        for f in os.listdir(graph_data_dir)
        if f.endswith("_angora_branch_count.txt")
    )

    result = {}  # program -> list of (hours, capped)

    for program in programs:
        angora = read_branch_data(
            os.path.join(graph_data_dir, f"{program}_angora_branch_count.txt")
        )
        reusing = read_branch_data(
            os.path.join(graph_data_dir, f"{program}_angora-reusing_branch_count.txt")
        )

        entries = []
        for trial in sorted(angora):
            a_vals = angora[trial]
            r_vals = reusing[trial]
            total = len(a_vals) - 1  # e.g. 96 for 97 snapshots at 15-min intervals
            final = a_vals[-1]

            t = next((i for i, v in enumerate(r_vals) if v >= final), None)
            if t is None:
                entries.append((total * 15 / 60, True))
            else:
                entries.append((t * 15 / 60, False))

        result[program] = entries

    return programs, result


def plot(programs, result, log_y=False, output="boxplot.png"):
    fig, ax = plt.subplots(figsize=(max(8, len(programs) * 2), 6))

    has_capped = False
    LOG_ZERO = 1 / 60  # 1 minute in hours, used as floor for log scale

    for i, program in enumerate(programs):
        entries = result[program]
        normal_y = [r for r, c in entries if not c]
        capped_y = [r for r, c in entries if c]

        if log_y:
            normal_y = [v if v > 0 else LOG_ZERO for v in normal_y]
            capped_y = [v if v > 0 else LOG_ZERO for v in capped_y]

        if normal_y:
            x = np.random.normal(i, 0.06, len(normal_y))
            ax.scatter(x, normal_y, alpha=0.65, s=40, color="goldenrod", zorder=3)
        if capped_y:
            x = np.random.normal(i, 0.06, len(capped_y))
            ax.scatter(x, capped_y, alpha=0.65, s=40, color="crimson", zorder=3)
            has_capped = True

    if log_y:
        data = [[v if v > 0 else LOG_ZERO for v, _ in result[p]] for p in programs]
    else:
        data = [[r for r, _ in result[p]] for p in programs]
    ax.boxplot(
        data,
        positions=np.arange(len(programs)),
        widths=0.5,
        patch_artist=True,
        showfliers=False,
        boxprops=dict(facecolor="orange", alpha=0.35),
        medianprops=dict(color="orange", linewidth=2),
        whiskerprops=dict(color="gray"),
        capprops=dict(color="gray"),
    )

    ax.set_xticks(np.arange(len(programs)))
    ax.set_xticklabels(programs, rotation=15, ha="right")
    ax.set_ylabel("Time to reach angora's final coverage (hours)")
    ax.set_title("Time for angora-reusing to match angora's final coverage")
    all_vals = [r for p in programs for r, _ in result[p]]
    val_min, val_max = min(all_vals), max(all_vals)
    if log_y:
        ax.set_yscale('log')
        ax.set_ylim(LOG_ZERO * 0.9, val_max * 1.1)
    else:
        val_range = val_max - val_min
        ax.set_ylim(val_min, val_max + val_range * 0.03)
        yticks = list(ax.get_yticks())
        if val_max not in yticks:
            yticks.append(val_max)
        ax.set_yticks(sorted(yticks))
    ax.grid(axis="y", alpha=0.3)
    ax.grid(axis="x", alpha=0.2)

    legend_handles = [
        Line2D([0], [0], marker="o", color="w", markerfacecolor="goldenrod",
               markersize=8, label="reached"),
    ]
    if has_capped:
        legend_handles.append(
            Line2D([0], [0], marker="o", color="w", markerfacecolor="crimson",
                   markersize=8, label="never reached (capped at total)")
        )
    ax.legend(handles=legend_handles, loc="upper right", fontsize=8, markerscale=0.8,
              handlelength=1.0, borderpad=0.5, labelspacing=0.3)

    plt.tight_layout()
    plt.savefig(output, dpi=300, bbox_inches="tight")
    print(f"Saved figure to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir")
    parser.add_argument("--log-y", action="store_true", help="Use log scale on the y-axis")
    args = parser.parse_args()

    programs, result = compute_ratios(args.data_dir)
    plot(programs, result, log_y=args.log_y)
