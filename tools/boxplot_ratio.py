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


def time_to_reach(vals, target):
    for i, v in enumerate(vals):
        if v >= target:
            return i
    return None  # unreachable if target <= vals[-1] (branch counts are monotonic)


def compute_ratios(data_dir, sorting=False):
    graph_data_dir = os.path.join(data_dir, "graph", "data")

    programs = sorted(
        f.replace("_angora_branch_count.txt", "")
        for f in os.listdir(graph_data_dir)
        if f.endswith("_angora_branch_count.txt")
    )

    result = {}  # program -> list of ratio values (reusing time / angora time)

    for program in programs:
        angora = read_branch_data(
            os.path.join(graph_data_dir, f"{program}_angora_branch_count.txt")
        )
        reusing = read_branch_data(
            os.path.join(graph_data_dir, f"{program}_angora-reusing_branch_count.txt")
        )

        if sorting:  # pair trials by coverage rank instead of by trial id
            angora_order = sorted(angora, key=lambda t: angora[t][-1])
            reusing_order = sorted(reusing, key=lambda t: reusing[t][-1])
            pairs = list(zip(angora_order, reusing_order))
        else:
            pairs = [(trial, trial) for trial in sorted(angora)]

        ratios = []
        for a_trial, r_trial in pairs:
            a_vals = angora[a_trial]
            r_vals = reusing[r_trial]

            # Target the lower of the two final coverages: whichever trial has
            # the higher final coverage is guaranteed (by monotonicity) to pass
            # through this value, so both times below are always well-defined.
            target = min(a_vals[-1], r_vals[-1])

            t_a = time_to_reach(a_vals, target)
            t_r = time_to_reach(r_vals, target)

            if t_a == 0:
                # Both trials start from the same seed corpus, so t_a == 0 only
                # happens when neither trial grew past it (target == seed
                # coverage) -- a true tie with nothing to measure.
                continue

            ratios.append(t_r / t_a)

        result[program] = ratios

    return programs, result


def plot(programs, result, log_y=False, output="boxplot_ratio.png"):
    fig, ax = plt.subplots(figsize=(max(8, len(programs) * 2), 6))

    LOG_FLOOR = 1e-3  # guards against log(0) in the rare case ratio == 0

    for i, program in enumerate(programs):
        ratios = result[program]
        faster = [r for r in ratios if r < 1]   # reusing reached the shared target sooner
        slower = [r for r in ratios if r >= 1]  # angora reached it sooner (or a tie)

        if log_y:
            faster = [v if v > 0 else LOG_FLOOR for v in faster]
            slower = [v if v > 0 else LOG_FLOOR for v in slower]

        if faster:
            x = np.random.normal(i, 0.09, len(faster))
            ax.scatter(x, faster, alpha=0.65, s=40, color="goldenrod", zorder=3)
        if slower:
            x = np.random.normal(i, 0.09, len(slower))
            ax.scatter(x, slower, alpha=0.65, s=40, color="crimson", zorder=3)

    if log_y:
        data = [[v if v > 0 else LOG_FLOOR for v in result[p]] for p in programs]
    else:
        data = [result[p] for p in programs]
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
    ax.set_ylabel("Time ratio (reusing / angora) to reach min(final coverage)")
    ax.set_title("Relative speed to reach the lower of the two trials' final coverage")
    ax.axhline(y=1.0, color="black", linewidth=0.8, linestyle="--", alpha=0.5)
    if log_y:
        ax.set_yscale('log')
    ax.grid(axis="y", alpha=0.3)
    ax.grid(axis="x", alpha=0.2)

    legend_handles = [
        Line2D([0], [0], marker="o", color="w", markerfacecolor="goldenrod",
               markersize=8, label="reusing faster"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor="crimson",
               markersize=8, label="angora faster"),
    ]
    ax.legend(handles=legend_handles, loc="upper right", fontsize=8, markerscale=0.8,
              handlelength=1.0, borderpad=0.5, labelspacing=0.3)

    plt.tight_layout()
    plt.savefig(output, dpi=300, bbox_inches="tight")
    print(f"Saved figure to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir")
    parser.add_argument("--log-y", action="store_true", help="Use log scale on the y-axis")
    parser.add_argument("--sorting", action="store_true",
                        help="Pair trials by final-coverage rank (lowest with lowest, etc.) "
                             "instead of by matching trial id")
    args = parser.parse_args()

    programs, result = compute_ratios(args.data_dir, sorting=args.sorting)
    output = os.path.join(args.data_dir, "graph", "boxplot_ratio.png")
    plot(programs, result, log_y=args.log_y, output=output)
