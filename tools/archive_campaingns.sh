#!/bin/bash
# NOTE: deliberately NOT 'set -e'. This is a long-running polling daemon; a
# transient non-zero from docker/grep/ls on a vanishing campaign dir must not
# kill the whole monitor.

##
# Archiving-only campaign driver (offline-coverage workflow).
#
# Replaces the live-coverage measure_coverage.sh during the campaign. It does
# NOT launch any coverage container and does NOT run lcov/genhtml while fuzzing,
# so it imposes no CPU contention on the pinned fuzzers. For every live fuzzing
# campaign it starts ONE lightweight, niced archiver (archive_queue.sh) that
# snapshots the queue into iter_NNNN.tar.gz every INTERVAL seconds, for
# MAX_ITERATIONS iterations. When a campaign reaches MAX_ITERATIONS the archiver
# writes archive_done; this driver then SIGINTs the matching fuzzer container so
# the campaign stops at the fixed duration (~INTERVAL * MAX_ITERATIONS).
#
# Coverage is measured AFTERWARDS, offline, from the iter_NNNN snapshots with
#   tools/measure_coverage_offline.sh
#
# Usage:
#   $0 WORKDIR INTERVAL MAX_ITERATIONS [--measure]
#     WORKDIR:        path to work directory (same as run.sh WORKDIR)
#     INTERVAL:       MINUTES between queue snapshots (consistent with plot_coverage.py)
#     MAX_ITERATIONS: number of snapshots, i.e. campaign length = INTERVAL*MAX minutes
#     --measure:      (optional) after ALL campaigns finish archiving, run offline
#                     coverage measurement + visualization (measure_coverage_offline.sh).
#                     DEFAULT (flag absent) = archiving only; measure later, on demand:
#                         tools/measure_coverage_offline.sh WORKDIR INTERVAL
#
# Example: 5 days at 15-minute snapshots = 15 * 480 minutes -> `$0 WORKDIR 15 480`
##

MEASURE_ON_FINISH=0
POSITIONAL=()
for a in "$@"; do
    case "$a" in
        --measure|--measure-on-finish) MEASURE_ON_FINISH=1 ;;
        -h|--help) POSITIONAL=() ; break ;;
        *) POSITIONAL+=("$a") ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 WORKDIR INTERVAL MAX_ITERATIONS [--measure]"
    echo "  WORKDIR:        path to work directory (required)"
    echo "  INTERVAL:       queue snapshot interval in MINUTES (required)"
    echo "  MAX_ITERATIONS: number of snapshots; campaign length = INTERVAL*MAX minutes (required)"
    echo "  --measure:      (optional) measure coverage + plot after all campaigns finish"
    echo "                  (default: archive only; measure later with measure_coverage_offline.sh)"
    exit 1
fi

WORKDIR="$1"
INTERVAL="$2"                       # minutes (user-facing unit)
MAX_ITERATIONS="$3"
INTERVAL_SECONDS=$(( INTERVAL * 60 ))  # archive_queue.sh sleeps in seconds

UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

WORKDIR="$(realpath "$WORKDIR")"
export CACHEDIR="$WORKDIR/cache"
export LOGDIR="$WORKDIR/log"
export COVERAGEDIR="$WORKDIR/coverage"
mkdir -p "$LOGDIR" "$COVERAGEDIR"

# Politeness wrappers so the archiver never competes with pinned fuzzers.
NICE_PREFIX=()
command -v nice   >/dev/null 2>&1 && NICE_PREFIX+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && NICE_PREFIX+=(ionice -c 3)

POLL_INTERVAL="${POLL_INTERVAL:-10}"

declare -A ARCHIVE_PIDS
declare -A REPORTED_DONE
SEEN_ANY=0

