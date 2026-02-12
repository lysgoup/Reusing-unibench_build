#!/bin/bash

##
# Coverage measurement entrypoint for running in container
# Monitors fuzzer output and executes coverage binary on new inputs
#
# Note: Mount structure:
# - Host: $CACHEDIR/$FUZZER/$TARGET/$CACHECID/ → Container: /unibench_shared/
# - Fuzzer creates: /unibench_shared/findings/queue/ (real-time output)
##

# Set umask to allow all permissions for created files
umask 0000

# Check if TARGET is set
if [ -z "$TARGET" ]; then
    echo "[ERROR] TARGET environment variable must be specified"
    exit 1
fi

# If running as root, switch to measurement user after initial setup
if [ "$(id -u)" -eq 0 ] && [ "$MEASURE_USER_ID" != "0" ]; then
    echo "[INFO] Running as root, will switch to user $MEASURE_USER_ID for measurements"
fi

# Find input directory (handles different fuzzer output structures)
# Try multiple possible locations
INPUT_DIR=""
if [ -d /unibench_shared/findings/queue ]; then
    INPUT_DIR="/unibench_shared/findings/queue"
elif [ -d /unibench_shared/findings/default/queue ]; then
    INPUT_DIR="/unibench_shared/findings/default/queue"
else
    echo "[ERROR] Input directory not found in expected locations:"
    echo "  - /unibench_shared/findings/queue (angora)"
    echo "  - /unibench_shared/findings/default/queue (aflplusplus)"
    exit 1
fi

echo "[INFO] Using input directory: $INPUT_DIR"

# Check if coverage output directory is empty
if [ -d /coverage_out ] && [ -n "$(ls -A /coverage_out 2>/dev/null)" ]; then
    echo "[ERROR] /coverage_out directory is not empty. Please clean it before starting."
    exit 1
fi

# Disable core dumps to avoid filling up disk
ulimit -c 0

# Find coverage binary for target
COVERAGE_BIN="/d/p/cov/${TARGET}"

if [ ! -f "$COVERAGE_BIN" ]; then
    echo "[ERROR] Coverage binary not found at $COVERAGE_BIN"
    echo "[INFO] Available binaries in /d/p/cov/:"
    ls -la /d/p/cov/ 2>/dev/null || echo "Directory not found"
    exit 1
fi

# Check if lcov is available (should be installed in Dockerfile)
if ! command -v lcov >/dev/null 2>&1; then
    echo "[ERROR] lcov not found - it should be installed in the Docker image"
    exit 1
fi

# Change to coverage output directory
cd /coverage_out

# Load target configuration from targets.conf
TARGETS_CONF="/volume/targets.conf"
if [ ! -f "$TARGETS_CONF" ]; then
    echo "[ERROR] targets.conf not found at $TARGETS_CONF"
    exit 1
fi

# Source the targets configuration
set -a
source "$TARGETS_CONF"
set +a

# Get target-specific arguments
target_args_var="${TARGET}_args[@]"
target_args=( "${!target_args_var}" )

# Check if target uses stdin redirection
target_stdin_var="${TARGET}_stdin_from_file"
target_stdin_from_file="${!target_stdin_var}"

# Get target source directory for lcov
target_source_var="${TARGET}_source_dir"
target_source_dir="${!target_source_var}"

echo "[INFO] Coverage measurement started for: $TARGET"
echo "[INFO] Coverage binary: $COVERAGE_BIN"
echo "[INFO] Input directory: $INPUT_DIR"
echo "[INFO] Output: /coverage_out"
echo "[INFO] Measurement interval: 30 minutes"
echo "[INFO] Target args: ${target_args[*]}"
if [ -n "$target_stdin_from_file" ]; then
    echo "[INFO] Input method: stdin from file"
fi

# Initialize start time for elapsed time calculation
COVERAGE_START_TIME=$(date +%s)
COVERAGE_LOG="/coverage_out/coverage.log"

# Run coverage measurement every 30 minutes
while true; do
    # Calculate elapsed time in minutes
    current_time=$(date +%s)
    elapsed=$((current_time - COVERAGE_START_TIME))
    elapsed_minutes=$((elapsed / 60))

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running coverage measurement..."

    # Check if coverage output directory is still accessible
    if [ ! -w /coverage_out ]; then
        echo "[ERROR] Coverage output directory /coverage_out is not accessible"
        exit 1
    fi

    # Process all inputs in queue directory
    if [ -d "$INPUT_DIR" ]; then
        INPUT_COUNT=0
        for input_file in "$INPUT_DIR"/*; do
            [ -f "$input_file" ] || continue

            INPUT_COUNT=$((INPUT_COUNT + 1))

            # Build command arguments, replacing @@ with input file path
            cmd_args=()
            for arg in "${target_args[@]}"; do
                if [ "$arg" = "@@" ]; then
                    cmd_args+=("$input_file")
                else
                    cmd_args+=("$arg")
                fi
            done

            # Execute coverage binary on input
            # Suppress errors as some inputs may cause crashes
            if [ -n "$target_stdin_from_file" ]; then
                # Use stdin redirection
                timeout 5 "$COVERAGE_BIN" "${cmd_args[@]}" < "$input_file" >/dev/null 2>&1 || true
            else
                # Use command line arguments
                timeout 5 "$COVERAGE_BIN" "${cmd_args[@]}" >/dev/null 2>&1 || true
            fi
        done
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processed $INPUT_COUNT inputs"
    else
        echo "[ERROR] Input directory not found: $INPUT_DIR"
        exit 1
    fi

    # Generate coverage report if lcov is available
    if command -v lcov >/dev/null 2>&1; then
        # Capture coverage data including branch coverage
        if lcov --capture --directory "$target_source_dir" --output-file coverage.info \
                --rc lcov_branch_coverage=1 >/dev/null 2>&1; then
            # Generate HTML report with branch coverage
            if genhtml coverage.info --output-directory html \
                    --rc genhtml_branch_coverage=1 > genhtml.tmp 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Coverage report generated successfully"

                # Extract last 3 lines (coverage summary) and log with elapsed time
                tail -3 genhtml.tmp | while read line; do
                    echo "[${elapsed_minutes}m] $line" >> "$COVERAGE_LOG"
                done
            fi
        fi
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting 30 minutes until next measurement..."
    sleep 1800  # 30 minutes
done
