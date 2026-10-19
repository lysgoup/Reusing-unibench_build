#!/bin/bash

##
# Mirrors ../forkserver_libafl/run.sh, but passes -c: the same target built a
# second time with AFL++'s cmplog instrumentation (AFL_LLVM_CMPLOG=1). The
# fuzzer's colorization/tracing/RedQueen stages read it; see LibAFL_reusing's
# fuzzers/cmplog_forkserver_cc.
#
# Pre-requirements (set by entrypoint.sh):
# - env TARGET: target name (e.g., jq, cflow)
# - env SEED:   seed directory path (inside container)
# - env SHARED: /unibench_shared (mounted from host)
# - env ARGS_STR: quoted target args string (e.g., ". @@")
##

set -e

FUZZER="/root/LibAFL-reusing/fuzzers/cmplog_forkserver_cc/target/release/cmplog_forkserver_cc"

# Map TARGET name → binary path inside container. The main binary is the same
# libafl_cc build every LibAFL arm runs; cmplog/ holds the AFL++ cmplog build.
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
    *)         echo "forkserver_libafl_cmplog: Unknown target: $TARGET"; exit 1 ;;
esac

CMPLOG_BINARY="/root/projects/targets/cmplog/${TARGET##*/}"
# infotocap's main binary is tic; keep the cmplog name in step with the case above
[ "$TARGET" = "infotocap" ] && CMPLOG_BINARY="/root/projects/targets/cmplog/tic"

# Prefer $SEED if it's a non-empty directory (e.g., /customized_seed from captainrc),
# otherwise fall back to image-internal seeds
if [ -n "$SEED" ] && [ -d "$SEED" ] && [ -n "$(ls -A "$SEED" 2>/dev/null)" ]; then
    SEED_DIR="$SEED"
else
    SEED_DIR="/root/projects/seed_corpus/$TARGET"
fi

OUTPUT_DIR="$SHARED/findings"
mkdir -p "$OUTPUT_DIR"

# Validate. The cmplog binary is a hard error, not a fallback to the baseline:
# a campaign that quietly fuzzes without its cmplog arm is indistinguishable
# from the baseline afterwards -- same reasoning as the reusing arm's -r.
[ -f "$FUZZER" ]        || { echo "Fuzzer not found: $FUZZER"; exit 1; }
[ -f "$TARGET_BINARY" ] || { echo "Target binary not found: $TARGET_BINARY"; exit 1; }
[ -f "$CMPLOG_BINARY" ] || { echo "Cmplog binary not found: $CMPLOG_BINARY (this image only builds cmplog for the campaign's targets; add a block to forkserver_libafl_cmplog-target/Dockerfile)"; exit 1; }
[ -d "$SEED_DIR" ]      || { echo "Seed dir not found: $SEED_DIR"; exit 1; }

# Convert ARGS_STR to array
eval "TARGET_ARGS=($ARGS_STR)"

echo "[forkserver_libafl_cmplog] Target:  $TARGET_BINARY"
echo "[forkserver_libafl_cmplog] Cmplog:  $CMPLOG_BINARY"
echo "[forkserver_libafl_cmplog] Seeds:   $SEED_DIR"
echo "[forkserver_libafl_cmplog] Output:  $OUTPUT_DIR"
echo "[forkserver_libafl_cmplog] Args:    ${TARGET_ARGS[*]}"

exec "$FUZZER" \
    -t 5000 \
    -o "$OUTPUT_DIR" \
    -c "$CMPLOG_BINARY" \
    $FUZZARGS \
    "$TARGET_BINARY" \
    "$SEED_DIR" \
    -- \
    "${TARGET_ARGS[@]}"
