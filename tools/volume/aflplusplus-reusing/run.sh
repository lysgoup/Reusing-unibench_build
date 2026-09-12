#!/bin/bash

##
# Pre-requirements:
# - env TARGET: target name (e.g., tiffsplit)
# - env SEED: path to seed directory
# - env SHARED: path to shared directory (to store results)
# - env ARGS: extra arguments to pass to the program
# - env FUZZARGS: extra arguments to pass to the fuzzer
##
#
# Mirrors ../aflplusplus/run.sh, but passes -r: the taint pool that
# afl-taint-scan produced for this target ahead of the campaign
# (value_pool.dict, unsolved_condition and one .dtaint per seed). afl-fuzz
# reads it in its reusing stage; see src/afl-fuzz-reusing.c. Trimming is off
# for the whole run, forced by -r, since it would rewrite a queue entry and
# leave every offset in its .dtaint pointing at the wrong byte.
#
# The real-DFSan companion binary is still checked for below: it is what
# produced the pool, and the in-process analysis that will replace the
# pre-pass needs it here. See instrumentation/README.dtaint.md /
# dfsan_legacy/README.md for what it captures.

# Validate required environment variables
if [ -z "$TARGET" ]; then
    echo "Error: TARGET environment variable is not set"
    exit 1
fi

if [ -z "$SHARED" ]; then
    echo "Error: SHARED environment variable is not set"
    exit 1
fi

if [ -z "$SEED" ]; then
    echo "Error: SEED environment variable is not set"
    exit 1
fi

if [ -z "$ARGS_STR" ]; then
    echo "Warning: ARGS_STR not set, using empty arguments"
    ARGS_STR=""
fi

# afl-fuzz -r's value: this target's taint pool (afl-taint-scan's
# value_pool.dict / unsolved_condition cache), mounted read-only at /taint by
# start.sh from the captainrc's <target>_TAINT_DIR. tools/run.sh already
# refuses to launch a campaign for this fuzzer without one, so reaching here
# unset means someone bypassed that -- a direct start.sh or docker run. Hard
# error either way rather than dropping -r, since a campaign that quietly
# fuzzes without its pool is indistinguishable from a baseline afterwards.
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

# Disable CPU binding for better compatibility
export AFL_SKIP_CPUFREQ=1
export AFL_NO_AFFINITY=1
export AFL_NO_UI=1
export AFL_MAP_SIZE=256000
export AFL_DRIVER_DONT_DEFER=1

# Convert ARGS_STR back to array
eval "ARGS=($ARGS_STR)"

# Determine binary paths based on TARGET
FAST_BIN="/d/p/aflplusplus-reusing/fast/${TARGET}"
DTAINT_BIN="/d/p/aflplusplus-reusing/dtaint/${TARGET}"
OUTPUT_DIR="$SHARED/findings"

if [ ! -f "$FAST_BIN" ]; then
    echo "Error: Fast (main) binary not found at $FAST_BIN"
    exit 1
fi

if [ ! -f "$DTAINT_BIN" ]; then
    echo "Error: Dtaint (real-DFSan) binary not found at $DTAINT_BIN"
    exit 1
fi

if [ ! -d "$SEED" ]; then
    echo "Error: Seed directory not found at $SEED"
    exit 1
fi

# cmpid -> source-location table (see aflplusplus-reusing-target/Dockerfile's
# ANGORA_OUTPUT_COND_LOC=1 step and parse_cond_loc.py), built alongside
# $DTAINT_BIN and otherwise stuck inside the image -- copy it into the
# campaign's own findings dir so a .dtaint record's cmpid can be looked up
# after the fact, from the host, without a shell into the container. Only
# present for images rebuilt after that Dockerfile change; best-effort so an
# older image doesn't fail the run over it.
CMPID_LOCS="/d/p/aflplusplus-reusing/dtaint/${TARGET}.cmpid_log.txt"
mkdir -p "$OUTPUT_DIR"
if [ -f "$CMPID_LOCS" ]; then
    cp "$CMPID_LOCS" "$OUTPUT_DIR/cmpid_log.txt"
else
    echo "Warning: cmpid_log.txt not found for $TARGET at $CMPID_LOCS (image built before ANGORA_OUTPUT_COND_LOC logging was added?)"
fi

# Run aflplusplus. Unlike ../aflplusplus/run.sh's hardcoded /aflplusplus/afl-fuzz
# (that image's own AFL++ checkout lives at that lowercase path), this fork's
# Dockerfile (AFLplusplus_reusing) keeps the source tree at /AFLplusplus and
# `make install`s it, so afl-fuzz is simply on PATH -- use that instead of
# guessing the source-tree casing.
echo "Taint pool (-r): $TAINT_DIR"
afl-fuzz -i "$SEED" -o "$OUTPUT_DIR" -r "$TAINT_DIR" $FUZZARGS -- "$FAST_BIN" "${ARGS[@]}" 2>&1
