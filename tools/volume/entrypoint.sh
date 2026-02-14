#!/bin/bash

##
# Pre-requirements:
# - env FUZZER: fuzzer name (angora, aflplusplus, angora-reusing, etc.)
# - env TARGET: target name (automatically loads args from targets.conf)
# - env FUZZARGS: extra arguments to pass to the fuzzer
# - env SHARED: path to directory shared with host (to store results)
# + env TIMEOUT: time (in seconds) to run the campaign (optional - if not set, runs indefinitely)
# + env SEED: path to seed directory
# + env CUSTOMIZED_SEED: path to customized seed directory (mounted as /customized_seed)
# + env LOGSIZE: size (in bytes) of log file to generate (default: 1 MiB)
##

# Set default max log size to 1 MiB
LOGSIZE=${LOGSIZE:-$[1 << 20]}

# Validate required environment variables
if [ -z "$FUZZER" ] || [ -z "$TARGET" ]; then
    echo "Error: Required environment variables missing (FUZZER, TARGET)"
    exit 1
fi

# TIMEOUT is optional - if not set, run indefinitely until user stops
if [ -z "$TIMEOUT" ]; then
    echo "Note: TIMEOUT not specified, will run until manually stopped"
fi

# Load target configuration
TARGETS_CONF="/volume/targets.conf"
if [ ! -f "$TARGETS_CONF" ]; then
    echo "Error: targets.conf not found at $TARGETS_CONF"
    exit 1
fi

source "$TARGETS_CONF"

# Extract args for the target (convert hyphens to underscores for variable lookup)
TARGET_NORMALIZED="${TARGET//-/_}"
target_args_var="${TARGET_NORMALIZED}_args[@]"

# Check if args are empty
if [ -z "${!target_args_var}" ]; then
    # If args are empty, check if stdin is used instead
    target_stdin_var="${TARGET_NORMALIZED}_stdin_from_file"
    target_stdin_from_file="${!target_stdin_var}"

    if [ "$target_stdin_from_file" != "1" ]; then
        echo "Error: No args found for target '$TARGET' in targets.conf, and stdin_from_file is not set"
        exit 1
    fi
    # If stdin_from_file=1, args being empty is OK, so just leave ARGS_STR empty
    ARGS_STR=""
    export ARGS_STR
else

    # Convert array to quoted string for proper export
    # This preserves arguments with spaces when passed to run.sh
    declare -a ARGS_ARRAY=( "${!target_args_var}" )
    ARGS_STR=""
    for arg in "${ARGS_ARRAY[@]}"; do
        ARGS_STR="$ARGS_STR $(printf '%q' "$arg")"
    done
    export ARGS_STR
fi

# Extract seed_dir for the target
target_seed_dir_var="${TARGET_NORMALIZED}_seed_dir"
target_seed_dir="${!target_seed_dir_var}"
if [ -z "$target_seed_dir" ]; then
    echo "Error: No seed_dir found for target '$TARGET' in targets.conf"
    exit 1
fi

# Set SEED automatically if not provided
if [ -z "$SEED" ]; then
    SEED="/volume/seeds/general_evaluation/$target_seed_dir"
    export SEED
fi

# Set up fuzzer-specific run script
FUZZER_RUN_SCRIPT="/volume/$FUZZER/run.sh"

if [ ! -f "$FUZZER_RUN_SCRIPT" ]; then
    echo "Error: Fuzzer run script not found: $FUZZER_RUN_SCRIPT"
    exit 1
fi

if [ ! -x "$FUZZER_RUN_SCRIPT" ]; then
    chmod +x "$FUZZER_RUN_SCRIPT"
fi

# Set SHARED to the mounted path in the container
export SHARED="/unibench_shared"

# Check if shared directory exists, if not exit
if [ ! -d "$SHARED" ]; then
    echo "Error: Shared directory $SHARED does not exist in container"
    echo "Please mount a host directory with: --volume=<host_path>:/unibench_shared"
    exit 1
fi

cd "$SHARED"

echo "Campaign launched at $(date '+%F %R')"
echo "Fuzzer: $FUZZER, Target: $TARGET"

# Execute fuzzer with timeout (optional)
foreground_flag=""
if [ "$FUZZER" = "coverage" ]; then
    foreground_flag="--foreground"
fi

if [ -n "$TIMEOUT" ]; then
    # Run with timeout
    timeout $foreground_flag --signal=INT $TIMEOUT "$FUZZER_RUN_SCRIPT" | \
        multilog n2 s$LOGSIZE "$SHARED/log"
else
    # Run without timeout (until user stops)
    "$FUZZER_RUN_SCRIPT" | \
        multilog n2 s$LOGSIZE "$SHARED/log"
fi

if [ -f "$SHARED/log/current" ]; then
    cat "$SHARED/log/current"
fi

echo "Campaign terminated at $(date '+%F %R')"

# Clean up background jobs
kill $(jobs -p) 2>/dev/null
