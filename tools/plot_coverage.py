#!/usr/bin/env python3
"""
Coverage data visualization script - Branch coverage progress per target
"""

import os
import sys
import re
from pathlib import Path
import argparse
from collections import defaultdict

try:
    import numpy as np
    import matplotlib.pyplot as plt
    from matplotlib.ticker import MaxNLocator
except ImportError as e:
    print(f"Error: {e.name} is required. Install with: pip install numpy matplotlib")
    sys.exit(1)


def bootstrap_ci(values, n_resamples=1000, confidence=0.95, seed=42, statistic='mean'):
    """
    Compute a bootstrap confidence interval for the mean or median of `values`.

    Args:
        statistic: 'mean' or 'median' - which statistic the CI is built around

    Returns:
        tuple: (lower, upper) bounds of the confidence interval
    """
    values = np.asarray(values, dtype=float)
    n = values.size
    if n == 0:
        return None, None
    if n == 1:
        return float(values[0]), float(values[0])

    rng = np.random.default_rng(seed)
    resample_idx = rng.integers(0, n, size=(n_resamples, n))
    resamples = values[resample_idx]
    if statistic == 'median':
        resample_stats = np.median(resamples, axis=1)
    else:
        resample_stats = resamples.mean(axis=1)

    alpha = 1 - confidence
    lower = np.percentile(resample_stats, 100 * alpha / 2)
    upper = np.percentile(resample_stats, 100 * (1 - alpha / 2))
    return float(lower), float(upper)


def check_coverage_directory(workdir):
    """
    Check if coverage directory exists and is not empty.

    Args:
        workdir: Path to work directory (_result directory)

    Returns:
        bool: True if coverage directory exists and has content, False otherwise
    """
    workdir = Path(workdir).resolve()
    coverage_dir = workdir / 'coverage'

    # Check if coverage directory exists
    if not coverage_dir.exists():
        print(f"Error: Coverage directory not found: {coverage_dir}")
        return False

    # Check if coverage directory is empty
    if not any(coverage_dir.iterdir()):
        print(f"Error: Coverage directory is empty: {coverage_dir}")
        return False

    # Directory exists and has content
    print(f"✓ Coverage directory found: {coverage_dir}")
    return True


def setup_output_directories(workdir):
    """
    Create graph and graph/data directories.

    Args:
        workdir: Path to work directory (_result directory)

    Returns:
        tuple: (graph_dir, data_dir) paths
    """
    workdir = Path(workdir).resolve()
    graph_dir = workdir / 'graph'
    data_dir = graph_dir / 'data'

    # Create directories if they don't exist
    graph_dir.mkdir(parents=True, exist_ok=True)
    data_dir.mkdir(parents=True, exist_ok=True)

    print(f"✓ Graph directory created: {graph_dir}")
    print(f"✓ Data directory created: {data_dir}")

    return graph_dir, data_dir


def extract_branch_hit_counts(coverage_log_path):
    """
    Extract branch hit counts from coverage.log file.

    Format: Each 3 lines contain:
    1. lines..... : X% (N of M lines)
    2. functions.: X% (N of M functions)
    3. branches..: X% (N of M branches)

    Extract branch hit count from every 3rd line (branches line).

    Args:
        coverage_log_path: Path to coverage.log file

    Returns:
        list: List of branch hit counts
    """
    try:
        with open(coverage_log_path, 'r') as f:
            lines = f.readlines()

        branch_counts = []
        # Every 3rd line (index 2, 5, 8, ...) contains branch information
        for i in range(2, len(lines), 3):
            line = lines[i]
            # Extract first number from "branches...: X% (N of M branches)"
            match = re.search(r'\((\d+) of \d+ branches\)', line)
            if match:
                branch_counts.append(int(match.group(1)))

        return branch_counts if branch_counts else None
    except Exception as e:
        print(f"Error reading {coverage_log_path}: {e}", file=sys.stderr)
        return None


