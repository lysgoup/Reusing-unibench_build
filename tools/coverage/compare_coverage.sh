#!/bin/bash -e

##
# Compare branch coverage across fuzzers and find exclusively covered branches
#
# For each target that has coverage.info in all specified fuzzers, finds:
#   - Branches covered only by fuzzer A (not any other)
#   - Branches covered only by fuzzer B (not any other)
#   - etc.
#
# Pre-requirements:
# + $1:    WORKDIR   - main experiment directory (contains ar/)
# + $2..N: FUZZERS   - fuzzer names to compare (e.g., angora angora-reusing forkserver_storfuzz)
#
# Pre-condition: batch_analyze_coverage.sh must have been run first to generate coverage.info files.
#
# Output: WORKDIR/coverage_comparison/{TARGET}/
#   branches_{FUZZER}.txt    - all covered branches for that fuzzer (sorted, deduplicated)
#   exclusive_{FUZZER}.txt   - branches covered only by that fuzzer
#   summary.txt              - per-fuzzer branch counts and exclusive counts
##

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 WORKDIR FUZZER1 FUZZER2 [FUZZER3 ...]"
    echo "  WORKDIR: main experiment directory (contains ar/)"
    echo "  FUZZER*: fuzzer names to compare"
    exit 1
fi

WORKDIR="$(realpath "$1")"
ARDIR="$WORKDIR/ar"
shift
FUZZERS=("$@")

OUTDIR="$WORKDIR/coverage_comparison"
mkdir -p "$OUTDIR"

if [ ! -d "$ARDIR" ]; then
    echo "[ERROR] ar/ not found under $WORKDIR"
    exit 1
fi

echo_time() { date "+[%F %R] $*"; }

# Extract sorted, deduplicated covered branch keys from a coverage.info file
# Output: one "file:line:block:branch" per line
extract_branches() {
    local info_file="$1"
    awk '
    /^SF:/ { file = substr($0, 4) }
    /^BRDA:/ {
        split(substr($0, 6), b, ",")
        key = file ":" b[1] ":" b[2] ":" b[3]
        count = b[4]
        if (count != "-" && count+0 > 0 && !(key in seen)) {
            seen[key] = 1
            print key
        }
    }
    ' "$info_file" | sort
}

# Collect all targets present in at least one fuzzer
declare -A ALL_TARGETS
for fuzzer in "${FUZZERS[@]}"; do
    for target_dir in "$ARDIR/$fuzzer"/*/; do
        [ -f "$target_dir/coverage.info" ] || continue
        ALL_TARGETS[$(basename "$target_dir")]=1
    done
done

if [ ${#ALL_TARGETS[@]} -eq 0 ]; then
    echo "[ERROR] No coverage.info files found. Run batch_analyze_coverage.sh first."
    exit 1
fi

echo_time "Fuzzers : ${FUZZERS[*]}"
echo_time "Targets : ${!ALL_TARGETS[*]}"

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

for target in "${!ALL_TARGETS[@]}"; do
    echo_time "--- Target: $target ---"

    TARGET_OUTDIR="$OUTDIR/$target"
    mkdir -p "$TARGET_OUTDIR"

    # Check which fuzzers have coverage.info for this target
    AVAILABLE_FUZZERS=()
    for fuzzer in "${FUZZERS[@]}"; do
        info_file="$ARDIR/$fuzzer/$target/coverage.info"
        if [ -f "$info_file" ]; then
            AVAILABLE_FUZZERS+=("$fuzzer")
        else
            echo_time "  [MISSING] $fuzzer/$target/coverage.info"
        fi
    done

    if [ ${#AVAILABLE_FUZZERS[@]} -lt 2 ]; then
        echo_time "  [SKIP] Need at least 2 fuzzers with coverage.info"
        continue
    fi

    # Step 1: Extract covered branches for each available fuzzer
    for fuzzer in "${AVAILABLE_FUZZERS[@]}"; do
        info_file="$ARDIR/$fuzzer/$target/coverage.info"
        branch_file="$TARGET_OUTDIR/branches_${fuzzer}.txt"
        extract_branches "$info_file" > "$branch_file"
    done

    # Step 2: Build union of all OTHER fuzzers' branches (for each fuzzer)
    # Then exclusive = fuzzer's branches minus that union
    SUMMARY_FILE="$TARGET_OUTDIR/summary.txt"
    > "$SUMMARY_FILE"

    for fuzzer in "${AVAILABLE_FUZZERS[@]}"; do
        branch_file="$TARGET_OUTDIR/branches_${fuzzer}.txt"
        excl_file="$TARGET_OUTDIR/exclusive_${fuzzer}.txt"

        # Union of all other fuzzers' branches
        others_union="$TMPDIR_WORK/others_${fuzzer}.txt"
        > "$others_union"
        for other in "${AVAILABLE_FUZZERS[@]}"; do
            [ "$other" = "$fuzzer" ] && continue
            cat "$TARGET_OUTDIR/branches_${other}.txt"
        done | sort -u > "$others_union"

        # Exclusive = in fuzzer, not in any other
        comm -23 "$branch_file" "$others_union" > "$excl_file"

        TOTAL_BRANCHES=$(wc -l < "$branch_file")
        EXCL_COUNT=$(wc -l < "$excl_file")

        echo_time "  $fuzzer : $TOTAL_BRANCHES branches total, $EXCL_COUNT exclusive"
        printf "%-35s  total: %6d  exclusive: %6d\n" \
            "$fuzzer" "$TOTAL_BRANCHES" "$EXCL_COUNT" >> "$SUMMARY_FILE"
    done

    echo_time "  Results: $TARGET_OUTDIR"
done

echo_time "Comparison complete. Output: $OUTDIR"
