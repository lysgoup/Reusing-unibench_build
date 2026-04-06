#!/bin/bash

##
# Pre-requirements:
# - env TARGET: target name (e.g., exiv2)
# - env SEED: path to seed directory
# - env SHARED: path to shared directory (to store results)
# - env ARGS: extra arguments to pass to the program
# - env FUZZARGS: extra arguments to pass to the fuzzer
##

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
# Binaries are expected in /unibench/{target}/fuzzer/{fast,track}
TARGET_BIN="/d/p/aflplusplus/${TARGET}"
OUTPUT_DIR="$SHARED/findings"

# Check if binaries exist
if [ ! -f "$TARGET_BIN" ]; then
    echo "Error: target binary not found at $TARGET_BIN"
    exit 1
fi

if [ ! -d "$SEED" ]; then
    echo "Error: Seed directory not found at $SEED"
    exit 1
fi

# Run aflplusplus
"/aflplusplus/afl-fuzz" -i "$SEED" -o "$OUTPUT_DIR" -d $FUZZARGS -- "$TARGET_BIN" $ARGS 2>&1

