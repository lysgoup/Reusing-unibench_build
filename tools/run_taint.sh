#!/bin/bash -e

##
# Pre-requirements:
# - env TARGET: target name (e.g., jq)
# - env SEED: path to the seed directory to scan
# - env SHARED: host directory to write the cache into (findings/seed_taint_cache/
#       lands here, same mount start.sh already sets up for a normal campaign)
# + env FUZZER: fuzzer image to use (default: aflplusplus-reusing -- the
#       only fuzzer this project builds dtaint/ binaries for)
##
#
# Host-level wrapper for a one-shot seed-scan run, sitting between the full
# campaign orchestrator (run.sh, captainrc-driven, way more than this needs
# -- TIMEOUT/saturation/archiving machinery for a job that just exits when
# done) and the bare single-container launcher (start.sh, which doesn't
# build anything). This is: build.sh (idempotent -- a no-op if the image is
# already current, so safe to call every time) then start.sh with
# RUN_SCRIPT=run_taint.sh so entrypoint.sh execs tools/volume/$FUZZER/
# run_taint.sh instead of the normal run.sh. See that file for what
# actually runs inside the container.

FUZZER="${FUZZER:-aflplusplus-reusing}"
export FUZZER

if [ -z "$TARGET" ] || [ -z "$SEED" ] || [ -z "$SHARED" ]; then
    echo '$TARGET, $SEED, and $SHARED must be specified as environment variables.'
    exit 1
fi

UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

echo_time "Building $FUZZER (no-op if already current)..."
"$UNIBENCH"/tools/build.sh

echo_time "Seed-scan: $SEED -> \$SHARED/seed_taint_cache/$TARGET (target: $TARGET)"
RUN_SCRIPT=run_taint.sh "$UNIBENCH"/tools/start.sh
