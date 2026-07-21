#!/bin/bash

##
# Accumulated coverage analysis across all trials (runs inside coverage container)
#
# Mount structure:
#   Host ar/{FUZZER}/{TARGET}/  → /target_dir  (trial subdirs live here; output written here)
#   Host tools/volume/          → /volume       (targets.conf, etc.)
#
# ENV:
#   TARGET - target program name
##

umask 0000
ulimit -c 0

if [ -z "${TARGET:-}" ]; then
    echo "[ERROR] TARGET environment variable must be set"
    exit 1
fi

COVERAGE_BIN="/d/p/cov/${TARGET}"
if [ ! -f "$COVERAGE_BIN" ]; then
    echo "[ERROR] Coverage binary not found: $COVERAGE_BIN"
    ls -la /d/p/cov/ 2>/dev/null || echo "  (directory not found)"
    exit 1
fi

if ! command -v lcov >/dev/null 2>&1; then
    echo "[ERROR] lcov not found in container"
    exit 1
fi

TARGETS_CONF="/volume/targets.conf"
if [ ! -f "$TARGETS_CONF" ]; then
    echo "[ERROR] targets.conf not found at $TARGETS_CONF"
    exit 1
fi
set -a
source "$TARGETS_CONF"
set +a

TARGET_NORMALIZED="${TARGET//-/_}"
target_args_var="${TARGET_NORMALIZED}_args[@]"
target_stdin_var="${TARGET_NORMALIZED}_stdin_from_file"
target_stdin_from_file="${!target_stdin_var:-}"
target_args=("${!target_args_var}")
target_source_var="${TARGET_NORMALIZED}_source_dir"
target_source_dir="${!target_source_var}"

if [ -z "${target_source_dir:-}" ]; then
    echo "[ERROR] No source_dir found for target '$TARGET' in targets.conf"
    exit 1
fi

OUTPUT_FILE="/target_dir/coverage_all_trials.txt"

echo "[INFO] Target      : $TARGET"
echo "[INFO] Source dir  : $target_source_dir"
echo "[INFO] Output      : $OUTPUT_FILE"

# --- Helper: run one input through coverage binary ---
run_input() {
    local f="$1"
    local tmp
    tmp=$(mktemp)
    cp "$f" "$tmp"

    local cmd_args=()
    for arg in "${target_args[@]}"; do
        [ "$arg" = "@@" ] && cmd_args+=("$tmp") || cmd_args+=("$arg")
    done

    if [ -n "$target_stdin_from_file" ]; then
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" < "$tmp" >/dev/null 2>&1 &
    else
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" >/dev/null 2>&1 &
    fi
    wait $! 2>/dev/null || true

    rm -f "$tmp"
}

# --- Reset gcov counters ---
echo "[INFO] Resetting gcov counters..."
lcov --zerocounters --directory "$target_source_dir" -q 2>/dev/null || true

# --- Collect and run all queue inputs from all trials ---
TOTAL_INPUTS=0

for trial_dir in /target_dir/*/; do
    [ -d "$trial_dir" ] || continue
    TRIAL=$(basename "$trial_dir")

    # Support both angora and aflplusplus queue layouts
    if [ -d "$trial_dir/findings/queue" ]; then
        QUEUE_DIR="$trial_dir/findings/queue"
    elif [ -d "$trial_dir/findings/default/queue" ]; then
        QUEUE_DIR="$trial_dir/findings/default/queue"
    else
        echo "[INFO] No queue found for trial $TRIAL, skipping"
        continue
    fi

    mapfile -t INPUTS < <(
        find "$QUEUE_DIR" -maxdepth 1 -name 'id:*' -printf '%f\n' 2>/dev/null | sort | \
        while IFS= read -r fname; do echo "$QUEUE_DIR/$fname"; done
    )

    echo "[INFO] Trial $TRIAL: ${#INPUTS[@]} inputs"

    for input_file in "${INPUTS[@]}"; do
        printf "\r[running] trial:%-3s  id:%s" "$TRIAL" "$(basename "$input_file")"
        run_input "$input_file"
        TOTAL_INPUTS=$((TOTAL_INPUTS + 1))
    done
done

printf "\n"
echo "[INFO] Total inputs executed: $TOTAL_INPUTS"

# --- Measure accumulated coverage ---
echo "[INFO] Measuring accumulated coverage..."

INFO_FILE="/target_dir/coverage.info"

if lcov --capture \
        --directory "$target_source_dir" \
        --output-file "$INFO_FILE" \
        --rc lcov_branch_coverage=1 \
        -q 2>/dev/null; then
    SUMMARY=$(lcov --summary "$INFO_FILE" --rc lcov_branch_coverage=1 2>&1)
    BRANCH_HIT=$(echo "$SUMMARY" | grep -oP '\d+(?= of \d+ branch)' | head -1)
    BRANCH_TOTAL=$(echo "$SUMMARY" | grep -oP '(?<=of )\d+(?= branch)' | head -1)
    LINE_HIT=$(echo "$SUMMARY" | grep -oP '\d+(?= of \d+ line)' | head -1)
    LINE_TOTAL=$(echo "$SUMMARY" | grep -oP '(?<=of )\d+(?= line)' | head -1)

    echo "[INFO] Branch coverage : ${BRANCH_HIT:-0} / ${BRANCH_TOTAL:-0}"
    echo "[INFO] Line coverage   : ${LINE_HIT:-0} / ${LINE_TOTAL:-0}"

    {
        echo "branch_hit:   ${BRANCH_HIT:-0}"
        echo "branch_total: ${BRANCH_TOTAL:-0}"
        echo "line_hit:     ${LINE_HIT:-0}"
        echo "line_total:   ${LINE_TOTAL:-0}"
        echo "total_inputs: $TOTAL_INPUTS"
    } > "$OUTPUT_FILE"
else
    echo "[ERROR] lcov capture failed"
    exit 1
fi

echo "[INFO] Done. Results: $OUTPUT_FILE"
echo "[INFO] Info file   : $INFO_FILE"
