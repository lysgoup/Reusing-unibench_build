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

ARCHIVES_DIR="/coverage_out/archives"

if [ ! -d "$ARCHIVES_DIR" ]; then
    echo "[ERROR] Archives directory not found: $ARCHIVES_DIR"
    exit 1
fi

echo "[INFO] Using archives directory: $ARCHIVES_DIR"

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

# Get target-specific arguments (convert hyphens to underscores for variable lookup)
TARGET_NORMALIZED="${TARGET//-/_}"
target_args_var="${TARGET_NORMALIZED}_args[@]"

# Check if target uses stdin redirection
target_stdin_var="${TARGET_NORMALIZED}_stdin_from_file"
target_stdin_from_file="${!target_stdin_var}"

# If args are empty, check if stdin is used
if [ -z "${!target_args_var}" ] && [ "$target_stdin_from_file" != "1" ]; then
    echo "[ERROR] No args found for target '$TARGET' in targets.conf, and stdin_from_file is not set"
    exit 1
fi

target_args=( "${!target_args_var}" )

# Get target source directory for lcov
target_source_var="${TARGET_NORMALIZED}_source_dir"
target_source_dir="${!target_source_var}"

# Measurement interval in seconds (modify here to change interval)
MEASUREMENT_INTERVAL=${MEASUREMENT_INTERVAL:-900}

echo "[INFO] Coverage measurement started for: $TARGET"
echo "[INFO] Coverage binary: $COVERAGE_BIN"
echo "[INFO] Input directory: $INPUT_DIR"
echo "[INFO] Output: /coverage_out"
echo "[INFO] Measurement interval: $((MEASUREMENT_INTERVAL / 60)) minutes ($MEASUREMENT_INTERVAL seconds)"
if [ -n "$MAX_ITERATIONS" ]; then
    echo "[INFO] Max iterations: $MAX_ITERATIONS (dryrun wait excluded)"
fi
echo "[INFO] Target args: ${target_args[*]}"
if [ -n "$target_stdin_from_file" ]; then
    echo "[INFO] Input method: stdin from file"
fi

COVERAGE_LOG="/coverage_out/coverage.log"

# Wait for first archive to appear
echo "[INFO] Waiting for first archive in $ARCHIVES_DIR..."
while [ ! -f "$ARCHIVES_DIR/iter_0000.tar.gz" ]; do
    sleep 3
done
echo "[INFO] First archive detected, starting coverage measurement loop"

run_input() {
    local input_file="$1"
    local tmp
    tmp=$(mktemp)
    cp "$input_file" "$tmp"

    local cmd_args=()
    for arg in "${target_args[@]}"; do
        [ "$arg" = "@@" ] && cmd_args+=("$tmp") || cmd_args+=("$arg")
    done

    if [ -n "$target_stdin_from_file" ]; then
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" < "$tmp" >/dev/null 2>&1 || true
    else
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" >/dev/null 2>&1 || true
    fi
    rm -f "$tmp"
}

ITERATION=0
recent_coverage=""
saturation_count=0

while true; do
    ARCHIVE_PATH="$ARCHIVES_DIR/$(printf 'iter_%04d.tar.gz' $ITERATION)"

    # Wait for this iteration's archive
    while [ ! -f "$ARCHIVE_PATH" ]; do
        sleep 3
    done

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing archive: $ARCHIVE_PATH"

    # Reset gcov counters (each archive is a full snapshot)
    lcov --zerocounters --directory "$target_source_dir" -q 2>/dev/null || true

    INPUT_COUNT=0
    if [ -s "$ARCHIVE_PATH" ]; then
        EXTRACT_DIR=$(mktemp -d)
        if ! tar xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" 2>/tmp/tar_extract_err; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: tar extraction failed: $(cat /tmp/tar_extract_err)"
        fi
        EXTRACTED_QUEUE_COUNT=$(find "$EXTRACT_DIR" -path "*/findings/queue/id:*" -type f 2>/dev/null | wc -l)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Extracted $EXTRACTED_QUEUE_COUNT queue files from archive"

        while IFS= read -r input_file; do
            INPUT_COUNT=$((INPUT_COUNT + 1))
            run_input "$input_file"
        done < <(find "$EXTRACT_DIR" -path "*/findings/queue/id:*" -type f 2>/dev/null)

        rm -rf "$EXTRACT_DIR"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Empty archive, skipping"
    fi

    # Generate coverage report
    if lcov --capture --directory "$target_source_dir" --output-file coverage.info \
            --rc lcov_branch_coverage=1 >/dev/null 2>&1; then
        if genhtml coverage.info --output-directory html \
                --rc genhtml_branch_coverage=1 > genhtml.tmp 2>&1; then
            branch_coverage=$(grep "branches" genhtml.tmp | grep -oP '\d+(?= of)' | head -1)
            if [ -n "$branch_coverage" ]; then
                if [ -z "$MIN_ITERATIONS" ] || [ "$ITERATION" -gt "$MIN_ITERATIONS" ]; then
                    if [ "$branch_coverage" = "$recent_coverage" ]; then
                        saturation_count=$((saturation_count + 1))
                    else
                        saturation_count=0
                    fi
                fi
                recent_coverage="$branch_coverage"
            fi
            if [ -n "$MIN_ITERATIONS" ] && [ "$ITERATION" -le "$MIN_ITERATIONS" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processed $INPUT_COUNT inputs | iter: $ITERATION/$MIN_ITERATIONS (min) | branch coverage: ${branch_coverage:-N/A} | saturation: (pending)"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processed $INPUT_COUNT inputs | iter: $ITERATION | branch coverage: ${branch_coverage:-N/A} | saturation: $saturation_count${SATURATION_WINDOW:+/$SATURATION_WINDOW}"
            fi
            tail -3 genhtml.tmp | while IFS= read -r line; do
                echo "[iter_$ITERATION] $line" >> "$COVERAGE_LOG"
            done
        fi
    fi

    ITERATION=$((ITERATION + 1))

    # Check saturation
    if [ -n "$SATURATION_WINDOW" ] && [ "$saturation_count" -ge "$SATURATION_WINDOW" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Saturation reached ($saturation_count/$SATURATION_WINDOW). Exiting."
        touch /coverage_out/saturation_done
        exit 0
    fi

    # Check iteration limit
    if [ -n "$MAX_ITERATIONS" ] && [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reached max iterations ($MAX_ITERATIONS). Exiting."
        exit 0
    fi

    rm -f "$ARCHIVE_PATH"
done
