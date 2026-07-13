#!/bin/bash

##
# Incrementally archives new files in the campaign cache directory at regular intervals.
#
# Usage: archive_queue.sh CACHE_DIR ARCHIVE_DIR INTERVAL [MAX_ITERATIONS]
#
#   CACHE_DIR:      campaign cache directory (e.g. $CACHEDIR/$FUZZER/$TARGET/$CACHECID)
#   ARCHIVE_DIR:    directory to write iter_NNNN.tar.gz archives
#   INTERVAL:       seconds between archives
#   MAX_ITERATIONS: (optional) stop after this many archives
#
# Archives are named iter_0000.tar.gz, iter_0001.tar.gz, ... Each archive holds
# the queue files (id:*) discovered since the previous iteration.
#
# COMPLETENESS (why a full scan, not `find -newer`):
#   The fuzzer writes the queue directory concurrently. `find -newer <marker>`
#   plus a monotonically-advanced watermark is NOT complete under concurrent
#   directory modification: a single readdir over an ext4 htree dir can skip
#   live entries (POSIX gives no guarantee for concurrently-modified dirs), and
#   files whose mtime == the watermark are excluded by strict `-newer`; the
#   advancing watermark then strands those files below the cutoff forever ->
#   SILENT, PERMANENT loss from the coverage archives. So we do a full readdir
#   every iteration and dedup against a persistent manifest of already-archived
#   basenames. A file skipped by one readdir is simply picked up by the next
#   scan (self-healing); the manifest makes it restart-safe. The full scan is
#   cheap now that per-file forks are gone (${f##*/}, no basename): ~seconds for
#   a 100-200k-file queue, far under the interval. Correctness > microseconds.
##

CACHE_DIR="$1"
ARCHIVE_DIR="$2"
INTERVAL="$3"
MAX_ITERATIONS="${4:-}"

if [ -z "$CACHE_DIR" ] || [ -z "$ARCHIVE_DIR" ] || [ -z "$INTERVAL" ]; then
    echo "Usage: $0 CACHE_DIR ARCHIVE_DIR INTERVAL [MAX_ITERATIONS]"
    exit 1
fi

mkdir -p "$ARCHIVE_DIR"

echo_ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [archive] $*"; }

# --- Singleton: only one archiver per ARCHIVE_DIR (prevents two racers from
#     corrupting archives / the manifest after an archive_campaigns restart). ---
exec 9>"$ARCHIVE_DIR/.archiver.lock"
if ! flock -n 9; then
    echo_ts "another archiver already owns $ARCHIVE_DIR; exiting"
    exit 0
fi

MANIFEST="$ARCHIVE_DIR/.archived_names"     # persistent set of accounted basenames
MIN_SLEEP="${MIN_SLEEP:-60}"                 # floor so the archiver never starves the fuzzer/disk
DRYRUN_WAIT_TIMEOUT="${DRYRUN_WAIT_TIMEOUT:-0}"   # 0 = wait forever for dryrun_finish

find_queue_dir() {
    if [ -d "$CACHE_DIR/findings/queue" ]; then
        echo "$CACHE_DIR/findings/queue"
    elif [ -d "$CACHE_DIR/findings/default/queue" ]; then
        echo "$CACHE_DIR/findings/default/queue"
    fi
}

# Wait for the queue directory. Exit if the campaign cache vanishes (moved to
# ar/) so the archive_campaigns driver can drain and self-terminate.
echo_ts "Waiting for queue directory in $CACHE_DIR..."
while true; do
    [ -d "$CACHE_DIR" ] || { echo_ts "cache dir vanished before queue appeared; exiting"; exit 0; }
    QUEUE_DIR=$(find_queue_dir)
    [ -n "$QUEUE_DIR" ] && break
    sleep 5 9>&-
done
echo_ts "Queue directory found: $QUEUE_DIR"

# Wait for dryrun_finish (with a cache-vanished guard and optional timeout).
echo_ts "Waiting for dryrun_finish signal (timeout: ${DRYRUN_WAIT_TIMEOUT}s)..."
_waited=0
while [ ! -f "$QUEUE_DIR/signal/dryrun_finish" ]; do
    [ -d "$CACHE_DIR" ] || { echo_ts "cache dir vanished while waiting for dryrun_finish; exiting"; exit 0; }
    sleep 3 9>&-
    _waited=$((_waited + 3))
    if [ "$DRYRUN_WAIT_TIMEOUT" -gt 0 ] && [ "$_waited" -ge "$DRYRUN_WAIT_TIMEOUT" ]; then
        echo_ts "WARNING: dryrun_finish not seen after ${DRYRUN_WAIT_TIMEOUT}s; starting anyway"
        break
    fi
