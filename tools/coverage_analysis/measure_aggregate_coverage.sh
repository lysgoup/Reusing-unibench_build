#!/bin/bash -e

##
# Batch accumulated coverage analysis across all trials
#
# For each ar/{FUZZER}/{TARGET}/ under WORKDIR, collects all queue inputs
# from every trial and runs them to measure combined branch coverage.
# Results are written to ar/{FUZZER}/{TARGET}/coverage_all_trials.txt.
#
# Pre-requirements:
# + $1: WORKDIR - main experiment directory (contains ar/)
##

if [ -z "$1" ]; then
    echo "Usage: $0 WORKDIR"
    echo "  WORKDIR: main experiment directory (contains ar/)"
    exit 1
fi

WORKDIR="$(realpath "$1")"
ARDIR="$WORKDIR/ar"

if [ ! -d "$ARDIR" ]; then
    echo "[ERROR] ar/ directory not found under $WORKDIR"
    exit 1
fi

UNIBENCH="${UNIBENCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)}"
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"
COV_TIMEOUT="${COV_TIMEOUT:-5}"

TOTAL=0
SKIPPED=0
DONE=0
FAILED=0

CONTAINER_NAME=""

cleanup() {
    if [ -n "$CONTAINER_NAME" ]; then
        echo_time "Stopping container..."
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT SIGINT SIGTERM

for fuzzer_dir in "$ARDIR"/*/; do
    [ -d "$fuzzer_dir" ] || continue
    FUZZER=$(basename "$fuzzer_dir")

    for target_dir in "$fuzzer_dir"*/; do
        [ -d "$target_dir" ] || continue
        TARGET=$(basename "$target_dir")

        TOTAL=$((TOTAL + 1))
        OUTPUT_FILE="$target_dir/coverage_all_trials.txt"

        if [ -f "$OUTPUT_FILE" ]; then
            echo_time "[SKIP] Already done: $FUZZER/$TARGET"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Check at least one trial has a queue
        has_queue=0
        for trial_dir in "$target_dir"*/; do
            [ -d "$trial_dir/findings/queue" ] && { has_queue=1; break; }
        done

        if [ "$has_queue" -eq 0 ]; then
            echo_time "[SKIP] No queue found in any trial: $FUZZER/$TARGET"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        echo_time "[START] $FUZZER / $TARGET"

        CONTAINER_NAME="batch-cov-${FUZZER}-${TARGET}-$(date +%s%N)"

        docker run \
            --name="$CONTAINER_NAME" \
            --volume="$(realpath "$target_dir"):/target_dir" \
            --volume="$VOLUME_PATH:/volume" \
            --env=TARGET="$TARGET" \
            --env=COV_TIMEOUT="$COV_TIMEOUT" \
            --env=TZ="Asia/Seoul" \
            --entrypoint=/volume/coverage/entrypoint_measure_aggregate_coverage.sh \
            "unifuzz/unibench:coverage" &

        DOCKER_PID=$!
        if wait "$DOCKER_PID"; then
            echo_time "[DONE] $FUZZER / $TARGET"
            DONE=$((DONE + 1))
        else
            echo_time "[FAIL] $FUZZER / $TARGET"
            FAILED=$((FAILED + 1))
        fi
        CONTAINER_NAME=""
    done
done

echo_time "Batch analysis complete."
echo_time "Total: $TOTAL | Done: $DONE | Skipped: $SKIPPED | Failed: $FAILED"
