#!/bin/bash -e

##
# Merge queue files from multiple fuzzing trials into a single deduplicated seed corpus.
# Uses SHA-256 hashing to eliminate duplicate inputs.
#
# Usage: $0 <fuzzer_target_dir>
# Example: $0 /path/to/ar/angora/mp3gain
#
# Expects: <dir>/{0,1,2,...}/findings/queue/id:*
# Output:  <dir>/saturated_seed/
##

if [ -z "$1" ]; then
    echo "Usage: $0 <fuzzer_target_dir>"
    echo "  e.g. $0 /path/to/ar/angora/mp3gain"
    exit 1
fi

TARGET_DIR="$(realpath "$1")"
DEST="$TARGET_DIR/saturated_seed"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: directory not found: $TARGET_DIR"
    exit 1
fi

mkdir -p "$DEST"

declare -A seen_hashes
counter=0
total=0

for run_dir in "$TARGET_DIR"/*/; do
    run_id=$(basename "$run_dir")
    # skip non-numeric directories (e.g. saturated_seed itself)
    [[ "$run_id" =~ ^[0-9]+$ ]] || continue

    queue_dir="$run_dir/findings/queue"
    [ -d "$queue_dir" ] || continue

    for f in "$queue_dir"/id:*; do
        [[ -f "$f" ]] || continue
        total=$((total + 1))
        hash=$(sha256sum "$f" | cut -d' ' -f1)
        if [[ -z "${seen_hashes[$hash]+x}" ]]; then
            seen_hashes[$hash]=1
            printf -v new_name "id:%06d" $counter
            cp "$f" "$DEST/$new_name"
            counter=$((counter + 1))
        fi
    done
done

duplicates=$((total - counter))

echo "Target dir  : $TARGET_DIR"
echo "Output dir  : $DEST"
echo "Total inputs: $total"
echo "Unique files: $counter"
echo "Duplicates  : $duplicates"
