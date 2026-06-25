#!/bin/bash -e

##
# Real-time coverage measurement for fuzzer campaigns
# Automatically builds coverage image and monitors fuzzer output
#
# Pre-requirements:
# + $1: WORKDIR (required)
# + $2: INTERVAL (required, in seconds)
# + $3: MAX_ITERATIONS (required)
##

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 WORKDIR INTERVAL MAX_ITERATIONS [SATURATION_WINDOW MIN_ITERATIONS]"
    echo "WORKDIR:           path to work directory (required)"
    echo "INTERVAL:          coverage measurement interval in seconds (required)"
    echo "MAX_ITERATIONS:    number of coverage measurement iterations after dryrun (required)"
    echo "SATURATION_WINDOW: stop early if branch coverage unchanged for this many iterations (optional)"
    echo "MIN_ITERATIONS:    minimum iterations before saturation counting starts (required if SATURATION_WINDOW is set)"
    exit 1
fi

if [ -n "$4" ] && [ -z "$5" ]; then
    echo "Error: MIN_ITERATIONS is required when SATURATION_WINDOW is set"
    exit 1
fi

WORKDIR="$1"
INTERVAL="$2"
MAX_ITERATIONS="$3"
SATURATION_WINDOW="${4:-}"
MIN_ITERATIONS="${5:-}"

UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

WORKDIR="$(realpath "$WORKDIR")"
export ARDIR="$WORKDIR/ar"
export CACHEDIR="$WORKDIR/cache"
export LOGDIR="$WORKDIR/log"
export COVERAGEDIR="$WORKDIR/coverage"
mkdir -p "$LOGDIR"
mkdir -p "$COVERAGEDIR"