done
[ -f "$QUEUE_DIR/signal/dryrun_finish" ] && echo_ts "dryrun_finish detected"

# --- Load the persistent manifest (resume-safe) into the in-memory set. ---
declare -A SEEN
if [ -f "$MANIFEST" ]; then
    while IFS= read -r _nm; do [ -n "$_nm" ] && SEEN[$_nm]=1; done < "$MANIFEST"
    echo_ts "resume: loaded ${#SEEN[@]} accounted names from manifest"
    FRESH=0
else
    : > "$MANIFEST"
    FRESH=1
fi

# --- Base install (saturation): put the prebuilt fixed-seed base at iter_0000
#     instead of dumping the ~100k dry-run queue. run.sh normally pre-installs
#     it directly; BASE_ARCHIVE is an alternative path. ---
if [ -n "$BASE_ARCHIVE" ] && [ -f "$BASE_ARCHIVE" ] && [ ! -f "$ARCHIVE_DIR/iter_0000.tar.gz" ]; then
    ln -f "$BASE_ARCHIVE" "$ARCHIVE_DIR/iter_0000.tar.gz" 2>/dev/null || \
        cp -f "$BASE_ARCHIVE" "$ARCHIVE_DIR/iter_0000.tar.gz"
    [ -f "$ARCHIVE_DIR/iter_0000.tar.gz" ] && echo_ts "installed base -> iter_0000.tar.gz (from $BASE_ARCHIVE)"
fi

# Saturation mode = the dry-run queue must be SKIPPED (its coverage is the fixed
# base at iter_0000). Signalled by run.sh's .skip_preloaded flag OR by a present
# iter_0000. Independent of base-build success, so a base hiccup never degrades
# to a full-queue dump.
SATURATION=0
[ -f "$ARCHIVE_DIR/.skip_preloaded" ] && SATURATION=1
[ -f "$ARCHIVE_DIR/iter_0000.tar.gz" ] && SATURATION=1

