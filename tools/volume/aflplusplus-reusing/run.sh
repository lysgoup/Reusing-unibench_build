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
# Mirrors ../aflplusplus/run.sh, but additionally points AFL_DTAINT_BINARY
# at the real-DFSan companion binary (dfsan_legacy/angora_dfsan_clang.sh's
# output, built into /d/p/aflplusplus-reusing/dtaint/ by
# aflplusplus-reusing-target/Dockerfile) -- this is what turns on taint
# tracking, mirroring how ../angora-reusing/run.sh passes -t "$TRACK_BIN".
# See src/afl-fuzz-bitmap.c's save_if_interesting() in AFLplusplus_reusing
# for exactly when this fires (once per newly discovered queue entry, not
# every execution) and instrumentation/README.dtaint.md /
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

# This is the switch that turns taint tracking on -- see save_if_interesting()
# in src/afl-fuzz-bitmap.c (AFLplusplus_reusing).
export AFL_DTAINT_BINARY="$DTAINT_BIN"

# Run aflplusplus. Unlike ../aflplusplus/run.sh's hardcoded /aflplusplus/afl-fuzz
# (that image's own AFL++ checkout lives at that lowercase path), this fork's
# Dockerfile (AFLplusplus_reusing) keeps the source tree at /AFLplusplus and
# `make install`s it, so afl-fuzz is simply on PATH -- use that instead of
# guessing the source-tree casing.
afl-fuzz -i "$SEED" -o "$OUTPUT_DIR" -d $FUZZARGS -- "$FAST_BIN" "${ARGS[@]}" 2>&1
