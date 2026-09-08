#!/bin/bash

##
# Pre-requirements:
# - env TARGET: target name (e.g., jq)
# - env SEED: path to seed directory to scan
# - env SHARED: path to shared directory (cache lands here, on the host)
# - env ARGS_STR: extra arguments to pass to the program
##
#
# Seed-scan-only companion to ./run.sh: instead of running afl-fuzz, runs
# reusing-taint-worker in its -S (seed-scan) mode against $SEED, once, and
# exits -- no queue/, no campaign, nothing kept running. Meant to be
# launched ahead of time (RUN_SCRIPT=run_taint.sh, see entrypoint.sh) so
# the resulting cache already exists by the time a real campaign's
# ./run.sh + reusing-taint-worker -c (see there) points at it for the same
# $SEED. Reuses start.sh's existing $SEED -> /customized_seed mount and
# $SHARED -> /unibench_shared mount unchanged -- this script only differs
# from ./run.sh in which binary it execs and that it's a one-shot batch job,
# not a campaign.

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

export AFL_MAP_SIZE=256000

# Convert ARGS_STR back to array
eval "ARGS=($ARGS_STR)"

DTAINT_BIN="/d/p/aflplusplus-reusing/dtaint/${TARGET}"

# Cache dir keyed by target only, not by campaign -- meant to be reused
# across every future campaign run against this same $SEED for this same
# target. Lands under $SHARED so it's visible on the host afterward (same
# mount start.sh already sets up for a normal campaign's findings).
CACHE_DIR="$SHARED/seed_taint_cache/${TARGET}"

if [ ! -f "$DTAINT_BIN" ]; then
    echo "Error: Dtaint (real-DFSan) binary not found at $DTAINT_BIN"
    exit 1
fi

if [ ! -d "$SEED" ]; then
    echo "Error: Seed directory not found at $SEED"
    exit 1
fi

mkdir -p "$CACHE_DIR"

# cmpid -> source-location table (see run.sh's own copy of this same step
# for the full rationale) -- copy it alongside the cache dir so a cached
# .dtaint record's cmpid can be looked up without a shell into the
# container. Best-effort so an older image doesn't fail the run over it.
CMPID_LOCS="/d/p/aflplusplus-reusing/dtaint/${TARGET}.cmpid_log.txt"
if [ -f "$CMPID_LOCS" ]; then
    cp "$CMPID_LOCS" "$CACHE_DIR/cmpid_log.txt"
else
    echo "Warning: cmpid_log.txt not found for $TARGET at $CMPID_LOCS (image built before ANGORA_OUTPUT_COND_LOC logging was added?)"
fi

echo "Seed-scan mode: $SEED -> $CACHE_DIR (target: $TARGET)"
reusing-taint-worker -S "$SEED" -o "$CACHE_DIR" -- "$DTAINT_BIN" "${ARGS[@]}" 2>&1