# Clean up empty target and fuzzer directories in cache
echo_time "Cleaning up empty cache directories..."
if [ -d "$CACHEDIR" ]; then
    # Delete target directories with no run_id subdirectories
    for target_dir in "$CACHEDIR"/*/*; do
        [ -d "$target_dir" ] || continue
        if [ -z "$(ls -A "$target_dir" 2>/dev/null)" ]; then
            echo_time "Removing empty target directory: $target_dir"
            rm -rf "$target_dir"
        fi
    done

    # Delete fuzzer directories with no target subdirectories
    for fuzzer_dir in "$CACHEDIR"/*; do
        [ -d "$fuzzer_dir" ] || continue
        if [ -z "$(ls -A "$fuzzer_dir" 2>/dev/null)" ]; then
            echo_time "Removing empty fuzzer directory: $fuzzer_dir"
            rm -rf "$fuzzer_dir"
        fi
    done
fi

# Build coverage image
echo_time "Building coverage image..."
if FUZZER=coverage "$UNIBENCH/tools/build.sh" &> "${LOGDIR}/coverage_build.log"; then
    echo_time "Coverage image built successfully"
else
    echo_time "Failed to build coverage image. Check ${LOGDIR}/coverage_build.log"
    cat "${LOGDIR}/coverage_build.log"
    exit 1
fi

# Track running coverage containers
declare -A COVERAGE_CONTAINERS
declare -A REPORTED_DONE
declare -A ARCHIVE_PIDS

cleanup()
{
    echo_time "Cleaning up coverage containers..."
    for container_id in "${COVERAGE_CONTAINERS[@]}"; do
        if docker ps -q --filter "id=$container_id" | grep -q .; then
            docker rm -f "$container_id" 2>/dev/null || true
        fi
    done
    echo_time "Cleaning up archive processes..."
    for pid in "${ARCHIVE_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM

# Clean up empty directories that haven't been modified for 3+ minutes
clean_up_empty_dir()
{
    local dir=$1
    local timeout=180  # 3 minutes in seconds

    # Check if directory exists
    [ -d "$dir" ] || return 1

    # Check if directory is empty
    if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        # Get last modification time
        local modified_time=$(stat -c %Y "$dir" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local elapsed=$((current_time - modified_time))

        if [ $elapsed -ge $timeout ]; then
            echo_time "Removing empty directory (3+ min inactive): $dir"
            rm -rf "$dir"
            return 0
        fi
    fi

    return 1
}

# Start coverage measurement for a specific cache ID (real-time monitoring)
start_coverage()
{
    local FUZZER=$1
    local TARGET=$2
    local CACHECID=$3
    local key="${FUZZER}::${TARGET}::${CACHECID}"

    # Monitor CACHE directory for real-time results
    local cache_dir="$CACHEDIR/$FUZZER/$TARGET/$CACHECID"
    if [ ! -d "$cache_dir" ]; then
        return
    fi

    cache_dir="$(realpath "$cache_dir")"
    local coverage_outdir="$COVERAGEDIR/${FUZZER}/${TARGET}/${CACHECID}"

    # Check if coverage output directory already exists
    if [ -d "$coverage_outdir" ]; then
        echo_time "Coverage output directory already exists: $coverage_outdir"
        return
    fi

    mkdir -p "$coverage_outdir/archives"

    local VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"
    local USER_ID=$(id -u)
    local GROUP_ID=$(id -g)

    # Container name based on key (replace :: with -)
    local container_name="${key//::/-}-$(date +%s%N)-cov"
    local container_id=$(
        docker run -d \
            --name="$container_name" \
            --volume="$VOLUME_PATH:/volume" \
            --volume="$coverage_outdir:/coverage_out" \
            --env=TARGET="$TARGET" \
            --env=MEASUREMENT_INTERVAL="$INTERVAL" \
            --env=TZ="Asia/Seoul" \
            ${MAX_ITERATIONS:+--env=MAX_ITERATIONS="$MAX_ITERATIONS"} \
            ${SATURATION_WINDOW:+--env=SATURATION_WINDOW="$SATURATION_WINDOW"} \
            ${MIN_ITERATIONS:+--env=MIN_ITERATIONS="$MIN_ITERATIONS"} \
            --entrypoint=/volume/coverage/entrypoint.sh \
            "unifuzz/unibench:coverage"
    )

    # Check if docker run failed
    if [ -z "$container_id" ]; then
        echo_time "Failed to start coverage container for $FUZZER::$TARGET::$CACHECID"
        return
    fi

    COVERAGE_CONTAINERS[$key]="$container_id"

    echo_time "Coverage container started for $FUZZER::$TARGET::$CACHECID (ID: ${container_id:0:12})"

    # Start logging in background
    (docker logs -f "$container_id" 2>/dev/null || true) &> "${LOGDIR}/coverage_${key}.log" &

    # Start archive process in background
    local archive_dir="$coverage_outdir/archives"
    "$UNIBENCH/tools/archive_queue.sh" \
        "$cache_dir" \
        "$archive_dir" \
        "$INTERVAL" \
        ${MAX_ITERATIONS:+"$MAX_ITERATIONS"} \
        &>> "${LOGDIR}/archive_${key}.log" &
    ARCHIVE_PIDS[$key]=$!
    echo_time "Archive process started for $FUZZER::$TARGET::$CACHECID (PID: ${ARCHIVE_PIDS[$key]})"
}

# Monitor cache directories for real-time coverage measurement
echo_time "Starting coverage monitoring (watching cache directories)..."
while true; do
    # Clean up containers for campaigns that no longer exist
    for key in "${!COVERAGE_CONTAINERS[@]}"; do
        # Extract fuzzer, target, cachecid from key (format: fuzzer::target::cachecid)
        key_fuzzer="${key%%::*}"
        key_rest="${key#*::}"
        key_target="${key_rest%%::*}"
        key_cachecid="${key_rest##*::}"
        cache_path="$CACHEDIR/$key_fuzzer/$key_target/$key_cachecid"
        if [ ! -d "$cache_path" ]; then
            container_id="${COVERAGE_CONTAINERS[$key]}"
            archive_done_file="$COVERAGEDIR/$key_fuzzer/$key_target/$key_cachecid/archives/archive_done"
            if [ -f "$archive_done_file" ]; then
                # Normal completion: leave coverage container to finish remaining archives
                if ! docker ps -q --filter "id=$container_id" | grep -q .; then
                    echo_time "Coverage container finished: $key"
                    unset 'COVERAGE_CONTAINERS[$key]'
                fi
            else
                # Unexpected termination: force kill coverage container
                echo_time "Campaign terminated unexpectedly, cleaning up: $key"
                if docker ps -q --filter "id=$container_id" | grep -q .; then
                    docker rm -f "$container_id" 2>/dev/null || true
                fi
                unset 'COVERAGE_CONTAINERS[$key]'
                if [ -n "${ARCHIVE_PIDS[$key]}" ]; then
                    kill "${ARCHIVE_PIDS[$key]}" 2>/dev/null || true
                    unset 'ARCHIVE_PIDS[$key]'
                fi
            fi
        fi
    done

    # Refresh fuzzer list from cache directory
    CURRENT_FUZZERS=()
    if [ -d "$CACHEDIR" ]; then
        for fuzzer_dir in "$CACHEDIR"/*; do
            [ -d "$fuzzer_dir" ] || continue
            fuzzer=$(basename "$fuzzer_dir")
            CURRENT_FUZZERS+=("$fuzzer")
        done
    fi

    for FUZZER in "${CURRENT_FUZZERS[@]}"; do
        # Get list of targets from cache directory
        TARGETS=()
        if [ -d "$CACHEDIR/$FUZZER" ]; then
            for target_dir in "$CACHEDIR/$FUZZER"/*; do
                [ -d "$target_dir" ] || continue
                target=$(basename "$target_dir")
                TARGETS+=("$target")
            done
        fi

        for TARGET in "${TARGETS[@]}"; do
            CAMPAIGN_CACHEDIR="$CACHEDIR/$FUZZER/$TARGET"

            [ ! -d "$CAMPAIGN_CACHEDIR" ] && continue

            # Find all cache IDs (these are created by run.sh in real-time) cache_campaigns에 ID가 담김
            shopt -s nullglob
            cache_campaigns=("$CAMPAIGN_CACHEDIR"/*)
            shopt -u nullglob

            for cache_dir in "${cache_campaigns[@]}"; do
                [ ! -d "$cache_dir" ] && continue
                CACHECID=$(basename "$cache_dir")

                # Check if directory is empty
                if [ -z "$(ls -A "$cache_dir" 2>/dev/null)" ]; then
                    # Try to clean up empty directories (3+ min inactive)
                    clean_up_empty_dir "$cache_dir"
                else
                    key="${FUZZER}::${TARGET}::${CACHECID}"
                    if ! { [ -n "${COVERAGE_CONTAINERS[$key]}" ] && \
                           docker ps -q --filter "id=${COVERAGE_CONTAINERS[$key]}" | grep -q .; }; then
                        echo_time "New campaign detected: $key"
                        start_coverage "$FUZZER" "$TARGET" "$CACHECID"
                    fi

                    done_file="$COVERAGEDIR/$FUZZER/$TARGET/$CACHECID/archives/archive_done"
                    if [ -f "$done_file" ] && [ -z "${REPORTED_DONE["$FUZZER::$TARGET::$CACHECID"]+x}" ]; then
                        echo_time "Archiving completed (max iterations): $FUZZER::$TARGET::$CACHECID"

                        # Find fuzzer container that has cache_path mounted as /unibench_shared
                        cache_path="$CACHEDIR/$FUZZER/$TARGET/$CACHECID"
                        fuzzer_container=$(docker ps -q | xargs -I{} docker inspect {} \
                            --format '{{.Id}} {{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' \
                            2>/dev/null | grep "$cache_path:/unibench_shared" | awk '{print $1}')

                        if [ -n "$fuzzer_container" ]; then
                            echo_time "Sending SIGINT to fuzzer container: ${fuzzer_container:0:12}"
                            docker kill --signal=INT "$fuzzer_container" 2>/dev/null || true
                        else
                            echo_time "Fuzzer container not found for $FUZZER::$TARGET::$CACHECID"
                        fi

                        REPORTED_DONE["$FUZZER::$TARGET::$CACHECID"]=1
                    fi

                    saturation_file="$COVERAGEDIR/$FUZZER/$TARGET/$CACHECID/saturation_done"
                    if [ -f "$saturation_file" ] && [ -z "${REPORTED_DONE["$FUZZER::$TARGET::$CACHECID"]+x}" ]; then
                        echo_time "Saturation detected: $FUZZER::$TARGET::$CACHECID"

                        cache_path="$CACHEDIR/$FUZZER/$TARGET/$CACHECID"
                        fuzzer_container=$(docker ps -q | xargs -I{} docker inspect {} \
                            --format '{{.Id}} {{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' \
                            2>/dev/null | grep "$cache_path:/unibench_shared" | awk '{print $1}')

                        if [ -n "$fuzzer_container" ]; then
                            echo_time "Sending SIGINT to fuzzer container: ${fuzzer_container:0:12}"
                            docker kill --signal=INT "$fuzzer_container" 2>/dev/null || true
                        else
                            echo_time "Fuzzer container not found for $FUZZER::$TARGET::$CACHECID"
                        fi

                        if [ -n "${ARCHIVE_PIDS[$key]}" ]; then
                            kill "${ARCHIVE_PIDS[$key]}" 2>/dev/null || true
                            unset 'ARCHIVE_PIDS[$key]'
                        fi

                        REPORTED_DONE["$FUZZER::$TARGET::$CACHECID"]=1
                    fi
                fi
            done
        done
    done

    sleep 10
done
