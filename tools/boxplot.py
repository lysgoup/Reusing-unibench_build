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


def list_programs(graph_data_dir):
    return sorted(
        f.replace("_angora_branch_count.txt", "")
        for f in os.listdir(graph_data_dir)
        if f.endswith("_angora_branch_count.txt")
    )


def discover_variants(graph_data_dir, programs):
    """Find fuzzer result names (other than angora) present for at least one program."""
    prefix_suffix_len = {p: (f"{p}_", "_branch_count.txt") for p in programs}
    variants = set()
    for f in os.listdir(graph_data_dir):
        for program, (prefix, suffix) in prefix_suffix_len.items():
            if f.startswith(prefix) and f.endswith(suffix):
                variant = f[len(prefix):-len(suffix)]
                if variant != "angora":
                    variants.add(variant)
                break
    return sorted(variants)


def compute_ratios(data_dir, variant, ratio=False, sorting=False, target_programs=None):
    graph_data_dir = os.path.join(data_dir, "graph", "data")

    all_programs = list_programs(graph_data_dir)
    if target_programs is not None:
        all_programs = [p for p in all_programs if p in target_programs]
    programs = [
        p for p in all_programs
        if os.path.exists(os.path.join(graph_data_dir, f"{p}_{variant}_branch_count.txt"))
    ]

    result = {}  # program -> list of (value, status)

    for program in programs:
        angora = read_branch_data(
            os.path.join(graph_data_dir, f"{program}_angora_branch_count.txt")
        )
        reusing = read_branch_data(
            os.path.join(graph_data_dir, f"{program}_{variant}_branch_count.txt")
        )

        if sorting:  # pair trials by coverage rank instead of by trial id
            angora_order = sorted(angora, key=lambda t: angora[t][-1])
            reusing_order = sorted(reusing, key=lambda t: reusing[t][-1])
            pairs = list(zip(angora_order, reusing_order))
        else:
            pairs = [(trial, trial) for trial in sorted(angora)]

        entries = []
        for a_trial, r_trial in pairs:
            a_vals = angora[a_trial]
            r_vals = reusing[r_trial]
            total = len(a_vals) - 1  # e.g. 96 for 97 snapshots at 15-min intervals
            final = a_vals[-1]

            if final < r_vals[-1]:  # reusing's 24h coverage exceeds angora's: measure against the full 24h window
                t = next(i for i, v in enumerate(r_vals) if v > final)
                if ratio:
                    entries.append((t / total, "reached"))
                else:
                    entries.append((t * 15 / 60, "reached"))
            elif a_vals[-1] == a_vals[0]:  # angora had no coverage growth, and reusing didn't beat it either
                if ratio:
                    continue  # t_angora = 0, ratio undefined
                t = next((i for i, v in enumerate(r_vals) if v > final), None)
                if t is None:
                    entries.append((total * 15 / 60, "stagnant"))  # both had no growth
                else:
                    entries.append((t * 15 / 60, "reached"))
            else:  # angora's 24h coverage is the higher (or equal) one, and angora did grow
                t_angora = next(i for i, v in enumerate(a_vals) if v >= final)
                t = next((i for i, v in enumerate(r_vals) if v >= final), None)
                if t is None:
                    if ratio:
                        entries.append((total / t_angora, "capped"))
                    else:
                        entries.append((total * 15 / 60, "capped"))
                else:
                    if ratio:
                        entries.append((t / t_angora, "reached"))
                    else:
                        entries.append((t * 15 / 60, "reached"))

        result[program] = entries

    return programs, result


def plot(programs, result, variant, log_y=False, ratio=False, output="boxplot.png"):
    fig, ax = plt.subplots(figsize=(max(8, len(programs) * 2), 6))

    has_capped = False
    has_stagnant = False
    LOG_ZERO = 1 / 60  # 1 minute in hours, used as floor for log scale

    for i, program in enumerate(programs):
        entries = result[program]
        normal_y   = [r for r, c in entries if c == "reached"]
        capped_y   = [r for r, c in entries if c == "capped"]
        stagnant_y = [r for r, c in entries if c == "stagnant"]

        if log_y:
            normal_y   = [v if v > 0 else LOG_ZERO for v in normal_y]
            capped_y   = [v if v > 0 else LOG_ZERO for v in capped_y]
            stagnant_y = [v if v > 0 else LOG_ZERO for v in stagnant_y]

        if normal_y:
            x = np.random.normal(i, 0.09, len(normal_y))
            ax.scatter(x, normal_y, alpha=0.65, s=40, color="goldenrod", zorder=3)
        if capped_y:
            x = np.random.normal(i, 0.09, len(capped_y))
            ax.scatter(x, capped_y, alpha=0.65, s=40, color="crimson", zorder=3)
            has_capped = True
        if stagnant_y:
            x = np.random.normal(i, 0.09, len(stagnant_y))
            ax.scatter(x, stagnant_y, alpha=0.65, s=40, color="slategray", zorder=3)
            has_stagnant = True

    if log_y:
        data = [[v if v > 0 else LOG_ZERO for v, _ in result[p]] for p in programs]
    else:
        data = [[v for v, _ in result[p]] for p in programs]
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
    if ratio:
        ax.set_ylabel(f"Time ratio ({variant} / angora)")
        ax.set_title(f"Relative time for {variant} to match angora's final coverage")
        ax.axhline(y=1.0, color="black", linewidth=0.8, linestyle="--", alpha=0.5)
    else:
        ax.set_ylabel("Time to reach angora's final coverage (hours)")
        ax.set_title(f"Time for {variant} to match angora's final coverage")
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
    if has_stagnant:
        legend_handles.append(
            Line2D([0], [0], marker="o", color="w", markerfacecolor="slategray",
                   markersize=8, label="both stagnant (capped at total)")
        )
    ax.legend(handles=legend_handles, loc="upper right", fontsize=8, markerscale=0.8,
              handlelength=1.0, borderpad=0.5, labelspacing=0.3)

    plt.tight_layout()
    plt.savefig(output, dpi=300, bbox_inches="tight")
    print(f"Saved figure to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir")
    parser.add_argument("--target",
                        help="Comma-separated target program(s) to include (e.g. exiv2,mp3gain). "
                             "Default: every program found in graph/data.")
    parser.add_argument("--log-y", action="store_true", help="Use log scale on the y-axis")
    parser.add_argument("--ratio", action="store_true",
                        help="Show ratio of reusing time to angora time instead of absolute hours")
    parser.add_argument("--sorting", action="store_true",
                        help="Pair trials by final-coverage rank (lowest with lowest, etc.) "
                             "instead of by matching trial id")
    args = parser.parse_args()

    graph_data_dir = os.path.join(args.data_dir, "graph", "data")
    target_programs = None
    if args.target:
        target_programs = [t.strip() for t in args.target.split(",") if t.strip()]
        unknown = set(target_programs) - set(list_programs(graph_data_dir))
        if unknown:
            print(f"Warning: no data found for target(s): {', '.join(sorted(unknown))}")

    variants = discover_variants(graph_data_dir, list_programs(graph_data_dir))
    if not variants:
        raise SystemExit("No non-angora results found in " + graph_data_dir)

    for variant in variants:
        programs, result = compute_ratios(
            args.data_dir, variant, ratio=args.ratio, sorting=args.sorting,
            target_programs=target_programs,
        )
        if not programs:
            print(f"Skipping {variant}: no matching programs have both angora and {variant} data.")
            continue
        output = os.path.join(args.data_dir, "graph", f"boxplot_{variant}.png")
        plot(programs, result, variant, log_y=args.log_y, ratio=args.ratio, output=output)
