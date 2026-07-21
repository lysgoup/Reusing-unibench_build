#!/bin/bash -e

##
# One-shot coverage analysis for a finished fuzzing campaign
#
# Pre-requirements:
# + $1: FINDINGS_DIR - path to fuzzer findings directory (containing queue/)
# + $2: SEED_COUNT   - [optional] number of initial seed inputs. If omitted,
#                      it's auto-detected from the "total_executed:" value on
#                      the first line of FINDINGS_DIR/dryrun_log.txt.
# + $3: TARGET       - target program name (e.g., exiv2, mp3gain)
#
# Output:
#   $FINDINGS_DIR/coverage_analysis.txt
#     Line 1: branch count after running all seeds
#     Line 2+: ID of each fuzzer input that increased branch coverage
#
# ENV:
#   CPUSET - [optional] passed through as `docker run --cpuset-cpus`, e.g.
#            "51-60" or "51,53,55". Unset = unrestricted.
##

usage() {
    echo "Usage: $0 FINDINGS_DIR SEED_COUNT TARGET"
    echo "   or: $0 FINDINGS_DIR TARGET"
    echo "  FINDINGS_DIR: path to fuzzer findings directory (containing queue/)"
    echo "  SEED_COUNT:   number of initial seed inputs. If omitted, auto-detected"
    echo "                from 'total_executed:' on the first line of"
    echo "                FINDINGS_DIR/dryrun_log.txt"
    echo "  TARGET:       target program name (e.g., exiv2, mp3gain)"
}

SEED_COUNT_AUTO_DETECTED=0
if [ "$#" -eq 3 ]; then
    FINDINGS_DIR="$(realpath "$1")"
    SEED_COUNT="$2"
    TARGET="$3"
elif [ "$#" -eq 2 ]; then
    FINDINGS_DIR="$(realpath "$1")"
    TARGET="$2"
    SEED_COUNT_AUTO_DETECTED=1

    DRYRUN_LOG="$FINDINGS_DIR/dryrun_log.txt"
    if [ ! -f "$DRYRUN_LOG" ]; then
        echo "[ERROR] SEED_COUNT not given and $DRYRUN_LOG not found" >&2
        exit 1
    fi

    SEED_COUNT="$(awk -F': *' '/^total_executed:/ {print $2; exit}' "$DRYRUN_LOG")"
    if [ -z "$SEED_COUNT" ]; then
        echo "[ERROR] SEED_COUNT not given and 'total_executed:' not found in $DRYRUN_LOG" >&2
        exit 1
    fi
else
    usage
    exit 1
fi

UNIBENCH="${UNIBENCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)}"
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"

CONTAINER_NAME="analyze-cov-${TARGET}-$(date +%s%N)"

cleanup() {
    echo_time "Stopping container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT SIGINT SIGTERM

echo_time "Starting one-shot coverage analysis"
echo_time "Findings dir : $FINDINGS_DIR"
if [ "$SEED_COUNT_AUTO_DETECTED" -eq 1 ]; then
    echo_time "Seed count   : $SEED_COUNT (auto-detected from dryrun_log.txt)"
else
    echo_time "Seed count   : $SEED_COUNT"
fi
echo_time "Target       : $TARGET"

CPUSET_ARGS=()
if [ -n "${CPUSET:-}" ]; then
    echo_time "Cpuset       : $CPUSET"
    CPUSET_ARGS=(--cpuset-cpus="$CPUSET")
fi

docker run \
    --name="$CONTAINER_NAME" \
    "${CPUSET_ARGS[@]}" \
    --volume="$FINDINGS_DIR:/findings" \
    --volume="$VOLUME_PATH:/volume" \
    --env=TARGET="$TARGET" \
    --env=SEED_COUNT="$SEED_COUNT" \
    --env=TZ="Asia/Seoul" \
    --entrypoint=/volume/coverage/entrypoint_find_coverage_increasing_inputs.sh \
    "unifuzz/unibench:coverage" &

DOCKER_PID=$!
wait "$DOCKER_PID"

echo_time "Done. Results: $FINDINGS_DIR/coverage_analysis.txt"
