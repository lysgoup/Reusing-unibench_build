#!/bin/bash

##
# Pre-requirements:
# - env TARGET: target name (only exiv2/mp3gain/mujs are built -- see
#   ../../aflplusplus-cmplog/Dockerfile)
# - env SEED: path to seed directory
# - env SHARED: path to shared directory (to store results)
# - env ARGS: extra arguments to pass to the program
# - env FUZZARGS: extra arguments to pass to the fuzzer
##
#
# Same image family as ../aflplusplus/run.sh (own AFL++ checkout, same
# patches), but built with a second, cmplog-instrumented binary per target
# (see the Dockerfile) and pointed at it via afl-fuzz's `-c`. Auto-extras
# OFF is baked in here too, same as ../aflplusplus/run.sh -- this fuzzer
# name is "cmplog ON, auto-extras OFF", not a toggle of either
# independently.

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

# Trimming, from the captainrc's DISABLE_TRIM (see tools/run.sh). Turn it on to
# stay comparable with aflplusplus-reusing, which cannot trim at all: trimming
# rewrites a queue entry and every offset in its .dtaint would then point at the
# wrong byte.
if [ "${DISABLE_TRIM:-0}" = 1 ]; then
    export AFL_DISABLE_TRIM=1
fi

# Auto-extras OFF -- baked in for this fuzzer name (see header note).
export AFL_NO_AUTO_EXTRAS=1

# Convert ARGS_STR back to array
eval "ARGS=($ARGS_STR)"

FAST_BIN="/d/p/aflplusplus-cmplog/${TARGET}"
CMPLOG_BIN="/d/p/aflplusplus-cmplog/cmplog/${TARGET}"
OUTPUT_DIR="$SHARED/findings"

if [ ! -f "$FAST_BIN" ]; then
    echo "Error: Fast (main) binary not found at $FAST_BIN"
    exit 1
fi

if [ ! -f "$CMPLOG_BIN" ]; then
    echo "Error: cmplog binary not found at $CMPLOG_BIN"
    exit 1
fi

if [ ! -d "$SEED" ]; then
    echo "Error: Seed directory not found at $SEED"
    exit 1
fi

# -c points afl-fuzz at the cmplog-instrumented companion binary; the main
# binary after -- stays the normal one, same as ../aflplusplus/run.sh.
afl-fuzz -i "$SEED" -o "$OUTPUT_DIR" -c "$CMPLOG_BIN" $FUZZARGS -- "$FAST_BIN" "${ARGS[@]}" 2>&1
