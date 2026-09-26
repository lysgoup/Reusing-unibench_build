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
# taint_scan produced for this target ahead of the campaign
# (value_pool.dict, unsolved_condition and one .dtaint per seed). afl-fuzz
# reads it in its reusing stage; see src/afl-fuzz-reusing.c. Trimming is off
# for the whole run, forced by -r, since it would rewrite a queue entry and
# leave every offset in its .dtaint pointing at the wrong byte.

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

# afl-fuzz -r's value: this target's taint pool (taint_scan's
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
OUTPUT_DIR="$SHARED/findings"

if [ ! -f "$FAST_BIN" ]; then
    echo "Error: Fast (main) binary not found at $FAST_BIN"
    exit 1
fi

if [ ! -d "$SEED" ]; then
    echo "Error: Seed directory not found at $SEED"
    exit 1
fi

echo "Taint pool (-r): $TAINT_DIR"

# afl-fuzz prints what -r loaded (pool entries, unsolved sites, how many seeds
# got taint data) before multilog attaches, so those lines are otherwise lost.
# Keep a copy next to the findings -- it is the only record of what this
# campaign actually read.
# Only the first lines are worth keeping -- past the banner it is just the
# periodic status, which multilog already has. awk (not tee | head) so the
# rest of the stream still reaches multilog instead of dying on SIGPIPE.
afl-fuzz -i "$SEED" -o "$OUTPUT_DIR" -r "$TAINT_DIR" $FUZZARGS -- "$FAST_BIN" "${ARGS[@]}" 2>&1 \
    | awk -v f="$OUTPUT_DIR/reusing_load.log" 'NR <= 200 { print > f; fflush(f) } { print }'
