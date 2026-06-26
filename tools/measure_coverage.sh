#!/bin/bash -e

##
# Offline coverage measurement launcher (offline-coverage workflow, run AFTER
# the campaign). For every campaign that archive_campaigns.sh snapshotted, it
# launches a coverage container that replays the iter_NNNN.tar.gz snapshots and
# writes a coverage-over-time CSV. Because the fuzzers are done, these run on the
# now-free cores and can be parallelized freely (no contention with fuzzing).
#
# Usage:
#   $0 WORKDIR INTERVAL [-r COV_RUNS] [-p PARALLEL]
#     WORKDIR  (required):  same work directory used during the campaign (has coverage/)
#     INTERVAL (required):  MINUTES per snapshot, for the time axis / plot
#                           (should match the INTERVAL passed to archive_campaigns.sh)
#     -r COV_RUNS (opt):    how many times each input is replayed per snapshot to union
#                           non-deterministic coverage (default 8; e.g. 1 = once, 10 = 10x)
#     -p PARALLEL (opt):    max concurrent coverage containers (default: nproc)
#
# ENV (used as fallback only when the matching option is omitted):
#   COVERAGE_IMAGE  docker image with the gcov binaries + lcov (default unifuzz/unibench:coverage)
#   COV_TIMEOUT     per-input replay timeout in seconds (default 5)
#   COV_RUNS        replays per input (default 8); -r overrides this
#   PARALLEL        max concurrent containers (default nproc); -p overrides this
#   CAPTURE_STRIDE  capture every Nth snapshot (default 1)
#   FINAL_HTML      1 to also emit a final genhtml report per campaign (default 0)
##

usage() { echo "Usage: $0 WORKDIR INTERVAL [-r COV_RUNS] [-p PARALLEL]"; }

# Required positionals: WORKDIR and INTERVAL.
if [ $# -lt 2 ]; then
    usage; exit 1
fi
WORKDIR="$(realpath "$1")"
INTERVAL="$2"                           # MINUTES (user-facing unit, matches plot_coverage.py)
shift 2

# Optional flags: -r COV_RUNS (replays per input), -p PARALLEL (concurrent containers).
# Precedence: flag value > matching env var > built-in default.
COV_RUNS="${COV_RUNS:-8}"
PARALLEL="${PARALLEL:-$(nproc)}"
while getopts ":r:p:" opt; do
    case "$opt" in
        r) COV_RUNS="$OPTARG" ;;
        p) PARALLEL="$OPTARG" ;;
        :)  echo "[ERROR] option -$OPTARG requires a value"; usage; exit 1 ;;
        \?) echo "[ERROR] unknown option -$OPTARG"; usage; exit 1 ;;
    esac
done

# Validate numeric args (>= 1).
for pair in "INTERVAL=$INTERVAL" "COV_RUNS=$COV_RUNS" "PARALLEL=$PARALLEL"; do
    if ! [[ "${pair#*=}" =~ ^[0-9]+$ ]] || [ "${pair#*=}" -lt 1 ]; then
        echo "[ERROR] ${pair%%=*} must be a positive integer >= 1; got: '${pair#*=}'"
        exit 1
    fi
done

INTERVAL_SECONDS=$(( INTERVAL * 60 ))   # CSV elapsed_seconds axis is in seconds

UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

COVERAGEDIR="$WORKDIR/coverage"
VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"
COVERAGE_IMAGE="${COVERAGE_IMAGE:-unifuzz/unibench:coverage}"
COV_TIMEOUT="${COV_TIMEOUT:-5}"
CAPTURE_STRIDE="${CAPTURE_STRIDE:-1}"
FINAL_HTML="${FINAL_HTML:-0}"
PLOT="${PLOT:-1}"

[ -d "$COVERAGEDIR" ] || { echo "[ERROR] coverage dir not found: $COVERAGEDIR"; exit 1; }
if ! docker image inspect "$COVERAGE_IMAGE" >/dev/null 2>&1; then
    echo "[ERROR] coverage image '$COVERAGE_IMAGE' not found. Build it first (FUZZER=coverage tools/build.sh) or set COVERAGE_IMAGE."
    exit 1
fi

SUMMARY="$COVERAGEDIR/offline_summary.csv"
echo "fuzzer,target,id,snapshots,cumulative_inputs,branches_covered,branches_total,branch_pct" > "$SUMMARY"

