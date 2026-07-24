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
# Plain aflplusplus -- shares the exact same image/binary as ../aflplusplus-
# reusing (see tools/build.sh's "aflplusplus" case, which just re-tags the
# aflplusplus-reusing image instead of building anything separately), the
# same relationship angora has to angora-reusing: one build, runtime flags
# decide the behavior. The only difference from aflplusplus-reusing/run.sh
# is that AFL_DTAINT_BINARY is never set here, so taint tracking's
# save_if_interesting() hook (src/afl-fuzz-bitmap.c, AFLplusplus_reusing)
# never fires -- this runs as plain coverage-guided AFL++, no dtaint
# companion process at all.

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

# Same image as aflplusplus-reusing, so the fast binary lives at the same
# path -- only the dtaint/ binary (and AFL_DTAINT_BINARY) is deliberately
# not used here.
FAST_BIN="/d/p/aflplusplus-reusing/fast/${TARGET}"
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
afl-fuzz -i "$SEED" -o "$OUTPUT_DIR" -d $FUZZARGS -- "$FAST_BIN" "${ARGS[@]}" 2>&1
