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
export ANGORA_DISABLE_CPU_BINDING=1

# Convert ARGS_STR back to array
eval "ARGS=($ARGS_STR)"

# Determine binary paths based on TARGET
# Binaries are expected in /unibench/{target}/fuzzer/{fast,track}
FAST_BIN="/d/p/angora/fast/${TARGET}"
TRACK_BIN="/d/p/angora/taint/${TARGET}"
OUTPUT_DIR="$SHARED/findings"

# Copy cmpid log files from target source directory to output directory
source /volume/targets.conf
TARGET_NORMALIZED="${TARGET//-/_}"
source_dir_var="${TARGET_NORMALIZED}_source_dir"
SOURCE_DIR="${!source_dir_var}"
for f in cmpid_fast.txt cmpid_track.txt; do
    if [ -f "$SOURCE_DIR/$f" ]; then
        cp "$SOURCE_DIR/$f" "$(dirname "$OUTPUT_DIR")/$f"
        echo "Copied $f from $SOURCE_DIR"
    else
        echo "Warning: $f not found at $SOURCE_DIR/$f"
    fi
done

# Check if binaries exist
if [ ! -f "$FAST_BIN" ]; then
    echo "Error: Fast binary not found at $FAST_BIN"
    exit 1
fi

if [ ! -f "$TRACK_BIN" ]; then
    echo "Error: Track binary not found at $TRACK_BIN"
    exit 1
fi

if [ ! -d "$SEED" ]; then
    echo "Error: Seed directory not found at $SEED"
    exit 1
fi

# Optional: restore from a previous run's cond_queue.csv
queue_file_flag=""
if [ -n "$QUEUE_FILE" ]; then
    queue_file_flag="-q $QUEUE_FILE"
fi

# Run angora_fuzzer
/angora/angora_fuzzer -i "$SEED" -o "$OUTPUT_DIR" \
    -t "$TRACK_BIN" $queue_file_flag $FUZZARGS -- "$FAST_BIN" "${ARGS[@]}" 2>&1

