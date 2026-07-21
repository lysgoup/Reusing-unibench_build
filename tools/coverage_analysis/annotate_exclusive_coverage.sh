#!/bin/bash -e

##
# Annotate an exclusive branches file with which trial and input first covered each branch.
#
# Pre-requirements:
# + $1: EXCLUSIVE_TXT - path to exclusive_*.txt
# + $2: TRIALS_DIR    - directory containing trial subdirs (0/, 1/, 2/, ...)
#                       each with findings/coverage_analysis.txt
#
# Output:
#   Same directory as EXCLUSIVE_TXT:
#   <original_name>_annotated.txt
#
#   Format per line:
#     /path/file.c:line:block:branch    {trial}-{id}    {trial}-{id} ...
##

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 EXCLUSIVE_TXT TRIALS_DIR"
    echo "  EXCLUSIVE_TXT: path to exclusive_*.txt"
    echo "  TRIALS_DIR:    directory containing trial subdirs (0/, 1/, ...)"
    exit 1
fi

EXCLUSIVE_FILE="$(realpath "$1")"
TRIALS_DIR="$(realpath "$2")"

BASENAME=$(basename "${EXCLUSIVE_FILE%.txt}")
OUTPUT_FILE="$(dirname "$EXCLUSIVE_FILE")/${BASENAME}_annotated.txt"

if [ ! -f "$EXCLUSIVE_FILE" ]; then
    echo "[ERROR] Not found: $EXCLUSIVE_FILE"
    exit 1
fi
if [ ! -d "$TRIALS_DIR" ]; then
    echo "[ERROR] Not found: $TRIALS_DIR"
    exit 1
fi

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

ANNOTATIONS="$TMPDIR_WORK/annotations.txt"
> "$ANNOTATIONS"

# For each trial, scan coverage_analysis.txt and emit "branch\ttrial-id" for exclusive branches
for trial_dir in "$TRIALS_DIR"/*/; do
    [ -d "$trial_dir" ] || continue
    TRIAL=$(basename "$trial_dir")
    ANALYSIS="$trial_dir/findings/coverage_analysis.txt"
    [ -f "$ANALYSIS" ] || { echo "[SKIP] No coverage_analysis.txt in trial $TRIAL"; continue; }

    awk -v trial="$TRIAL" -v exclusive_file="$EXCLUSIVE_FILE" '
    BEGIN {
        while ((getline line < exclusive_file) > 0) {
            exclusive[line] = 1
        }
        close(exclusive_file)
    }
    FNR == 1 { next }
    /^[0-9]/  { current_id = $0; next }
    /^  / {
        branch = substr($0, 3)
        if (branch in exclusive) {
            print branch "\t" trial "-" current_id
        }
    }
    ' "$ANALYSIS" >> "$ANNOTATIONS"
done

# Merge annotations per branch and write annotated output
awk -v annotations_file="$ANNOTATIONS" '
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
' "$EXCLUSIVE_FILE" > "$OUTPUT_FILE"

ANNOTATED=$(awk 'NF > 1' "$OUTPUT_FILE" | wc -l)
TOTAL=$(wc -l < "$OUTPUT_FILE")
echo "Done. $ANNOTATED / $TOTAL branches annotated → $OUTPUT_FILE"