def collect_and_save_branch_data(workdir, coverage_dir, data_dir, use_median=False):
    """
    Collect branch hit count data and save to files.

    Expected structure:
    coverage/
    ├── fuzzer1/
    │   ├── target1/
    │   │   ├── campaign_num1/
    │   │   │   └── coverage.info
    │   │   └── campaign_num2/
    │   │       └── coverage.info
    │   └── target2/
    └── fuzzer2/

    Output files in data_dir:
    {target}_{fuzzer}_branch_count.txt
    Format: campaign_num branch_hit_count [branch_hit_count ...]

    Args:
        workdir: Path to work directory
        coverage_dir: Path to coverage directory
        data_dir: Path to output data directory

    Returns:
        dict: Summary of collected data
    """
    coverage_dir = Path(coverage_dir)
    data_dir = Path(data_dir)
    data_summary = defaultdict(lambda: defaultdict(list))
    files_created = 0

    # Traverse fuzzer -> target -> campaign_num
    for fuzzer_path in coverage_dir.iterdir():
        if not fuzzer_path.is_dir():
            continue
        fuzzer_name = fuzzer_path.name

        for target_path in fuzzer_path.iterdir():
            if not target_path.is_dir():
                continue
            target_name = target_path.name

            # Collect campaigns for this target/fuzzer
            campaign_data = []  # List of (campaign_num, branch_hit_count)

            for campaign_path in target_path.iterdir():
                if not campaign_path.is_dir():
                    continue
                campaign_num = campaign_path.name

                # Look for coverage.log
                coverage_log = campaign_path / 'coverage.log'
                if not coverage_log.exists():
                    continue

                # Extract branch hit counts from log file
                branch_counts = extract_branch_hit_counts(str(coverage_log))
                if branch_counts is not None:
                    # Store the campaign number and all branch counts found
                    campaign_data.append((campaign_num, branch_counts))

            # Save data to file if we have any
            if campaign_data:
                # Sort by campaign number (convert to int for proper numeric sorting)
                campaign_data.sort(key=lambda x: int(x[0]))

                output_filename = f"{target_name}_{fuzzer_name}_branch_count.txt"
                output_path = data_dir / output_filename

                with open(output_path, 'w') as f:
                    # Write campaign data
                    for campaign_num, branch_counts in campaign_data:
                        line = f"{campaign_num}"
                        for count in branch_counts:
                            line += f" {count}"
                        f.write(line + "\n")

                    # Calculate and write the center line (mean or median)
                    # Find the minimum number of columns (only use columns where all campaigns have data)
                    if campaign_data:
                        min_columns = min(len(counts) for _, counts in campaign_data)

                        if min_columns > 0:
                            centers = []
                            for col_idx in range(min_columns):
                                col_values = [counts[col_idx] for _, counts in campaign_data]
                                if col_values:
                                    center = np.median(col_values) if use_median else (sum(col_values) / len(col_values))
                                    centers.append(center)

                            # Write center line (label stays "avg" for parsing;
                            # the value is the median instead of the mean when use_median is set)
                            avg_line = "avg"
                            for center in centers:
                                avg_line += f" {center:.2f}"
                            f.write(avg_line + "\n")

                data_summary[target_name][fuzzer_name] = len(campaign_data)
                files_created += 1
                print(f"✓ Created: {output_filename} ({len(campaign_data)} campaigns)")

    return dict(data_summary), files_created


# Bottom margin is a fixed constant (not scaled to the data range) so that
# small gaps between curves near their max aren't swamped by whitespace
# reserved for the low end of the range.
BOTTOM_MARGIN = 20


def set_ylim_with_margin(ax, all_values):
    """
    Set Y-axis limits with a fixed bottom margin and a top margin that scales
    with the max value, so small differences between curves near their max
    stay visible regardless of how far the range extends toward zero.

    Both margins are capped by the data's actual spread (max - min): when the
    curves are nearly identical, a margin sized for the raw magnitude would
    swallow the whole gap between them. Capping it to the spread shrinks the
    Y range down toward the data instead, so matplotlib's tick locator picks
    a much finer step (e.g. 1 instead of 20) and the difference stays visible.
    """
    if not all_values:
        return
    min_val = min(all_values)
    max_val = max(all_values)
    spread = max_val - min_val
    spread_cap = max(spread * 0.5, 1)

    bottom_margin = min(BOTTOM_MARGIN, spread_cap)
    top_margin = min(max(max_val * 0.03, 10), spread_cap)

    ax.set_ylim(min_val - bottom_margin, max_val + top_margin)