cleanup() {
    echo_time "Stopping archivers..."
    for pid in "${ARCHIVE_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM

# Start an archiver for one campaign (fuzzer/target/cacheid) if not already running.
start_archiver() {
    local FUZZER=$1 TARGET=$2 CACHECID=$3
    local key="${FUZZER}::${TARGET}::${CACHECID}"

    # Already running?
    if [ -n "${ARCHIVE_PIDS[$key]}" ] && kill -0 "${ARCHIVE_PIDS[$key]}" 2>/dev/null; then
        return
    fi

    local cache_dir="$CACHEDIR/$FUZZER/$TARGET/$CACHECID"
    [ -d "$cache_dir" ] || return
    cache_dir="$(realpath "$cache_dir")"

    local archive_dir="$COVERAGEDIR/$FUZZER/$TARGET/$CACHECID/archives"

    # If archiving already finished for this campaign, don't restart it
    # (restarting would corrupt the fixed iter_NNNN index stream).
    if [ -f "$archive_dir/archive_done" ]; then
        return
    fi
    mkdir -p "$archive_dir"

    "${NICE_PREFIX[@]}" "$UNIBENCH/tools/archive_queue.sh" \
        "$cache_dir" "$archive_dir" "$INTERVAL_SECONDS" "$MAX_ITERATIONS" \
        &>> "${LOGDIR}/archive_${key}.log" &
    ARCHIVE_PIDS[$key]=$!
    SEEN_ANY=1
    echo_time "Archiver started for $key (PID: ${ARCHIVE_PIDS[$key]})"
}

# On archive_done, SIGINT the matching fuzzer container (fixed-duration stop).
maybe_stop_fuzzer() {
    local FUZZER=$1 TARGET=$2 CACHECID=$3
    local key="${FUZZER}::${TARGET}::${CACHECID}"
    local done_file="$COVERAGEDIR/$FUZZER/$TARGET/$CACHECID/archives/archive_done"

    [ -f "$done_file" ] || return
    [ -z "${REPORTED_DONE[$key]+x}" ] || return

    echo_time "Archiving completed (max iterations): $key"
    local cache_path="$CACHEDIR/$FUZZER/$TARGET/$CACHECID"
    # Identify the fuzzer container by its /unibench_shared mount (fixed-string grep).
    local fuzzer_container
    fuzzer_container=$( { docker ps -q | xargs -r -I{} docker inspect {} \
        --format '{{.Id}} {{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' \
        2>/dev/null | grep -F "$cache_path:/unibench_shared" | awk '{print $1}'; } || true)

    if [ -n "$fuzzer_container" ]; then
        echo_time "Sending SIGINT to fuzzer container: ${fuzzer_container:0:12}"
        docker kill --signal=INT "$fuzzer_container" 2>/dev/null || true
    else
        echo_time "WARNING: fuzzer container not found for $key (campaign may already have exited)"
    fi
    REPORTED_DONE[$key]=1
}

echo_time "Archiving-only driver started (interval=${INTERVAL}min, max_iterations=${MAX_ITERATIONS})"
echo_time "Watching $CACHEDIR ; snapshots -> $COVERAGEDIR/<fuzzer>/<target>/<id>/archives"

while true; do
    have_campaign=0
    all_done=1

    if [ -d "$CACHEDIR" ]; then
        shopt -s nullglob
        for fuzzer_dir in "$CACHEDIR"/*; do
            [ -d "$fuzzer_dir" ] || continue
            FUZZER=$(basename "$fuzzer_dir")
            for target_dir in "$fuzzer_dir"/*; do
                [ -d "$target_dir" ] || continue
                TARGET=$(basename "$target_dir")
                for cache_dir in "$target_dir"/*; do
                    [ -d "$cache_dir" ] || continue
                    CACHECID=$(basename "$cache_dir")
                    have_campaign=1
                    # Only act on a populated campaign directory.
                    if [ -n "$(ls -A "$cache_dir" 2>/dev/null)" ]; then
                        start_archiver "$FUZZER" "$TARGET" "$CACHECID"
                        maybe_stop_fuzzer "$FUZZER" "$TARGET" "$CACHECID"
                        if [ ! -f "$COVERAGEDIR/$FUZZER/$TARGET/$CACHECID/archives/archive_done" ]; then
                            all_done=0
                        fi
                    fi
                done
            done
        done
        shopt -u nullglob
    fi

    # Reap finished archivers.
    for key in "${!ARCHIVE_PIDS[@]}"; do
        if ! kill -0 "${ARCHIVE_PIDS[$key]}" 2>/dev/null; then
            unset 'ARCHIVE_PIDS[$key]'
        fi
    done

    # Self-terminate once at least one campaign was seen and either no campaign
    # remains (cache moved to ar/) or every present campaign finished archiving.
    if [ "$SEEN_ANY" -eq 1 ] && [ "${#ARCHIVE_PIDS[@]}" -eq 0 ] && \
       { [ "$have_campaign" -eq 0 ] || [ "$all_done" -eq 1 ]; }; then
        echo_time "All campaigns finished archiving and archivers drained. Exiting."
        break
    fi

    sleep "$POLL_INTERVAL"
done

# Optional: measure coverage + visualize once everything is archived. By default
# (no --measure) we stop here so the benchmark is unaffected by measurement
# timing; the developer measures the archived data later, on demand.
if [ "$MEASURE_ON_FINISH" -eq 1 ]; then
    echo_time "Archiving done. Starting offline coverage measurement + visualization..."
    "$UNIBENCH/tools/measure_coverage_offline.sh" "$WORKDIR" "$INTERVAL" || \
        echo_time "WARNING: offline measurement/visualization failed (archives are intact; retry manually)."
fi
