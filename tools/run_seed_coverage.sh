#!/bin/bash -e

##
# Run all inputs in a seed directory once and print branch coverage to stdout.
#
# Usage: $0 SEED_DIR TARGET
#   SEED_DIR: path to directory containing seed files (id:* format)
#   TARGET:   target program name (e.g., mp3gain, wav2swf)
##

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 SEED_DIR TARGET"
    echo "  SEED_DIR: path to directory containing seed files (id:* format)"
    echo "  TARGET:   target program name (e.g., mp3gain, wav2swf)"
    exit 1
fi

SEED_DIR="$(realpath "$1")"
TARGET="$2"

if [ ! -d "$SEED_DIR" ]; then
    echo "[ERROR] Seed directory not found: $SEED_DIR"
    exit 1
fi

UNIBENCH="${UNIBENCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)}"
VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"
COV_TIMEOUT="${COV_TIMEOUT:-5}"

CONTAINER_NAME="seed-cov-${TARGET}-$(date +%s%N)"

cleanup() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT SIGINT SIGTERM

echo "[INFO] Seed dir : $SEED_DIR"
echo "[INFO] Target   : $TARGET"
echo "[INFO] Seeds    : $(find "$SEED_DIR" -maxdepth 1 -name 'id:*' | wc -l) files"
echo ""

docker run \
    --name="$CONTAINER_NAME" \
    --volume="$SEED_DIR:/seeds:ro" \
    --volume="$VOLUME_PATH:/volume" \
    --env=TARGET="$TARGET" \
    --env=COV_TIMEOUT="$COV_TIMEOUT" \
    --env=TZ="Asia/Seoul" \
    --entrypoint=/volume/coverage/entrypoint_run_seed_coverage.sh \
    "unifuzz/unibench:coverage"