def plot_branch_graphs(graph_dir, data_dir, interval, log_x=False, use_median=False, only_average=False):
    """
    Generate branch hit count graphs from data files.

    File format:
    campaign_num branch_count_t0 branch_count_t1 branch_count_t2 ...
    ...
    avg avg_t0 avg_t1 avg_t2 ...

    Each column represents `interval` minutes.

    Args:
        graph_dir: Path to graph directory (output location)
        data_dir: Path to data directory (input files)
    """
    graph_dir = Path(graph_dir)
    data_dir = Path(data_dir)

    if not data_dir.exists():
        print(f"Error: Data directory not found: {data_dir}")
        return

    # Find all branch_count.txt files
    data_files = sorted(data_dir.glob('*_branch_count.txt'))

    if not data_files:
        print(f"No data files found in {data_dir}")
        return

    print(f"Generating {len(data_files)} graphs...")

    center_label = 'median' if use_median else 'avg'

    for data_file in data_files:
        # Extract target and fuzzer from filename
        # Format: {target}_{fuzzer}_branch_count.txt
        filename = data_file.stem.replace('_branch_count', '')
        parts = filename.split('_', 1)

        if len(parts) != 2:
            print(f"Warning: Could not parse filename: {data_file.name}")
            continue

        target_name = parts[0]
        fuzzer_name = parts[1]

        # Read data file
        try:
            with open(data_file, 'r') as f:
                lines = f.readlines()
        except Exception as e:
            print(f"Error reading {data_file}: {e}")
            continue

        if not lines:
            continue

        # Parse data
        campaign_data = {}  # {campaign_num: [values]}
        avg_data = None

        for line in lines:
            parts = line.strip().split()
            if not parts:
                continue

            label = parts[0]
            values = [float(x) for x in parts[1:]]

            if label == 'avg':
                avg_data = values
            else:
                campaign_data[label] = values

        if not campaign_data:
            print(f"Warning: No campaign data in {data_file.name}")
            continue

        # Determine the number of data points (use avg_data length if available)
        if avg_data:
            num_points = len(avg_data)
        else:
            num_points = len(next(iter(campaign_data.values())))

        # Generate time points (in hours)
        time_points = [i * interval / 60 for i in range(num_points)]

        # Create figure with larger height
        fig, ax = plt.subplots(figsize=(12, 8))

        # Collect all values to determine Y-axis range
        all_values = []
        if not only_average:
            for values in campaign_data.values():
                all_values.extend(values[:num_points])
        if avg_data:
            all_values.extend(avg_data)

        # Plot each campaign in blue
        if not only_average:
            for campaign_num in sorted(campaign_data.keys(), key=lambda x: int(x)):
                values = campaign_data[campaign_num]
                # Use only as many values as we have time points
                if len(values) >= num_points:
                    ax.plot(time_points, values[:num_points], color='blue', alpha=0.3, linewidth=1.5, marker='o', markersize=2)

        # Plot average in red
        if avg_data:
            ax.plot(time_points, avg_data, color='red', linewidth=2, label=center_label, marker='o', markersize=2.5)

        # Set Y-axis range: fixed bottom margin, top margin scaled to max_val
        set_ylim_with_margin(ax, all_values)

        # Set X-axis range and scale
        if log_x:
            ax.set_xscale('log')
            ax.set_xlim(time_points[1] if time_points[0] == 0 else time_points[0], time_points[-1])
        else:
            ax.set_xlim(0, time_points[-1])
            ax.xaxis.set_major_locator(MaxNLocator(integer=True))

        # Set labels and title
        ax.set_xlabel('Time (hours)')
        ax.set_ylabel('Branch Hit Count')
        ax.set_title(f'{target_name} - {fuzzer_name} - Branch Hit Count Progress')
        ax.grid(True, alpha=0.3)

        # Add legend
        if only_average:
            red_line = plt.Line2D([0], [0], color='red', linewidth=2)
            ax.legend([red_line], [center_label], loc='best')
        else:
            blue_line = plt.Line2D([0], [0], color='blue', linewidth=1)
            red_line = plt.Line2D([0], [0], color='red', linewidth=2)
            ax.legend([blue_line, red_line], ['each campaign', center_label], loc='best')

        # Save figure
        output_filename = f"{target_name}_{fuzzer_name}_branch_graph.png"
        output_path = graph_dir / output_filename

        plt.tight_layout()
        plt.savefig(output_path, dpi=150, bbox_inches='tight')
        plt.close()

        print(f"✓ Created: {output_filename}")


