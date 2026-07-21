#!/bin/bash

##
# One-shot coverage analysis entrypoint (runs inside coverage container)
#
# Mount structure:
#   Host FINDINGS_DIR      → /findings  (queue/ lives here; output written here)
#   Host tools/volume/     → /volume    (targets.conf, etc.)
#
# ENV:
#   TARGET      - target program name
#   SEED_COUNT  - number of initial seed inputs
##

umask 0000
ulimit -c 0

# --- Validate environment ---
if [ -z "${TARGET:-}" ]; then
    echo "[ERROR] TARGET environment variable must be set"
    exit 1
fi
if [ -z "${SEED_COUNT:-}" ]; then
    echo "[ERROR] SEED_COUNT environment variable must be set"
    exit 1
fi

# --- Find queue directory ---
if [ -d /findings/queue ]; then
    QUEUE_DIR="/findings/queue"
elif [ -d /findings/default/queue ]; then
    QUEUE_DIR="/findings/default/queue"
else
    echo "[ERROR] queue directory not found under /findings"
    echo "[INFO]  Contents of /findings:"
    ls -la /findings/ 2>/dev/null || true
    exit 1
fi

# --- Validate tools ---
COVERAGE_BIN="/d/p/cov/${TARGET}"
if [ ! -f "$COVERAGE_BIN" ]; then
    echo "[ERROR] Coverage binary not found: $COVERAGE_BIN"
    echo "[INFO]  Available binaries in /d/p/cov/:"
    ls -la /d/p/cov/ 2>/dev/null || echo "  (directory not found)"
    exit 1
fi

if ! command -v lcov >/dev/null 2>&1; then
    echo "[ERROR] lcov not found in container"
    exit 1
fi

# --- Load target configuration ---
TARGETS_CONF="/volume/targets.conf"
if [ ! -f "$TARGETS_CONF" ]; then
    echo "[ERROR] targets.conf not found at $TARGETS_CONF"
    exit 1
fi
set -a
source "$TARGETS_CONF"
set +a

TARGET_NORMALIZED="${TARGET//-/_}"
target_args_var="${TARGET_NORMALIZED}_args[@]"
target_stdin_var="${TARGET_NORMALIZED}_stdin_from_file"
target_stdin_from_file="${!target_stdin_var:-}"
target_args=("${!target_args_var}")
target_source_var="${TARGET_NORMALIZED}_source_dir"
target_source_dir="${!target_source_var}"

if [ -z "${target_source_dir:-}" ]; then
    echo "[ERROR] No source_dir found for target '$TARGET' in targets.conf"
    exit 1
fi

OUTPUT_FILE="/findings/coverage_analysis.txt"

echo "[INFO] Target       : $TARGET"
echo "[INFO] Coverage bin : $COVERAGE_BIN"
echo "[INFO] Source dir   : $target_source_dir"
echo "[INFO] Queue dir    : $QUEUE_DIR"
echo "[INFO] Seed count   : $SEED_COUNT"
echo "[INFO] Output       : $OUTPUT_FILE"

# --- Helper: run one input file through the coverage binary ---
run_input() {
    local f="$1"
    local tmp
    tmp=$(mktemp)
    cp "$f" "$tmp"

    local cmd_args=()
    for arg in "${target_args[@]}"; do
        if [ "$arg" = "@@" ]; then
            cmd_args+=("$tmp")
        else
            cmd_args+=("$arg")
        fi
    done

    # Run as background job so bash doesn't print signal-death messages
    # (e.g. "Segmentation fault", "Aborted") for crashing inputs.
    # gcov data is not written when the binary crashes, so those inputs
    # simply don't contribute to coverage — the analysis still continues.
    if [ -n "$target_stdin_from_file" ]; then
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" < "$tmp" >/dev/null 2>&1 &
    else
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" >/dev/null 2>&1 &
    fi
    wait $! 2>/dev/null || true

    rm -f "$tmp"
}

# --- Helper: capture lcov data into $1; echo unique covered branch count ---
# Uses awk deduplication (same logic as diff_branches) to avoid double-counting
# branches from headers included by multiple compilation units.
capture_coverage() {
    local out="$1"
    if lcov --capture \
            --directory "$target_source_dir" \
            --output-file "$out" \
            --rc lcov_branch_coverage=1 \
            -q 2>/dev/null; then
        awk '
        /^SF:/ { file = substr($0, 4) }
        /^BRDA:/ {
            split(substr($0, 6), b, ",")
            key = file ":" b[1] ":" b[2] ":" b[3]
            count = b[4]
            if (count != "-" && count+0 > 0 && !(key in covered)) {
                covered[key] = 1
                total++
            }
        }
        END { print total+0 }
        ' "$out"
    else
        echo "0"
    fi
}

