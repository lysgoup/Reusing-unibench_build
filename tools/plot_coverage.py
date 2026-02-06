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
    import matplotlib.pyplot as plt
except ImportError:
    print("Error: matplotlib is required. Install with: pip install matplotlib")
    sys.exit(1)


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


def collect_and_save_branch_data(workdir, coverage_dir, data_dir):
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

                    # Calculate and write averages
                    # Find the minimum number of columns (only use columns where all campaigns have data)
                    if campaign_data:
                        min_columns = min(len(counts) for _, counts in campaign_data)

                        if min_columns > 0:
                            averages = []
                            for col_idx in range(min_columns):
                                col_values = [counts[col_idx] for _, counts in campaign_data]
                                if col_values:
                                    avg = sum(col_values) / len(col_values)
                                    averages.append(avg)

                            # Write average line
                            avg_line = "avg"
                            for avg in averages:
                                avg_line += f" {avg:.2f}"
                            f.write(avg_line + "\n")

                data_summary[target_name][fuzzer_name] = len(campaign_data)
                files_created += 1
                print(f"✓ Created: {output_filename} ({len(campaign_data)} campaigns)")

    return dict(data_summary), files_created


def plot_branch_graphs(graph_dir, data_dir):
    """
    Generate branch hit count graphs from data files.

    File format:
    campaign_num branch_count_t0 branch_count_t30 branch_count_t60 ...
    ...
    avg avg_t0 avg_t30 avg_t60 ...

    Each column represents 30 minutes (0, 30, 60, 90, ...).

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

    for data_file in data_files:
        # Extract target and fuzzer from filename
        # Format: {target}_{fuzzer}_branch_count.txt
        filename = data_file.stem.replace('_branch_count', '')
        parts = filename.rsplit('_', 1)

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

        # Generate time points (in minutes)
        time_points = [i * 30 for i in range(num_points)]

        # Create figure with larger height
        fig, ax = plt.subplots(figsize=(12, 8))

        # Collect all values to determine Y-axis range
        all_values = []
        for values in campaign_data.values():
            all_values.extend(values[:num_points])
        if avg_data:
            all_values.extend(avg_data)

        # Plot each campaign in blue
        for campaign_num in sorted(campaign_data.keys(), key=lambda x: int(x)):
            values = campaign_data[campaign_num]
            # Use only as many values as we have time points
            if len(values) >= num_points:
                ax.plot(time_points, values[:num_points], color='blue', alpha=0.3, linewidth=1.5, marker='o', markersize=2)

        # Plot average in red
        if avg_data:
            ax.plot(time_points, avg_data, color='red', linewidth=2, label='avg', marker='o', markersize=2.5)

        # Set Y-axis range based on data with 5% margin
        if all_values:
            min_val = min(all_values)
            max_val = max(all_values)
            margin = max((max_val - min_val) * 0.25, 50)
            if margin == 0:
                margin = max(10, min_val * 0.01)
            ax.set_ylim(min_val - margin, max_val + margin)

        # Set X-axis range to start exactly at 0
        ax.set_xlim(0, time_points[-1])

        # Set labels and title
        ax.set_xlabel('Time (minutes)')
        ax.set_ylabel('Branch Hit Count')
        ax.set_title(f'{target_name} - {fuzzer_name} - Branch Hit Count Progress')
        ax.grid(True, alpha=0.3)

        # Add legend
        blue_line = plt.Line2D([0], [0], color='blue', linewidth=1)
        red_line = plt.Line2D([0], [0], color='red', linewidth=2)
        ax.legend([blue_line, red_line], ['each campaign', 'avg'], loc='best')

        # Save figure
        output_filename = f"{target_name}_{fuzzer_name}_branch_graph.png"
        output_path = graph_dir / output_filename

        plt.tight_layout()
        plt.savefig(output_path, dpi=150, bbox_inches='tight')
        plt.close()

        print(f"✓ Created: {output_filename}")


def plot_comparison_graphs(graph_dir, data_dir):
    """
    Generate comparison graphs for targets with multiple fuzzers.
    Only shows avg lines from different fuzzers for the same target.

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

    # Group by target and collect fuzzer avg data
    target_fuzzers = {}  # {target: {fuzzer: (avg_data, time_points)}}

    for data_file in data_files:
        # Extract target and fuzzer from filename
        # Format: {target}_{fuzzer}_branch_count.txt
        filename = data_file.stem.replace('_branch_count', '')
        parts = filename.rsplit('_', 1)

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

        # Parse data to extract avg
        avg_data = None
        for line in lines:
            line_parts = line.strip().split()
            if not line_parts:
                continue

            label = line_parts[0]
            if label == 'avg':
                avg_data = [float(x) for x in line_parts[1:]]
                break

        if avg_data is None:
            continue

        # Generate time points (in minutes)
        num_points = len(avg_data)
        time_points = [i * 30 for i in range(num_points)]

        # Store data
        if target_name not in target_fuzzers:
            target_fuzzers[target_name] = {}
        target_fuzzers[target_name][fuzzer_name] = (avg_data, time_points)

    # Generate comparison graphs for targets with multiple fuzzers
    comparison_count = 0
    for target_name in sorted(target_fuzzers.keys()):
        fuzzers_data = target_fuzzers[target_name]

        # Only create comparison if there are multiple fuzzers
        if len(fuzzers_data) <= 1:
            continue

        # Create figure
        fig, ax = plt.subplots(figsize=(12, 8))

        # Collect all avg values to determine Y-axis range
        all_values = []
        for fuzzer_name in sorted(fuzzers_data.keys()):
            avg_data, _ = fuzzers_data[fuzzer_name]
            all_values.extend(avg_data)

        # Plot each fuzzer's avg in different colors
        colors = ['red', 'blue', 'green', 'orange', 'purple', 'brown', 'pink', 'gray']
        for idx, fuzzer_name in enumerate(sorted(fuzzers_data.keys())):
            avg_data, time_points = fuzzers_data[fuzzer_name]
            color = colors[idx % len(colors)]
            ax.plot(time_points, avg_data, color=color, linewidth=2, label=fuzzer_name, marker='o', markersize=2.5)

        # Set Y-axis range based on data with same method as individual graphs
        if all_values:
            min_val = min(all_values)
            max_val = max(all_values)
            margin = max((max_val - min_val) * 0.25, 50)
            if margin == 0:
                margin = max(10, min_val * 0.01)
            ax.set_ylim(min_val - margin, max_val + margin)

        # Set X-axis range to start exactly at 0
        ax.set_xlim(0, time_points[-1])

        # Set labels and title
        ax.set_xlabel('Time (minutes)')
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


def main():
    parser = argparse.ArgumentParser(description='Generate branch coverage visualization graphs')
    parser.add_argument('workdir', help='Result directory path (_result directory)')

    args = parser.parse_args()
    workdir = Path(args.workdir).resolve()

    if not check_coverage_directory(workdir):
        sys.exit(1)

    graph_dir, data_dir = setup_output_directories(workdir)

    coverage_dir = workdir / 'coverage'
    print(f"\nCollecting branch hit count data...")
    data_summary, files_created = collect_and_save_branch_data(workdir, coverage_dir, data_dir)

    print(f"\n✓ Created {files_created} data files")
    if data_summary:
        print("\nData Summary:")
        for target in sorted(data_summary.keys()):
            print(f"  {target}:")
            for fuzzer, count in sorted(data_summary[target].items()):
                print(f"    - {fuzzer}: {count} campaigns")

    print(f"\nGenerating graphs...")
    plot_branch_graphs(graph_dir, data_dir)

    print(f"\nGenerating comparison graphs...")
    plot_comparison_graphs(graph_dir, data_dir)
    print("\n✓ Graph generation complete!")


if __name__ == '__main__':
    main()
