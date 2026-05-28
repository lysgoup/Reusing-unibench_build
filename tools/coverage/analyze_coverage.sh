#!/bin/bash -e

##
# One-shot coverage analysis for a finished fuzzing campaign
#
# Pre-requirements:
# + $1: FINDINGS_DIR - path to fuzzer findings directory (containing queue/)
# + $2: SEED_COUNT   - number of initial seed inputs
# + $3: TARGET       - target program name (e.g., exiv2, mp3gain)
#
# Output:
#   $FINDINGS_DIR/coverage_analysis.txt
#     Line 1: branch count after running all seeds
#     Line 2+: ID of each fuzzer input that increased branch coverage
##

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 FINDINGS_DIR SEED_COUNT TARGET"
    echo "  FINDINGS_DIR: path to fuzzer findings directory (containing queue/)"
    echo "  SEED_COUNT:   number of initial seed inputs"
    echo "  TARGET:       target program name (e.g., exiv2, mp3gain)"
    exit 1
fi

FINDINGS_DIR="$(realpath "$1")"
SEED_COUNT="$2"
TARGET="$3"

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
echo_time "Seed count   : $SEED_COUNT"
echo_time "Target       : $TARGET"

docker run \
    --name="$CONTAINER_NAME" \
    --volume="$FINDINGS_DIR:/findings" \
    --volume="$VOLUME_PATH:/volume" \
    --env=TARGET="$TARGET" \
    --env=SEED_COUNT="$SEED_COUNT" \
    --env=TZ="Asia/Seoul" \
    --entrypoint=/volume/coverage/entrypoint_analyze.sh \
    "unifuzz/unibench:coverage" &

DOCKER_PID=$!
wait "$DOCKER_PID"

echo_time "Done. Results: $FINDINGS_DIR/coverage_analysis.txt"
