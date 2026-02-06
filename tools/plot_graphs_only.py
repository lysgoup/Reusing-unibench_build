#!/usr/bin/env python3
"""
Graph visualization script - Plots graphs from pre-processed data files
This script assumes data files already exist in graph/data/ directory
"""

import os
import sys
from pathlib import Path
import argparse

try:
    import matplotlib.pyplot as plt
except ImportError:
    print("Error: matplotlib is required. Install with: pip install matplotlib")
    sys.exit(1)


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
    parser = argparse.ArgumentParser(
        description='Generate branch coverage visualization graphs from pre-processed data files'
    )
    parser.add_argument(
        'workdir',
        help='Result directory path (_result directory) or data directory path (graph/data directory)'
    )
    parser.add_argument(
        '--data-dir',
        help='Path to data directory (optional, defaults to workdir/graph/data)'
    )

    args = parser.parse_args()
    workdir = Path(args.workdir).resolve()

    # Determine data_dir and graph_dir
    if args.data_dir:
        data_dir = Path(args.data_dir).resolve()
        graph_dir = data_dir.parent  # Assume data_dir is graph/data, so parent is graph
    elif workdir.name == 'data' and workdir.parent.name == 'graph':
        # If workdir is already the data directory
        data_dir = workdir
        graph_dir = workdir.parent
    else:
        # Assume workdir is _result directory
        data_dir = workdir / 'graph' / 'data'
        graph_dir = workdir / 'graph'

    if not data_dir.exists():
        print(f"Error: Data directory not found: {data_dir}")
        sys.exit(1)

    # Ensure graph directory exists
    graph_dir.mkdir(parents=True, exist_ok=True)

    print(f"✓ Reading data from: {data_dir}")
    print(f"✓ Writing graphs to: {graph_dir}")

    print(f"\nGenerating graphs...")
    plot_branch_graphs(graph_dir, data_dir)

    print(f"\nGenerating comparison graphs...")
    plot_comparison_graphs(graph_dir, data_dir)

    print("\n✓ Graph generation complete!")


if __name__ == '__main__':
    main()
