#!/bin/bash -e

##
# Compare branch coverage across fuzzers and find exclusively covered branches
#
# For each target that has coverage.info in all specified fuzzers, finds:
#   - Branches covered only by fuzzer A (not any other)
#   - Branches covered only by fuzzer B (not any other)
#   - etc.
#
# Also annotates exclusive_{FUZZER}.txt in place: for every trial under
# ar/{FUZZER}/{TARGET}/*/findings/ that already has a coverage_analysis.txt,
# scans it for the trial-id/input-id that first covered each exclusive
# branch, and appends "{trial}-{id}" markers to that branch's line -- plus
# the mutation operator that produced that input as "{trial}-{id}(mut_op)",
# when that trial also has an analysis_1.csv. Branches with no match yet (no
# trial's coverage_analysis.txt found it) are left unannotated.
#
# Pre-requirements:
# + $1:    WORKDIR   - main experiment directory (contains ar/)
# + $2..N: FUZZERS   - fuzzer names to compare (e.g., angora angora-reusing forkserver_storfuzz)
#
# REQUIRED before running this script:
#   1) find_coverage_increasing_inputs.sh -- run per trial you want annotated
#      into exclusive_{FUZZER}.txt. Without it, this script still computes
#      exclusive_{FUZZER}.txt fine, it just can't annotate branches found
#      only in that trial.
#   2) measure_aggregate_coverage.sh -- run once per WORKDIR. This one is a
#      hard requirement: without coverage.info files, this script exits
#      immediately with an error.
#
# Output: WORKDIR/coverage_comparison/{TARGET}/
#   branches_{FUZZER}.txt    - all covered branches for that fuzzer (sorted, deduplicated)
#   exclusive_{FUZZER}.txt   - branches covered only by that fuzzer, each line
#                              "file:line:block:branch    {trial}-{id}(mut_op)    ..."
#                              (mut_op omitted when that trial has no analysis_1.csv)
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

# Annotate exclusive_file (one "file:line:block:branch" per line) in place:
# append "{trial}-{id}" for every trial-input that covered that branch,
# scanned from each trial's coverage_analysis.txt under trials_dir. If that
# trial also has an analysis_1.csv (new_input_id,parent_input_id,mut_op,...),
# the mutation operator that produced the input is appended too, as
# "{trial}-{id}({mut_op})".
annotate_exclusive() {
    local exclusive_file="$1"
    local trials_dir="$2"
    local annotations output
    annotations=$(mktemp)
    output=$(mktemp)

    for trial_dir in "$trials_dir"/*/; do
        [ -d "$trial_dir" ] || continue
        local trial analysis csv
        trial=$(basename "$trial_dir")
        analysis="$trial_dir/findings/coverage_analysis.txt"
        [ -f "$analysis" ] || continue
        csv="$trial_dir/findings/analysis_1.csv"

        awk -v trial="$trial" -v exclusive_file="$exclusive_file" -v csv="$csv" '
        BEGIN {
            while ((getline line < exclusive_file) > 0) {
                exclusive[line] = 1
            }
            close(exclusive_file)

            # analysis_1.csv: new_input_id,parent_input_id,mut_op,reusing_detail
            # -- optional, only loaded if present.
            if ((getline header < csv) > 0) {
                while ((getline line < csv) > 0) {
                    split(line, f, ",")
                    mut_op[f[1] + 0] = f[3]
                }
            }
            close(csv)
        }
        FNR == 1 { next }
        /^[0-9]/  { current_id = $0; next }
        /^  / {
            branch = substr($0, 3)
            if (branch in exclusive) {
                marker = trial "-" current_id
                # Skip if find_coverage_increasing_inputs.sh already embedded
                # "(mut_op)" into the id line itself -- avoids "(GD)(GD)".
                if (current_id !~ /\(/ && (current_id + 0) in mut_op) {
                    marker = marker "(" mut_op[current_id + 0] ")"
                }
                print branch "\t" marker
            }
        }
        ' "$analysis" >> "$annotations"
    done

    awk -v annotations_file="$annotations" '
    BEGIN {
        while ((getline line < annotations_file) > 0) {
            n = index(line, "\t")
            branch = substr(line, 1, n - 1)
            annotation = substr(line, n + 1)
            if (annot[branch] == "") {
                annot[branch] = annotation
            } else {
                annot[branch] = annot[branch] "    " annotation
            }
        }
        close(annotations_file)
    }
    {
        if ($0 in annot) {
            print $0 "    " annot[$0]
        } else {
            print $0
        }
    }
    ' "$exclusive_file" > "$output"

    mv "$output" "$exclusive_file"
    rm -f "$annotations"
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

        # Annotate exclusive_${fuzzer}.txt in place with which trial-input
        # covered each branch (scans every trial's coverage_analysis.txt
        # under ar/$fuzzer/$target/, if present).
        if [ "$EXCL_COUNT" -gt 0 ]; then
            annotate_exclusive "$excl_file" "$ARDIR/$fuzzer/$target"
            ANNOTATED=$(awk 'NF > 1' "$excl_file" | wc -l)
            echo_time "  $fuzzer : annotated $ANNOTATED/$EXCL_COUNT exclusive branch(es) with trial-input"
        fi
    done

    echo_time "  Results: $TARGET_OUTDIR"
done

echo_time "Comparison complete. Output: $OUTDIR"