def plot_comparison_graphs(graph_dir, data_dir, interval, log_x=False, use_median=False, only_average=False):
    """
    Generate comparison graphs for targets with multiple fuzzers.
    Shows avg lines with bootstrap 95% CI bands from different fuzzers for the same target.

    Args:
        graph_dir: Path to graph directory (output location)
        data_dir: Path to data directory (input files)
    """
    graph_dir = Path(graph_dir)
    data_dir = Path(data_dir)

    if not data_dir.exists():
        return

    # Find all branch_count.txt files
    data_files = sorted(data_dir.glob('*_branch_count.txt'))

    if not data_files:
        return

    # Group by target and collect fuzzer data (campaign and avg)
    target_fuzzers = {}  # {target: {fuzzer: {campaign_data, avg_data, time_points}}}

    for data_file in data_files:
        # Extract target and fuzzer from filename
        # Format: {target}_{fuzzer}_branch_count.txt
        filename = data_file.stem.replace('_branch_count', '')
        parts = filename.split('_', 1)

        if len(parts) != 2:
            continue

        target_name = parts[0]
        fuzzer_name = parts[1]

        # Read data file
        try:
            with open(data_file, 'r') as f:
                lines = f.readlines()
        except Exception as e:
            continue

        if not lines:
            continue

        # Parse data to extract campaign and avg data
        campaign_data = {}
        avg_data = None

        for line in lines:
            line_parts = line.strip().split()
            if not line_parts:
                continue

            label = line_parts[0]
            values = [float(x) for x in line_parts[1:]]

            if label == 'avg':
                avg_data = values
            else:
                campaign_data[label] = values

        if avg_data is None or not campaign_data:
            continue

        # Generate time points (in hours)
        num_points = len(avg_data)
        time_points = [i * interval / 60 for i in range(num_points)]

        # Calculate bootstrap 95% CI of the mean for each time point
        ci_upper = []
        ci_lower = []
        if only_average:
            ci_lower = list(avg_data)
            ci_upper = list(avg_data)
        else:
            for col_idx in range(num_points):
                col_values = [data[col_idx] for data in campaign_data.values() if col_idx < len(data)]
                if col_values:
                    lower, upper = bootstrap_ci(col_values, statistic='median' if use_median else 'mean')
                    ci_lower.append(lower)
                    ci_upper.append(upper)
                else:
                    ci_lower.append(avg_data[col_idx])
                    ci_upper.append(avg_data[col_idx])

        # Store data
        if target_name not in target_fuzzers:
            target_fuzzers[target_name] = {}
        target_fuzzers[target_name][fuzzer_name] = {
            'avg': avg_data,
            'ci_upper': ci_upper,
            'ci_lower': ci_lower,
            'time_points': time_points
        }

    # Generate comparison graphs for targets with multiple fuzzers
    comparison_count = 0
    for target_name in sorted(target_fuzzers.keys()):
        fuzzers_data = target_fuzzers[target_name]

        # Only create comparison if there are multiple fuzzers
        if len(fuzzers_data) <= 1:
            continue

        # Create figure
        fig, ax = plt.subplots(figsize=(12, 8))

        # Collect all values to determine Y-axis range
        all_values = []
        for fuzzer_name in sorted(fuzzers_data.keys()):
            data = fuzzers_data[fuzzer_name]
            all_values.extend(data['ci_upper'])
            all_values.extend(data['ci_lower'])

        # Plot each fuzzer's data in different colors
        colors = ['red', 'blue', 'green', 'orange', 'purple', 'brown', 'pink', 'gray']
        for idx, fuzzer_name in enumerate(sorted(fuzzers_data.keys())):
            data = fuzzers_data[fuzzer_name]
            avg_data = data['avg']
            ci_upper = data['ci_upper']
            ci_lower = data['ci_lower']
            time_points = data['time_points']

            color = colors[idx % len(colors)]

            # Fill the bootstrap 95% CI band with light color
            if not only_average:
                ax.fill_between(time_points, ci_lower, ci_upper, color=color, alpha=0.15)

            # Plot average line
            ax.plot(time_points, avg_data, color=color, linewidth=2, label=fuzzer_name, marker='o', markersize=2.5)

        # Set Y-axis range: fixed bottom margin, top margin scaled to max_val
        set_ylim_with_margin(ax, all_values)

        # Set X-axis range and scale
        if log_x:
            ax.set_xscale('log')
            ax.set_xlim(time_points[1] if time_points[0] == 0 else time_points[0], time_points[-1])
        else:
            ax.set_xlim(0, time_points[-1])
            ax.xaxis.set_major_locator(MaxNLocator(integer=True))

        # Set labels and title
        ax.set_xlabel('Time (hours)')
        ax.set_ylabel('Branch Hit Count')
        ax.set_title(f'{target_name} - Fuzzer Comparison')
        ax.grid(True, alpha=0.3)

        # Add legend
        ax.legend(loc='best')

        # Save figure
        output_filename = f"{target_name}_comparison.png"
        output_path = graph_dir / output_filename

        plt.tight_layout()
        plt.savefig(output_path, dpi=150, bbox_inches='tight')
        plt.close()

        print(f"✓ Created: {output_filename}")
        comparison_count += 1

    if comparison_count > 0:
        print(f"\n✓ Created {comparison_count} comparison graphs")


