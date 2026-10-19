#!/bin/bash

##
# Mirrors ../forkserver_libafl/run.sh, but passes -r: the taint pool a scan
# produced for this target ahead of the campaign (value_pool.dict,
# unsolved_condition and one .dtaint per seed). The reusing stage reads it;
# see LibAFL_reusing's fuzzers/reusing_core.
#
# Pre-requirements (set by entrypoint.sh):
# - env TARGET: target name (e.g., jq, exiv2)
# - env SEED:   seed directory path (inside container)
# - env SHARED: /unibench_shared (mounted from host)
# - env ARGS_STR: quoted target args string (e.g., ". @@")
##

set -e

FUZZER="/root/LibAFL-reusing/fuzzers/reusing_forkserver_cc/target/release/reusing_forkserver_cc"

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
    tiffsplit) TARGET_BINARY="/root/projects/targets/tiffsplit" ;;
    jhead)     TARGET_BINARY="/root/projects/targets/jhead" ;;
    lame)      TARGET_BINARY="/root/projects/targets/lame" ;;
    infotocap) TARGET_BINARY="/root/projects/targets/tic" ;;
    mujs)      TARGET_BINARY="/root/projects/targets/mujs" ;;
    mp42aac)   TARGET_BINARY="/root/projects/targets/mp42aac" ;;
    nm)        TARGET_BINARY="/root/projects/targets/nm" ;;
    objdump)   TARGET_BINARY="/root/projects/targets/objdump" ;;
    tcpdump)   TARGET_BINARY="/root/projects/targets/tcpdump" ;;
    ffmpeg)    TARGET_BINARY="/root/projects/targets/ffmpeg" ;;
    *)         echo "forkserver_libafl_reusing: Unknown target: $TARGET"; exit 1 ;;
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

# The taint pool, mounted read-only at /taint by start.sh from the captainrc's
# <target>_TAINT_DIR. tools/run.sh already refuses to launch a campaign for
# this fuzzer without one, so reaching here unset means someone bypassed that.
# Hard error rather than dropping -r: a campaign that quietly fuzzes without
# its pool is indistinguishable from a baseline afterwards.
if [ -z "$TAINT_DIR" ]; then
    echo "Error: TAINT_DIR environment variable is not set"
    echo "       Set <target>_TAINT_DIR in the captainrc (tools/run.sh validates it),"
    echo "       or pass TAINT_DIR=<host path> if invoking tools/start.sh directly."
    exit 1
fi

if [ ! -d "$TAINT_DIR" ]; then
    echo "Error: Taint pool dir not found at $TAINT_DIR"
    exit 1
fi

# Convert ARGS_STR to array
eval "TARGET_ARGS=($ARGS_STR)"

echo "[forkserver_libafl_reusing] Target:  $TARGET_BINARY"
echo "[forkserver_libafl_reusing] Seeds:   $SEED_DIR"
echo "[forkserver_libafl_reusing] Output:  $OUTPUT_DIR"
echo "[forkserver_libafl_reusing] Args:    ${TARGET_ARGS[*]}"
echo "[forkserver_libafl_reusing] Taint:   $TAINT_DIR"

# The reusing stage reports what it is doing (visits, execs, retired,
# no_taint) at info level every couple of hundred entries; without this the
# campaign leaves no trace that the stage ran beyond the pool-loaded banner.
# Everything else stays at error so the multilog is not drowned in libafl's
# own startup chatter.
export RUST_LOG=error,reusing_core=info

exec "$FUZZER" \
    -t 5000 \
    -o "$OUTPUT_DIR" \
    -r "$TAINT_DIR" \
    $FUZZARGS \
    "$TARGET_BINARY" \
    "$SEED_DIR" \
    -- \
    "${TARGET_ARGS[@]}"