measure_one() {
    local fuzzer=$1 target=$2 id=$3
    local campaign_dir="$COVERAGEDIR/$fuzzer/$target/$id"
    local archives_dir="$campaign_dir/archives"

    if ! ls "$archives_dir"/iter_*.tar* >/dev/null 2>&1; then   # .tar (new) or .tar.gz (legacy)
        echo_time "skip (no snapshots): $fuzzer/$target/$id"
        return 0
    fi

    echo_time "measuring: $fuzzer/$target/$id"
    docker run --rm \
        --volume="$(realpath "$archives_dir"):/archives:ro" \
        --volume="$(realpath "$campaign_dir"):/coverage_out" \
        --volume="$VOLUME_PATH:/volume" \
        --env=TARGET="$target" \
        --env=MEASUREMENT_INTERVAL="$INTERVAL_SECONDS" \
        --env=COV_TIMEOUT="$COV_TIMEOUT" \
        --env=COV_RUNS="$COV_RUNS" \
        --env=CAPTURE_STRIDE="$CAPTURE_STRIDE" \
        --env=FINAL_HTML="$FINAL_HTML" \
        --env=TZ="Asia/Seoul" \
        --entrypoint=/volume/coverage/entrypoint.sh \
        "$COVERAGE_IMAGE" \
        &> "$campaign_dir/offline_run.log" || \
        echo_time "WARNING: measurement failed for $fuzzer/$target/$id (see $campaign_dir/offline_run.log)"
}

# Collect campaigns.
declare -a JOBS
shopt -s nullglob
for fuzzer_dir in "$COVERAGEDIR"/*; do
    [ -d "$fuzzer_dir" ] || continue
    fuzzer=$(basename "$fuzzer_dir")
    [ "$fuzzer" = "html" ] && continue
    for target_dir in "$fuzzer_dir"/*; do
        [ -d "$target_dir" ] || continue
        target=$(basename "$target_dir")
        for id_dir in "$target_dir"/*; do
            [ -d "$id_dir" ] || continue
            id=$(basename "$id_dir")
            JOBS+=("$fuzzer/$target/$id")
        done
    done
done
shopt -u nullglob

echo_time "Found ${#JOBS[@]} campaign(s); parallel=$PARALLEL ; image=$COVERAGE_IMAGE"

running=0
for job in "${JOBS[@]}"; do
    IFS='/' read -r fuzzer target id <<< "$job"
    measure_one "$fuzzer" "$target" "$id" &
    running=$((running + 1))
    if [ "$running" -ge "$PARALLEL" ]; then
        wait -n 2>/dev/null || wait
        running=$((running - 1))
    fi
done
wait

# Aggregate final CSV rows into a summary.
for job in "${JOBS[@]}"; do
    IFS='/' read -r fuzzer target id <<< "$job"
    csv="$COVERAGEDIR/$fuzzer/$target/$id/coverage_over_time.csv"
    [ -f "$csv" ] || continue
    last=$(tail -n +2 "$csv" | tail -1)
    [ -n "$last" ] || continue
    IFS=',' read -r iter elapsed new cum br_cov br_tot br_pct rest <<< "$last"
    snaps=$(( $(wc -l < "$csv") - 1 ))
    echo "$fuzzer,$target,$id,$snaps,$cum,$br_cov,$br_tot,$br_pct" >> "$SUMMARY"
done

echo_time "Offline measurement complete."
echo_time "Per-campaign series: $COVERAGEDIR/<fuzzer>/<target>/<id>/coverage_over_time.csv"
echo_time "Summary: $SUMMARY"
column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"

# Visualization with plot_coverage.py (reads each campaign's coverage.log).
if [ "$PLOT" != "0" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import matplotlib' >/dev/null 2>&1; then
        echo_time "Generating graphs (plot_coverage.py --interval $INTERVAL)..."
        if python3 "$UNIBENCH/tools/plot_coverage.py" "$WORKDIR" --interval "$INTERVAL"; then
            echo_time "Graphs written to $WORKDIR/graph"
        else
            echo_time "WARNING: plot_coverage.py failed (coverage data still available as CSV)"
        fi
    else
        echo_time "Skipping plots: python3 + matplotlib not available (pip install matplotlib). CSV/coverage.log still produced."
    fi
fi
