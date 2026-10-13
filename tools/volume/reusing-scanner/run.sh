#!/bin/bash

##
# Pre-requirements (set by entrypoint.sh):
# - env TARGET:   target name (e.g., cflow)
# - env SEED:     seed directory path (inside container)
# - env SHARED:   /unibench_shared (mounted from host)
# - env ARGS_STR: quoted target args string, from targets.conf (e.g., ". @@")
##
#
# A scan, not a campaign. taint_scan runs every seed once under the track
# binary and writes the cache afl-fuzz -r reads -- value_pool.dict,
# unsolved_condition and one <seed>.dtaint -- then exits.
#
# So the captainrc knobs that pace a fuzzing run do not apply here and are
# ignored on purpose:
#
#   REPEAT   a scan is deterministic in what it covers (every seed, once);
#            running it five times gives five copies of the same cache, so
#            point it at REPEAT=1. A second trial costs the same hours and
#            tells you nothing. (Two runs do differ in the pool's *order* --
#            it is filled through HashMaps, and Rust seeds those per process
#            -- but not in what ends up there.)
#   TIMEOUT  the scan ends when the corpus does. There is no queue to keep
#            cycling, so nothing to cut short; a TIMEOUT only risks killing
#            it before it writes value_pool.dict, which it does at the end.
#   FUZZARGS afl-fuzz flags, which taint_scan does not take.
#
# The archive driver has nothing to watch either: findings/ here is the cache,
# written once at the end, not a queue that grows.

set -e

SCANNER="/reusing-scanner/bin/taint_scan"
TRACK_BIN="/d/p/taint/${TARGET}"
FAST_BIN="/d/p/fast/${TARGET}"
OUTPUT_DIR="$SHARED/findings"
mkdir -p "$OUTPUT_DIR"

[ -f "$SCANNER" ]   || { echo "Scanner not found: $SCANNER"; exit 1; }
[ -f "$TRACK_BIN" ] || { echo "Track binary not found: $TRACK_BIN"; exit 1; }
[ -f "$FAST_BIN" ]  || { echo "Fast binary not found: $FAST_BIN"; exit 1; }
[ -d "$SEED" ]      || { echo "Seed dir not found: $SEED"; exit 1; }

# targets.conf's <target>_args, already quoted by entrypoint.sh. A target that
# reads stdin (sqlite3) has none, and taint_scan reads the absence of "@@" as
# stdin mode by itself -- same rule CommandOpt uses for the fuzzer.
eval "TARGET_ARGS=($ARGS_STR)"

echo "[reusing-scanner] Target: $TARGET"
echo "[reusing-scanner] Track:  $TRACK_BIN"
echo "[reusing-scanner] Fast:   $FAST_BIN ${TARGET_ARGS[*]}"
echo "[reusing-scanner] Seeds:  $SEED ($(ls "$SEED" | wc -l) file(s))"
echo "[reusing-scanner] Output: $OUTPUT_DIR"

exec "$SCANNER" \
    -i "$SEED" \
    -o "$OUTPUT_DIR" \
    -t "$TRACK_BIN" \
    -- \
    "$FAST_BIN" \
    "${TARGET_ARGS[@]}"
