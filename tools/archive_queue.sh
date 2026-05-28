#!/bin/bash

##
# Incrementally archives new files in the campaign cache directory at regular intervals
#
# Usage: archive_queue.sh CACHE_DIR ARCHIVE_DIR INTERVAL [MAX_ITERATIONS]
#
#   CACHE_DIR:      campaign cache directory (e.g. $CACHEDIR/$FUZZER/$TARGET/$CACHECID)
#   ARCHIVE_DIR:    directory to write iter_NNNN.tar.gz archives
#   INTERVAL:       seconds between archives
#   MAX_ITERATIONS: (optional) stop after this many archives
#
# Archives are named iter_0000.tar.gz, iter_0001.tar.gz, ...
# Each archive contains only files added since the previous iteration.
# If no new files exist, an empty marker file is created to keep iteration indices aligned.
##

CACHE_DIR="$1"
ARCHIVE_DIR="$2"
INTERVAL="$3"
MAX_ITERATIONS="${4:-}"

if [ -z "$CACHE_DIR" ] || [ -z "$ARCHIVE_DIR" ] || [ -z "$INTERVAL" ]; then
    echo "Usage: $0 CACHE_DIR ARCHIVE_DIR INTERVAL [MAX_ITERATIONS]"
    echo ""
    echo "  CACHE_DIR:      campaign cache directory (e.g. \$CACHEDIR/\$FUZZER/\$TARGET/\$CACHECID)"
    echo "  ARCHIVE_DIR:    directory to write iter_NNNN.tar.gz archives"
    echo "  INTERVAL:       seconds between archives"
    echo "  MAX_ITERATIONS: (optional) stop after this many archives"
    echo ""
    echo "Archives are named iter_0000.tar.gz, iter_0001.tar.gz, ..."
    echo "Each archive contains only files added since the previous iteration."
    echo "If no new files exist, an empty marker file is created to keep iteration indices aligned."
    exit 1
fi

mkdir -p "$ARCHIVE_DIR"

echo_ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [archive] $*"; }

# Find queue directory (handles angora and afl++ structures)
find_queue_dir() {
    if [ -d "$CACHE_DIR/findings/queue" ]; then
        echo "$CACHE_DIR/findings/queue"
    elif [ -d "$CACHE_DIR/findings/default/queue" ]; then
        echo "$CACHE_DIR/findings/default/queue"
    fi
}

# Wait for queue directory to appear
echo_ts "Waiting for queue directory in $CACHE_DIR..."
while true; do
    QUEUE_DIR=$(find_queue_dir)
    [ -n "$QUEUE_DIR" ] && break
    sleep 5
done
echo_ts "Queue directory found: $QUEUE_DIR"

# Wait for dryrun_finish signal before starting archive loop
echo_ts "Waiting for dryrun_finish signal..."
while [ ! -f "$QUEUE_DIR/signal/dryrun_finish" ]; do
    sleep 3
done
echo_ts "dryrun_finish detected, starting archive loop (interval: ${INTERVAL}s)"

ITERATION=0

while true; do
    ARCHIVE_PATH="$ARCHIVE_DIR/$(printf 'iter_%04d.tar.gz' $ITERATION)"

    ITER_START=$(date +%s)
    CURRENT_QUEUE_DIR=$(find_queue_dir)
    if [ -n "$CURRENT_QUEUE_DIR" ]; then
        QUEUE_FILE_COUNT=$(find "$CURRENT_QUEUE_DIR" -maxdepth 1 -name 'id:*' -type f 2>/dev/null | wc -l)
        echo_ts "iter $ITERATION: queue has $QUEUE_FILE_COUNT files in $CURRENT_QUEUE_DIR"
    else
        echo_ts "iter $ITERATION: queue dir not found"
    fi
    echo_ts "iter $ITERATION: archiving $CACHE_DIR..."
    ARCHIVE_TMP="${ARCHIVE_PATH}.tmp"
    tar czf "$ARCHIVE_TMP" -C "$CACHE_DIR" . 2>/dev/null
    TAR_EXIT=$?
    if [ "$TAR_EXIT" -eq 0 ] || [ "$TAR_EXIT" -eq 1 ]; then
        mv "$ARCHIVE_TMP" "$ARCHIVE_PATH"
        ARCHIVE_QUEUE_COUNT=$(tar tzf "$ARCHIVE_PATH" 2>/dev/null | grep -c 'findings/queue/id:' || echo 0)
        echo_ts "iter $ITERATION: done -> $ARCHIVE_PATH (archive contains $ARCHIVE_QUEUE_COUNT queue files, queue had $QUEUE_FILE_COUNT)"
    else
        rm -f "$ARCHIVE_TMP"
        echo_ts "iter $ITERATION: tar FAILED (exit code $TAR_EXIT) -> $ARCHIVE_PATH"
    fi

    ITERATION=$((ITERATION + 1))

    if [ -n "$MAX_ITERATIONS" ] && [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
        echo_ts "Max iterations ($MAX_ITERATIONS) reached, stopping"
        touch "$ARCHIVE_DIR/archive_done"
        echo_ts "archive_done signal written"
        break
    fi

    ELAPSED=$(( $(date +%s) - ITER_START ))
    SLEEP_TIME=$(( INTERVAL - ELAPSED ))
    if [ "$SLEEP_TIME" -gt 0 ]; then
        echo_ts "iter $ITERATION: waiting ${SLEEP_TIME}s..."
        sleep "$SLEEP_TIME"
    else
        echo_ts "iter $ITERATION: compression took ${ELAPSED}s, skipping sleep"
    fi
done