def plot_per_trial_comparison_graphs(graph_dir, data_dir, interval, log_x=False):
    """
    Generate per-trial comparison graphs.
    For each (target, trial_num) pair that exists in multiple fuzzers,
    plot each fuzzer's line for that specific trial on the same graph.

    Args:
        graph_dir: Path to graph directory (output location)
        data_dir: Path to data directory (input files)
        interval: Measurement interval in minutes
        log_x: Whether to use log scale on x-axis
    """
    graph_dir = Path(graph_dir)
    data_dir = Path(data_dir)

    if not data_dir.exists():
        return

    data_files = sorted(data_dir.glob('*_branch_count.txt'))
    if not data_files:
        return

    # target -> fuzzer -> campaign_num -> [values]
    all_data = {}

    for data_file in data_files:
        filename = data_file.stem.replace('_branch_count', '')
        parts = filename.split('_', 1)
        if len(parts) != 2:
            continue

        target_name, fuzzer_name = parts[0], parts[1]

        try:
            with open(data_file, 'r') as f:
                lines = f.readlines()
        except Exception:
            continue

        for line in lines:
            line_parts = line.strip().split()
            if not line_parts or line_parts[0] == 'avg':
                continue
            campaign_num = line_parts[0]
            values = [float(x) for x in line_parts[1:]]

            all_data.setdefault(target_name, {}).setdefault(fuzzer_name, {})[campaign_num] = values

    colors = ['red', 'blue', 'green', 'orange', 'purple', 'brown', 'pink', 'gray']
    trial_count = 0

    for target_name in sorted(all_data.keys()):
        fuzzers = all_data[target_name]

        # Collect all trial nums that appear in at least 2 fuzzers
        trial_to_fuzzers = {}
        for fuzzer_name, campaigns in fuzzers.items():
            for campaign_num in campaigns:
                trial_to_fuzzers.setdefault(campaign_num, []).append(fuzzer_name)

        for campaign_num, fuzzer_list in sorted(trial_to_fuzzers.items(), key=lambda x: int(x[0])):
            if len(fuzzer_list) < 2:
                continue

            fig, ax = plt.subplots(figsize=(12, 8))
            all_values = []

            for idx, fuzzer_name in enumerate(sorted(fuzzer_list)):
                values = fuzzers[fuzzer_name][campaign_num]
                num_points = len(values)
                time_points = [i * interval / 60 for i in range(num_points)]
                color = colors[idx % len(colors)]
                ax.plot(time_points, values, color=color, linewidth=2,
                        label=fuzzer_name, marker='o', markersize=2.5)
                all_values.extend(values)

            # Set Y-axis range: fixed bottom margin, top margin scaled to max_val
            set_ylim_with_margin(ax, all_values)

            if log_x:
                ax.set_xscale('log')
                ax.set_xlim(time_points[1] if time_points[0] == 0 else time_points[0], time_points[-1])
            else:
                ax.set_xlim(0, time_points[-1])
                ax.xaxis.set_major_locator(MaxNLocator(integer=True))

            ax.set_xlabel('Time (hours)')
            ax.set_ylabel('Branch Hit Count')
            ax.set_title(f'{target_name} - Trial {campaign_num} Comparison')
            ax.grid(True, alpha=0.3)
            ax.legend(loc='best')

            output_filename = f"{target_name}_trial{campaign_num}_comparison.png"
            output_path = graph_dir / output_filename

            plt.tight_layout()
            plt.savefig(output_path, dpi=150, bbox_inches='tight')
            plt.close()

            print(f"✓ Created: {output_filename}")
            trial_count += 1

    if trial_count > 0:
        print(f"\n✓ Created {trial_count} per-trial comparison graphs")


