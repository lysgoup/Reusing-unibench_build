#!/bin/bash -e

##
# Compare branch coverage across fuzzers and find exclusively covered branches
#
# For each target that has coverage.info in all specified fuzzers, finds:
#   - Branches covered only by fuzzer A (not any other)
#   - Branches covered only by fuzzer B (not any other)
#   - etc.
#
# Also filters per-trial results: for every trial under
# ar/{FUZZER}/{TARGET}/*/findings/ that already has a coverage_analysis.txt,
# keeps only the inputs that covered at least one of that fuzzer's freshly
# computed exclusive branches, writing coverage_analysis_exclusive.txt right
# there. Trials without a coverage_analysis.txt yet are silently skipped.
#
# Pre-requirements:
# + $1:    WORKDIR   - main experiment directory (contains ar/)
# + $2..N: FUZZERS   - fuzzer names to compare (e.g., angora angora-reusing forkserver_storfuzz)
#
# REQUIRED before running this script:
#   1) find_coverage_increasing_inputs.sh -- run per trial you want a
#      coverage_analysis_exclusive.txt for. Without it, this script still
#      computes exclusive_{FUZZER}.txt fine, it just has nothing to filter
#      for that trial.
#   2) measure_aggregate_coverage.sh -- run once per WORKDIR. This one is a
#      hard requirement: without coverage.info files, this script exits
#      immediately with an error.
#
# Output: WORKDIR/coverage_comparison/{TARGET}/
#   branches_{FUZZER}.txt    - all covered branches for that fuzzer (sorted, deduplicated)
#   exclusive_{FUZZER}.txt   - branches covered only by that fuzzer
#   summary.txt              - per-fuzzer branch counts and exclusive counts
# Output: ar/{FUZZER}/{TARGET}/{TRIAL}/findings/coverage_analysis_exclusive.txt
#   (one per trial that already had a coverage_analysis.txt)
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

# Filter one trial's coverage_analysis.txt to keep only the input blocks that
# covered at least one branch listed in exclusive_file. Writes
# coverage_analysis_exclusive.txt next to analysis_file.
filter_exclusive() {
    local analysis_file="$1"
    local exclusive_file="$2"
    local output_file
    output_file="$(dirname "$analysis_file")/coverage_analysis_exclusive.txt"

    awk -v exclusive_file="$exclusive_file" -v outfile="$output_file" '
    BEGIN {
        while ((getline line < exclusive_file) > 0) {
            exclusive[line] = 1
        }
        close(exclusive_file)
    }

    # Line 1: seed branch count -- always copy as-is
    FNR == 1 {
        print > outfile
        next
    }

    # Input id line (no leading whitespace)
    /^[0-9]/ {
        # Flush previous block if it had at least one exclusive branch
        if (current_id != "" && has_exclusive) {
            print current_id > outfile
            for (i = 1; i <= branch_count; i++) {
                print branches[i] > outfile
            }
        }
        current_id = $0
        has_exclusive = 0
        branch_count = 0
        next
    }

    # Branch line (two leading spaces)
    /^  / {
        branch_count++
        branches[branch_count] = $0
        branch = substr($0, 3)
        if (branch in exclusive) has_exclusive = 1
        next
    }

    END {
        if (current_id != "" && has_exclusive) {
            print current_id > outfile
            for (i = 1; i <= branch_count; i++) {
                print branches[i] > outfile
            }
        }
    }
    ' "$analysis_file"
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
    echo "[ERROR] No coverage.info files found. Run measure_aggregate_coverage.sh first."
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

        # Auto-chain: filter every trial's coverage_analysis.txt (if it
        # already exists) against this fuzzer's exclusive branches.
        FILTERED=0
        for trial_analysis in "$ARDIR/$fuzzer/$target"/*/findings/coverage_analysis.txt; do
            [ -f "$trial_analysis" ] || continue
            filter_exclusive "$trial_analysis" "$excl_file"
            FILTERED=$((FILTERED + 1))
        done
        [ "$FILTERED" -gt 0 ] && echo_time "  $fuzzer : filtered $FILTERED trial(s) -> coverage_analysis_exclusive.txt"
    done

    echo_time "  Results: $TARGET_OUTDIR"
done

echo_time "Comparison complete. Output: $OUTDIR"
