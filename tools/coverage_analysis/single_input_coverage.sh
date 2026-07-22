#!/bin/bash -e

##
# Generate an HTML coverage report for a single input file.
#
# Pre-requirements:
# + $1: INPUT_FILE  - path to the input file to run
# + $2: TARGET      - target program name (e.g., jq, imginfo)
# + $3: OUTPUT_DIR  - directory where html/ report will be created
##

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 INPUT_FILE TARGET OUTPUT_DIR"
    echo "  INPUT_FILE: path to the single input file"
    echo "  TARGET:     target program name (e.g., jq, imginfo)"
    echo "  OUTPUT_DIR: directory to write the HTML report into"
    exit 1
fi

INPUT_FILE="$(realpath "$1")"
TARGET="$2"
OUTPUT_DIR="$(realpath "$3")"

if [ ! -f "$INPUT_FILE" ]; then
    echo "[ERROR] Input file not found: $INPUT_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

UNIBENCH="${UNIBENCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)}"
VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"
COV_TIMEOUT="${COV_TIMEOUT:-5}"

# Docker volume specs use ':' as separator, so file paths containing ':' (e.g. id:001789)
# must be copied to a colon-free temporary path before mounting.
TMP_INPUT=$(mktemp)
cp "$INPUT_FILE" "$TMP_INPUT"

CONTAINER_NAME="single-cov-${TARGET}-$(date +%s%N)"

cleanup() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    rm -f "$TMP_INPUT"
}
trap cleanup EXIT SIGINT SIGTERM

echo "[INFO] Input  : $INPUT_FILE"
echo "[INFO] Target : $TARGET"
echo "[INFO] Output : $OUTPUT_DIR/html"

docker run \
    --name="$CONTAINER_NAME" \
    --volume="$TMP_INPUT:/input:ro" \
    --volume="$OUTPUT_DIR:/report" \
    --volume="$VOLUME_PATH:/volume" \
    --env=TARGET="$TARGET" \
    --env=COV_TIMEOUT="$COV_TIMEOUT" \
    --entrypoint=/volume/coverage/entrypoint_single_coverage.sh \
    "unifuzz/unibench:coverage" &

wait $!

echo "[INFO] Done. Open: $OUTPUT_DIR/html/index.html"
