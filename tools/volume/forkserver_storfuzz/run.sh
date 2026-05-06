#!/bin/bash

##
# Pre-requirements (set by entrypoint.sh):
# - env TARGET: target name (e.g., jq, exiv2)
# - env SEED:   seed directory path (inside container)
# - env SHARED: /unibench_shared (mounted from host)
# - env ARGS_STR: quoted target args string (e.g., ". @@")
##

set -e

FUZZER="/root/StorFuzz-LibAFL/fuzzers/forkserver_libafl_cc/target/release/forkserver_libafl_cc"

# Map TARGET name → binary path inside container
case "$TARGET" in
    exiv2)     TARGET_BINARY="/root/projects/targets/exiv2" ;;
    imginfo)   TARGET_BINARY="/root/projects/targets/imginfo" ;;
    mp3gain)   TARGET_BINARY="/root/projects/targets/mp3gain" ;;
    flvmeta)   TARGET_BINARY="/root/projects/targets/flvmeta" ;;
    cflow)     TARGET_BINARY="/root/projects/targets/cflow" ;;
    jq)        TARGET_BINARY="/root/projects/targets/jq" ;;
    pdftotext) TARGET_BINARY="/root/projects/targets/pdftotext" ;;
    sqlite3)   TARGET_BINARY="/root/projects/targets/sqlite3" ;;
    *)         echo "forkserver_storfuzz: Unknown target: $TARGET"; exit 1 ;;
esac

# Prefer $SEED if it's a non-empty directory (e.g., /customized_seed from captainrc),
# otherwise fall back to image-internal seeds
if [ -n "$SEED" ] && [ -d "$SEED" ] && [ -n "$(ls -A "$SEED" 2>/dev/null)" ]; then
    SEED_DIR="$SEED"
else
    SEED_DIR="/root/projects/seed_corpus/$TARGET"
fi

OUTPUT_DIR="$SHARED/findings"
mkdir -p "$OUTPUT_DIR"

# Validate
[ -f "$FUZZER" ]       || { echo "Fuzzer not found: $FUZZER"; exit 1; }
[ -f "$TARGET_BINARY" ] || { echo "Target binary not found: $TARGET_BINARY"; exit 1; }
[ -d "$SEED_DIR" ]      || { echo "Seed dir not found: $SEED_DIR"; exit 1; }

# Convert ARGS_STR to array
eval "TARGET_ARGS=($ARGS_STR)"

echo "[forkserver_storfuzz] Target:  $TARGET_BINARY"
echo "[forkserver_storfuzz] Seeds:   $SEED_DIR"
echo "[forkserver_storfuzz] Output:  $OUTPUT_DIR"
echo "[forkserver_storfuzz] Args:    ${TARGET_ARGS[*]}"

exec "$FUZZER" \
    -t 5000 \
    -o "$OUTPUT_DIR" \
    $FUZZARGS \
    "$TARGET_BINARY" \
    "$SEED_DIR" \
    "${TARGET_ARGS[@]}"
