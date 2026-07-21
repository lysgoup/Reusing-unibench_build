#!/bin/bash
# Watches archive_done markers and runs measure_coverage.sh for a TARGET the
# moment ALL its campaigns (every fuzzer x every repeat id) finish archiving,
# instead of waiting for the whole workdir (every target) to finish. Useful
# when dry-run length varies across targets, so archive_done lands at
# different real times per target.
#
# Pure polling, no LLM/agent involved: safe to leave running for the whole
# campaign duration.
#
# Usage:
#   $0 WORKDIR INTERVAL FUZZERS TARGETS REPEAT [POLL_SECONDS] [ID_START]
#     WORKDIR:      same work directory used by run.sh / archive_campaigns.sh
#     INTERVAL:     snapshot interval in MINUTES (passed through to measure_coverage.sh)
#     FUZZERS:      comma-separated fuzzer names, e.g. angora,angora-reusing
#     TARGETS:      comma-separated target names, e.g. jq,nm,cflow,imginfo
#     REPEAT:       number of repeat ids per (fuzzer,target)
#     POLL_SECONDS: polling interval in seconds (default 10)
#     ID_START:     first campaign id to check; ids checked are
#                   ID_START..ID_START+REPEAT-1 (default 0). Needed when a
#                   target's campaigns didn't land on ids 0..REPEAT-1, e.g. a
#                   prior failed run already consumed the low ids and run.sh
#                   allocated the next free ones instead.
#
# Example:
#   ./watch_target_done.sh ../64b3b_AR_5_24_M 15 angora,angora-reusing jq,nm,cflow,imginfo 5
#   ./watch_target_done.sh ../64b3b_AR_5_24_M 15 angora,angora-reusing gdk-pixbuf-pixdata 5 10 5
##

set -u

if [ -z "${5:-}" ]; then
    echo "Usage: $0 WORKDIR INTERVAL FUZZERS TARGETS REPEAT [POLL_SECONDS] [ID_START]"
    exit 1
fi

WORKDIR="$(realpath "$1")"
INTERVAL="$2"
IFS=',' read -ra FUZZERS <<< "$3"
IFS=',' read -ra TARGETS <<< "$4"
REPEAT="$5"
POLL_SECONDS="${6:-10}"
ID_START="${7:-0}"

UNIBENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"
COVERAGEDIR="$WORKDIR/coverage"
mkdir -p "$WORKDIR/log"
LOGFILE="$WORKDIR/log/watch_target_done.log"

echo_time() { echo "[$(date '+%Y-%m-%d %H:%M')] $*"; }

declare -A TRIGGERED

echo_time "Watcher started. fuzzers=${FUZZERS[*]} targets=${TARGETS[*]} repeat=$REPEAT ids=${ID_START}..$((ID_START + REPEAT - 1)) poll=${POLL_SECONDS}s" | tee -a "$LOGFILE"

while true; do
    for TARGET in "${TARGETS[@]}"; do
        [ -n "${TRIGGERED[$TARGET]+x}" ] && continue

        expected=0
        found=0
        for FUZZER in "${FUZZERS[@]}"; do
            for ((id = ID_START; id < ID_START + REPEAT; id++)); do
                expected=$((expected + 1))
                if [ -f "$COVERAGEDIR/$FUZZER/$TARGET/$id/archives/archive_done" ]; then
                    found=$((found + 1))
                fi
            done
        done

        [ "$found" -lt "$expected" ] && continue

        # All campaigns for this target finished archiving (SIGINT already sent
        # to their fuzzer containers by archive_campaigns.sh) -> measure now.
        TRIGGERED[$TARGET]=1
        echo_time "Target '$TARGET' finished archiving ($found/$expected campaigns). Launching measure_coverage.sh -t $TARGET" | tee -a "$LOGFILE"
        nohup "$UNIBENCH/tools/measure_coverage.sh" "$WORKDIR" "$INTERVAL" -t "$TARGET" \
            >> "$WORKDIR/log/measure_${TARGET}.log" 2>&1 &
        echo_time "measure_coverage.sh for '$TARGET' started (PID: $!, log: log/measure_${TARGET}.log)" | tee -a "$LOGFILE"
    done

    remaining=0
    for TARGET in "${TARGETS[@]}"; do
        [ -n "${TRIGGERED[$TARGET]+x}" ] || remaining=$((remaining + 1))
    done
    if [ "$remaining" -eq 0 ]; then
        echo_time "All targets triggered. Watcher exiting." | tee -a "$LOGFILE"
        break
    fi

    sleep "$POLL_SECONDS"
done