# Resume iteration index = (highest existing iter_NNNN) + 1.
_last=-1
shopt -s nullglob
for _a in "$ARCHIVE_DIR"/iter_*.tar.gz; do
    _n=${_a##*/iter_}; _n=${_n%.tar.gz}
    [[ "$_n" =~ ^[0-9]+$ ]] || continue
    [ "$((10#$_n))" -gt "$_last" ] && _last=$((10#$_n))
done
shopt -u nullglob
ITERATION=$(( _last + 1 )); [ "$ITERATION" -lt 0 ] && ITERATION=0

# One-time base marking (saturation): the dry-run seeds present AT dryrun_finish
# are the fixed base (iter_0000); mark them accounted so they are not re-archived
# as deltas. The base/discovery boundary is the dryrun_finish SIGNAL mtime, NOT
# scan time, so a genuine post-signal discovery created while this scan runs is
# never mis-marked as base (`! -newer signal` = mtime <= signal) -> it becomes a
# delta. Guarded by a persistent .base_marked sentinel (independent of the
# manifest) so a manifest-less restart never re-baselines the LIVE queue.
BASE_MARKED="$ARCHIVE_DIR/.base_marked"
if [ "$SATURATION" = 1 ] && [ ! -f "$BASE_MARKED" ]; then
    _q=$(find_queue_dir)
    _pre=0
    if [ -n "$_q" ]; then
        _sig="$_q/signal/dryrun_finish"
        if [ -f "$_sig" ]; then _pred=( ! -newer "$_sig" ); else _pred=(); fi
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            nm="${f##*/}"
            if [ -z "${SEEN[$nm]+x}" ]; then SEEN[$nm]=1; printf '%s\n' "$nm" >> "$MANIFEST"; _pre=$((_pre+1)); fi
        done < <(find "$_q" -maxdepth 1 -name 'id:*' -type f "${_pred[@]}" 2>/dev/null)
    fi
    : > "$BASE_MARKED"
    echo_ts "saturation: marked $_pre dry-run base files (boundary=dryrun_finish); post-signal discoveries kept as deltas"
    [ "$ITERATION" -lt 1 ] && ITERATION=1   # iter_0000 is the base
fi

echo_ts "starting at iter $ITERATION (interval ${INTERVAL}s, min_sleep ${MIN_SLEEP}s, saturation=$SATURATION)"

while true; do
    [ -d "$CACHE_DIR" ] || { echo_ts "cache dir vanished; exiting"; exit 0; }
    ARCHIVE_PATH="$ARCHIVE_DIR/$(printf 'iter_%04d.tar.gz' "$ITERATION")"
    ITER_START=$(date +%s)
    CURRENT_QUEUE_DIR=$(find_queue_dir)

    # Full readdir; dedup against SEEN (self-healing over concurrent inserts).
    NEW_FILES=(); NEW_NAMES=()
    if [ -n "$CURRENT_QUEUE_DIR" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            nm="${f##*/}"
            if [ -z "${SEEN[$nm]+x}" ]; then NEW_FILES+=("$f"); NEW_NAMES+=("$nm"); fi
        done < <(find "$CURRENT_QUEUE_DIR" -maxdepth 1 -name 'id:*' -type f 2>/dev/null)
    else
        echo_ts "iter $ITERATION: queue dir not found"
    fi
    NEW_FILE_COUNT=${#NEW_FILES[@]}
    echo_ts "iter $ITERATION: $NEW_FILE_COUNT new files to archive"

    ARCHIVE_TMP=$(mktemp "${ARCHIVE_PATH}.XXXXXX")
    COPIED_NAMES=()
    if [ "$NEW_FILE_COUNT" -gt 0 ]; then
        RELATIVE_QUEUE="${CURRENT_QUEUE_DIR#$CACHE_DIR/}"
        TEMP_DIR=$(mktemp -d)
        mkdir -p "$TEMP_DIR/$RELATIVE_QUEUE"
        for i in "${!NEW_FILES[@]}"; do
            # Account a file ONLY if it was actually copied into the archive. A
            # file that failed cp (vanished/unreadable) stays UNaccounted so the
            # next full scan re-archives it (self-healing; never a silent loss).
            if cp "${NEW_FILES[$i]}" "$TEMP_DIR/$RELATIVE_QUEUE/" 2>/dev/null; then
                COPIED_NAMES+=("${NEW_NAMES[$i]}")
            fi
        done
        echo_ts "iter $ITERATION: archiving ${#COPIED_NAMES[@]}/$NEW_FILE_COUNT new files..."
        tar czf "$ARCHIVE_TMP" -C "$TEMP_DIR" "$RELATIVE_QUEUE" 2>/dev/null
        TAR_EXIT=$?
        rm -rf "$TEMP_DIR"
    else
        tar czf "$ARCHIVE_TMP" -T /dev/null 2>/dev/null
        TAR_EXIT=$?
    fi

    if [ "$TAR_EXIT" -eq 0 ] || [ "$TAR_EXIT" -eq 1 ]; then
        mv -f "$ARCHIVE_TMP" "$ARCHIVE_PATH"
        # DURABLE-THEN-RECORD: only after the archive is committed, and only for
        # files actually copied into it, do we mark accounted (SEEN + manifest).
        # A crash before this, or a cp failure, leaves files unaccounted ->
        # re-archived next scan (dup, which coverage-union tolerates) not lost.
        if [ "${#COPIED_NAMES[@]}" -gt 0 ]; then
            printf '%s\n' "${COPIED_NAMES[@]}" >> "$MANIFEST"
            for nm in "${COPIED_NAMES[@]}"; do SEEN[$nm]=1; done
        fi
        echo_ts "iter $ITERATION: done -> $ARCHIVE_PATH (${#COPIED_NAMES[@]} new files, total accounted ${#SEEN[@]})"
    else
        rm -f "$ARCHIVE_TMP"
        echo_ts "iter $ITERATION: tar FAILED (exit $TAR_EXIT); files stay unaccounted, retried next iter"
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
    if [ "$SLEEP_TIME" -lt "$MIN_SLEEP" ]; then
        [ "$ELAPSED" -ge "$INTERVAL" ] && echo_ts "iter $((ITERATION-1)): scan+archive took ${ELAPSED}s (>= interval ${INTERVAL}s)"
        SLEEP_TIME=$MIN_SLEEP
    fi
    sleep "$SLEEP_TIME" 9>&-
done