def main():
    parser = argparse.ArgumentParser(description='Generate branch coverage visualization graphs')
    parser.add_argument('workdir', help='Result directory path (_result directory)')
    parser.add_argument('--interval', type=int, required=True,
                        help='Measurement interval in minutes (e.g. 10)')
    parser.add_argument('--log-x', action='store_true',
                        help='Use log scale on the x-axis')
    parser.add_argument('--per-trial', action='store_true',
                        help='Generate per-trial comparison graphs (one graph per target+trial)')
    parser.add_argument('--median', action='store_true',
                        help='Use median instead of mean for the main line and CI band')
    parser.add_argument('--only-average', action='store_true',
                        help='Plot only the average/median line, without per-campaign lines, '
                             'confidence interval bands, or per-trial comparison graphs')

    args = parser.parse_args()
    workdir = Path(args.workdir).resolve()
    interval = args.interval
    log_x = args.log_x
    use_median = args.median
    only_average = args.only_average

    if not check_coverage_directory(workdir):
        sys.exit(1)

    graph_dir, data_dir = setup_output_directories(workdir)

    coverage_dir = workdir / 'coverage'
    print(f"\nCollecting branch hit count data...")
    data_summary, files_created = collect_and_save_branch_data(workdir, coverage_dir, data_dir, use_median)

    print(f"\n✓ Created {files_created} data files")
    if data_summary:
        print("\nData Summary:")
        for target in sorted(data_summary.keys()):
            print(f"  {target}:")
            for fuzzer, count in sorted(data_summary[target].items()):
                print(f"    - {fuzzer}: {count} campaigns")

    print(f"\nGenerating graphs...")
    plot_branch_graphs(graph_dir, data_dir, interval, log_x, use_median, only_average)

    print(f"\nGenerating comparison graphs...")
    plot_comparison_graphs(graph_dir, data_dir, interval, log_x, use_median, only_average)

    if args.per_trial and not only_average:
        print(f"\nGenerating per-trial comparison graphs...")
        plot_per_trial_comparison_graphs(graph_dir, data_dir, interval, log_x)

    print("\n✓ Graph generation complete!")


if __name__ == '__main__':
    main()
