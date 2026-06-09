#!/bin/bash

##
# Run all seed inputs once and print branch coverage to stdout.
#
# Mount structure:
#   Host SEED_DIR      → /seeds    (read-only, contains id:* files)
#   Host tools/volume/ → /volume
#
# ENV:
#   TARGET - target program name
##

umask 0000
ulimit -c 0

if [ -z "${TARGET:-}" ]; then
    echo "[ERROR] TARGET environment variable must be set"
    exit 1
fi

COVERAGE_BIN="/d/p/cov/${TARGET}"
if [ ! -f "$COVERAGE_BIN" ]; then
    echo "[ERROR] Coverage binary not found: $COVERAGE_BIN"
    ls -la /d/p/cov/ 2>/dev/null || echo "  (directory not found)"
    exit 1
fi

TARGETS_CONF="/volume/targets.conf"
if [ ! -f "$TARGETS_CONF" ]; then
    echo "[ERROR] targets.conf not found"
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

# --- Helper: run one input through the coverage binary ---
run_input() {
    local f="$1"
    local tmp
    tmp=$(mktemp)
    cp "$f" "$tmp"

    local cmd_args=()
    for arg in "${target_args[@]}"; do
        [ "$arg" = "@@" ] && cmd_args+=("$tmp") || cmd_args+=("$arg")
    done

    if [ -n "$target_stdin_from_file" ]; then
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" < "$tmp" >/dev/null 2>&1 &
    else
        timeout 1 "$COVERAGE_BIN" "${cmd_args[@]}" >/dev/null 2>&1 &
    fi
    wait $! 2>/dev/null || true
    rm -f "$tmp"
}

# --- Collect seed files ---
mapfile -t ALL_FILES < <(
    find /seeds -maxdepth 1 -name 'id:*' -printf '%f\n' 2>/dev/null | \
    sort | \
    while IFS= read -r fname; do echo "/seeds/$fname"; done
)

TOTAL=${#ALL_FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "[ERROR] No seed files (id:*) found in /seeds"
    exit 1
fi

echo "[INFO] Target     : $TARGET"
echo "[INFO] Binary     : $COVERAGE_BIN"
echo "[INFO] Source dir : $target_source_dir"
echo "[INFO] Seed files : $TOTAL"
echo ""

# --- Reset gcov counters ---
lcov --zerocounters --directory "$target_source_dir" -q 2>/dev/null || true

# --- Run all seeds ---
for ((i = 0; i < TOTAL; i++)); do
    printf "\r[%d/%d] running seeds..." "$((i + 1))" "$TOTAL"
    run_input "${ALL_FILES[$i]}"
done
printf "\n\n"

# --- Capture coverage ---
INFO=$(mktemp --suffix=.info)
trap 'rm -f "$INFO"' EXIT

if ! lcov --capture \
          --directory "$target_source_dir" \
          --output-file "$INFO" \
          --rc lcov_branch_coverage=1 \
          -q 2>/dev/null; then
    echo "[ERROR] lcov capture failed"
    exit 1
fi

# --- Count unique covered branches (dedup across compilation units) ---
BRANCHES=$(awk '
/^SF:/ { file = substr($0, 4) }
/^BRDA:/ {
    split(substr($0, 6), b, ",")
    key = file ":" b[1] ":" b[2] ":" b[3]
    if (b[4] != "-" && b[4]+0 > 0 && !(key in covered)) {
        covered[key] = 1
        total++
    }
}
END { print total+0 }
' "$INFO")

# --- Print results ---
SUMMARY=$(lcov --summary "$INFO" --rc lcov_branch_coverage=1 2>&1)

echo "===== Coverage Results ====="
echo "  Branches covered : $BRANCHES"
echo "  $(echo "$SUMMARY" | grep 'lines'    | sed 's/^ *//')"
echo "  $(echo "$SUMMARY" | grep 'branches' | sed 's/^ *//')"
echo "  $(echo "$SUMMARY" | grep 'functions'| sed 's/^ *//')"
echo "============================"
