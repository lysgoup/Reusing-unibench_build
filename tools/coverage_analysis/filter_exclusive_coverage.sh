#!/bin/bash -e

##
# Filter coverage_analysis.txt to keep only inputs that covered
# at least one exclusive branch.
#
# Pre-requirements:
# + $1: COVERAGE_ANALYSIS_TXT - path to coverage_analysis.txt
# + $2: EXCLUSIVE_TXT         - path to exclusive_*.txt
#
# Output:
#   Same directory as COVERAGE_ANALYSIS_TXT:
#   coverage_analysis_exclusive.txt
##

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 COVERAGE_ANALYSIS_TXT EXCLUSIVE_TXT"
    echo "  COVERAGE_ANALYSIS_TXT: path to coverage_analysis.txt"
    echo "  EXCLUSIVE_TXT:         path to exclusive_*.txt"
    exit 1
fi

ANALYSIS_FILE="$(realpath "$1")"
EXCLUSIVE_FILE="$(realpath "$2")"
OUTPUT_FILE="$(dirname "$ANALYSIS_FILE")/coverage_analysis_exclusive.txt"

if [ ! -f "$ANALYSIS_FILE" ]; then
    echo "[ERROR] Not found: $ANALYSIS_FILE"
    exit 1
fi
if [ ! -f "$EXCLUSIVE_FILE" ]; then
    echo "[ERROR] Not found: $EXCLUSIVE_FILE"
    exit 1
fi

awk -v exclusive_file="$EXCLUSIVE_FILE" -v outfile="$OUTPUT_FILE" '
BEGIN {
    while ((getline line < exclusive_file) > 0) {
        exclusive[line] = 1
    }
    close(exclusive_file)
}

# Line 1: seed branch count — always copy as-is
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
' "$ANALYSIS_FILE"

KEPT=$(grep -c '^[0-9]' "$OUTPUT_FILE" 2>/dev/null || echo 0)
TOTAL=$(grep -c '^[0-9]' "$ANALYSIS_FILE" 2>/dev/null || echo 0)
echo "Done. $KEPT / $TOTAL inputs kept → $OUTPUT_FILE"
