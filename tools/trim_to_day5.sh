#!/bin/bash -e

##
# Trim each trial's queue to its day-5 (iter_0480) state, then re-merge saturated seeds.
#
# Usage: $0 <saturation_dir>
# Example: $0 /path/to/_saturation
##

if [ -z "$1" ]; then
    echo "Usage: $0 <saturation_dir>"
    echo "  e.g. $0 /path/to/_saturation"
    exit 1
fi

SAT_DIR="$(realpath "$1")"
LOGDIR="$SAT_DIR/log"
ARDIR="$SAT_DIR/ar"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGETS=(exiv2 flvmeta infotocap mp3gain mp42aac objdump pdftotext tcpdump tiffsplit)
TRIALS=(0 1 2 3 4)
FUZZER=angora
TARGET_ITER=480

echo "=== Phase 1: Trim each trial's queue to iter_${TARGET_ITER} state ==="

for target in "${TARGETS[@]}"; do
    for trial in "${TRIALS[@]}"; do
        logfile="$LOGDIR/archive_${FUZZER}::${target}::${trial}.log"
        qdir="$ARDIR/$FUZZER/$target/$trial/findings/queue"

        if [ ! -f "$logfile" ]; then
            echo "[SKIP] $target/$trial: no log file"
            continue
        fi
        if [ ! -d "$qdir" ]; then
            echo "[SKIP] $target/$trial: no queue dir"
            continue
        fi

        # Extract "queue has N" from the iter TARGET_ITER check line
        day5_count=$(grep "iter ${TARGET_ITER}:" "$logfile" | grep -oP 'queue has \K[0-9]+' | tail -1)
        if [ -z "$day5_count" ]; then
            echo "[WARN] $target/$trial: iter_${TARGET_ITER} not found in log, skipping"
            continue
        fi

        current_count=$(find "$qdir" -maxdepth 1 -name 'id:*' | wc -l)
        to_delete=$(( current_count - day5_count ))

        if [ "$to_delete" -le 0 ]; then
            echo "[OK]   $target/$trial: $current_count id:* files, day-5=$day5_count, nothing to trim"
            continue
        fi

        echo "[TRIM] $target/$trial: $current_count -> $day5_count (deleting $to_delete files)..."

        # Files are named id:NNNNNN (zero-padded, sequential). Sort and remove the last to_delete.
        find "$qdir" -maxdepth 1 -name 'id:*' | sort | tail -n "$to_delete" | \
            xargs -r -P4 rm -f

        after_count=$(find "$qdir" -maxdepth 1 -name 'id:*' | wc -l)
        echo "       done: $after_count id:* files remain"
    done
done

echo ""
echo "=== Phase 2: Re-merge saturated seeds per target ==="

for target in "${TARGETS[@]}"; do
    target_dir="$ARDIR/$FUZZER/$target"
    seed_dir="$target_dir/saturated_seed"

    if [ -d "$seed_dir" ]; then
        echo "[RM]   Removing old $seed_dir"
        rm -rf "$seed_dir"
    fi

    echo "[MERGE] $target"
    "$TOOLS_DIR/merge_saturated_seed.sh" "$target_dir"
    echo ""
done

echo "=== Done ==="