# --- Helper: print branches covered in $2 (curr) but not in $1 (prev) ---
# Output format per line: "file:line:block:branch"
# Deduplicates entries that appear multiple times (e.g. inlined header functions).
diff_branches() {
    local prev="$1"
    local curr="$2"
    awk '
    /^SF:/ { file = substr($0, 4) }
    /^BRDA:/ {
        split(substr($0, 6), b, ",")
        key = file ":" b[1] ":" b[2] ":" b[3]
        count = b[4]
        if (FILENAME == ARGV[1]) {
            # Mark covered if ANY section for this key has count > 0
            if (count != "-" && count+0 > 0) prev[key] = 1
            else if (!(key in prev)) prev[key] = 0
        } else {
            pcount = (key in prev) ? prev[key] : 0
            if (pcount == 0 && count != "-" && count+0 > 0 && !(key in seen)) {
                seen[key] = 1
                print key
            }
        }
    }
    ' "$prev" "$curr"
}

# --- Build sorted list of queue files by id ---
mapfile -t ALL_FILES < <(
    find "$QUEUE_DIR" -maxdepth 1 -name 'id:*' -printf '%f\n' 2>/dev/null | \
    sort | \
    while IFS= read -r fname; do echo "$QUEUE_DIR/$fname"; done
)

TOTAL=${#ALL_FILES[@]}
echo "[INFO] Total queue files  : $TOTAL"
echo "[INFO] Seeds (0..N-1)     : $SEED_COUNT"
echo "[INFO] Fuzzer inputs      : $((TOTAL - SEED_COUNT))"

if [ "$TOTAL" -eq 0 ]; then
    echo "[ERROR] No queue files found matching 'id:*' in $QUEUE_DIR"
    exit 1
fi

# Guard against SEED_COUNT > TOTAL
ACTUAL_SEED_COUNT=$SEED_COUNT
if [ "$ACTUAL_SEED_COUNT" -gt "$TOTAL" ]; then
    echo "[WARNING] SEED_COUNT ($SEED_COUNT) > total files ($TOTAL), clamping to $TOTAL"
    ACTUAL_SEED_COUNT=$TOTAL
fi

PREV_INFO=$(mktemp --suffix=.info)
CURR_INFO=$(mktemp --suffix=.info)
trap 'rm -f "$PREV_INFO" "$CURR_INFO"' EXIT

# --- Reset gcov counters ---
echo "[INFO] Resetting gcov counters..."
lcov --zerocounters --directory "$target_source_dir" -q 2>/dev/null || true

# --- Step 1: Run all seeds ---
echo "[INFO] Running $ACTUAL_SEED_COUNT seeds..."
for ((i = 0; i < ACTUAL_SEED_COUNT; i++)); do
    run_input "${ALL_FILES[$i]}"
done

# --- Measure seed (baseline) coverage and write first line immediately ---
echo "[INFO] Measuring seed coverage..."
PREV_BRANCHES=$(capture_coverage "$PREV_INFO")
echo "[INFO] Seed coverage: $PREV_BRANCHES branches"
echo "$PREV_BRANCHES" > "$OUTPUT_FILE"

# --- Step 2: Process fuzzer-generated inputs one by one ---
FUZZ_COUNT=$((TOTAL - ACTUAL_SEED_COUNT))
echo "[INFO] Analyzing $FUZZ_COUNT fuzzer-generated inputs..."

for ((i = ACTUAL_SEED_COUNT; i < TOTAL; i++)); do
    input_file="${ALL_FILES[$i]}"
    filename=$(basename "$input_file")
    id_num=$(echo "$filename" | grep -oP '(?<=id:)\d+' | head -1)

    printf "\r[processing] id:%s" "$id_num"

    run_input "$input_file"

    NEW_BRANCHES=$(capture_coverage "$CURR_INFO")

    if [ "$NEW_BRANCHES" -gt "$PREV_BRANCHES" ]; then
        printf "\n"
        echo "[coverage++] id:$id_num ($PREV_BRANCHES → $NEW_BRANCHES branches)"

        # Write id and new branches to file immediately; also print to terminal
        echo "$id_num" >> "$OUTPUT_FILE"
        while IFS= read -r branch; do
            echo "  $branch" | tee -a "$OUTPUT_FILE"
        done < <(diff_branches "$PREV_INFO" "$CURR_INFO")

        PREV_BRANCHES="$NEW_BRANCHES"
    fi

    # Always sync PREV_INFO to current gcov state for accurate next diff
    cp "$CURR_INFO" "$PREV_INFO"
done

echo "[INFO] Analysis complete."
echo "[INFO] Final branch coverage : $PREV_BRANCHES"
echo "[INFO] Results written to    : $OUTPUT_FILE"
