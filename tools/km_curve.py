import argparse
import os
import numpy as np
import matplotlib.pyplot as plt
from lifelines import KaplanMeierFitter


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


def compute_km_data(data_dir, ratio=False):
    graph_data_dir = os.path.join(data_dir, "graph", "data")

    programs = sorted(
        f.replace("_angora_branch_count.txt", "")
        for f in os.listdir(graph_data_dir)
        if f.endswith("_angora_branch_count.txt")
    )

    result = {}  # program -> list of (time_or_ratio, event: bool)

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
            total = len(a_vals) - 1
            final = a_vals[-1]

            if a_vals[-1] == a_vals[0]:  # angora had no growth
                if ratio:
                    continue  # t_angora = 0, skip
                t = next((i for i, v in enumerate(r_vals) if v > final), None)
                if t is None:
                    entries.append((total * 15 / 60, False))  # both stagnant: censored
                else:
                    entries.append((t * 15 / 60, True))
            else:
                t_angora = next(i for i, v in enumerate(a_vals) if v >= final)
                t = next((i for i, v in enumerate(r_vals) if v >= final), None)
                if t is None:
                    if ratio:
                        entries.append((total / t_angora, False))  # censored
                    else:
                        entries.append((total * 15 / 60, False))  # censored
                else:
                    if ratio:
                        entries.append((t / t_angora, True))
                    else:
                        entries.append((t * 15 / 60, True))

        result[program] = entries

    return programs, result


def plot(programs, result, log_x=False, ratio=False, output="km_curve.png"):
    ncols = min(3, len(programs))
    nrows = (len(programs) + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(ncols * 5, nrows * 4))
    axes = np.array(axes).flatten()

    for i, program in enumerate(programs):
        ax = axes[i]
        entries = result[program]

        if not entries:
            ax.set_title(program, fontsize=10)
            ax.text(0.5, 0.5, "no data", ha="center", va="center", transform=ax.transAxes)
            continue

        durations = [t for t, _ in entries]
        events    = [int(e) for _, e in entries]

        kmf = KaplanMeierFitter()
        kmf.fit(durations, events)
        kmf.plot_survival_function(ax=ax, ci_show=True, color="steelblue")

        if ratio:
            ax.axvline(x=1.0, color="gray", linewidth=0.8, linestyle="--", alpha=0.6)

        n_total   = len(entries)
        n_reached = sum(events)
        ax.set_title(f"{program}  ({n_reached}/{n_total} reached)", fontsize=9)
        ax.set_xlabel("")
        ax.set_ylabel("")
        ax.get_legend().remove()
        if not ratio:
            ax.set_xlim(0, 24)
        ax.set_ylim(-0.05, 1.05)
        ax.grid(alpha=0.3)
        if log_x:
            ax.set_xscale("log")

    for j in range(len(programs), len(axes)):
        axes[j].set_visible(False)

    xlabel = "Time ratio (reusing / angora)" if ratio else "Time (hours)"
    fig.supxlabel(xlabel, fontsize=11, y=0.02)
    fig.supylabel("S(t)", fontsize=11, x=0.02)
    fig.suptitle("Kaplan-Meier: Time for angora-reusing to match angora's final coverage",
                 fontsize=12)

    plt.tight_layout()
    plt.savefig(output, dpi=300, bbox_inches="tight")
    print(f"Saved figure to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir")
    parser.add_argument("--log-x", action="store_true", help="Use log scale on the x-axis")
    parser.add_argument("--ratio", action="store_true",
                        help="Use time ratio (reusing / angora) instead of absolute hours")
    args = parser.parse_args()

    programs, result = compute_km_data(args.data_dir, ratio=args.ratio)
    output = os.path.join(args.data_dir, "graph", "km_curve.png")
    plot(programs, result, log_x=args.log_x, ratio=args.ratio, output=output)
