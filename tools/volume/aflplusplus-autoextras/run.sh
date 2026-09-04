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
# Same image/binary as ../aflplusplus/run.sh (see build.sh -- this fuzzer
# name shares that build, tagged separately) and identical in every way
# EXCEPT one: no AFL_NO_AUTO_EXTRAS export here, so AFL++'s own default
# (auto-detected dictionary tokens / a_extras ON) applies. That's the sole
# reason this file exists instead of a runtime toggle.

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

FAST_BIN="/d/p/aflplusplus/${TARGET}"
OUTPUT_DIR="$SHARED/findings"

if [ ! -f "$FAST_BIN" ]; then
    echo "Error: Fast (main) binary not found at $FAST_BIN"
    exit 1
fi

if [ ! -d "$SEED" ]; then
    echo "Error: Seed directory not found at $SEED"
    exit 1
fi

# Run aflplusplus -- no AFL_DTAINT_BINARY set, so taint tracking stays off.
afl-fuzz -i "$SEED" -o "$OUTPUT_DIR" $FUZZARGS -- "$FAST_BIN" "${ARGS[@]}" 2>&1
