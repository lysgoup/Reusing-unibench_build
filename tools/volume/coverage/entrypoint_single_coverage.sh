#!/bin/bash

##
# Single-input HTML coverage report (runs inside coverage container)
#
# Mount structure:
#   Host INPUT_FILE  → /input      (read-only)
#   Host OUTPUT_DIR  → /report
#   Host tools/volume/ → /volume
#
# ENV:
#   TARGET      - target program name
#   COV_TIMEOUT - per-input replay timeout in seconds (default 5)
##

umask 0000
ulimit -c 0

COV_TIMEOUT="${COV_TIMEOUT:-5}"

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

echo "[INFO] Target     : $TARGET"
echo "[INFO] Binary     : $COVERAGE_BIN"
echo "[INFO] Source dir : $target_source_dir"

# Reset gcov counters
echo "[INFO] Resetting gcov counters..."
lcov --zerocounters --directory "$target_source_dir" -q 2>/dev/null || true

# Build command arguments
tmp=$(mktemp)
cp /input "$tmp"

cmd_args=()
for arg in "${target_args[@]}"; do
    [ "$arg" = "@@" ] && cmd_args+=("$tmp") || cmd_args+=("$arg")
done

# Run the single input
echo "[INFO] Running input..."
if [ -n "$target_stdin_from_file" ]; then
    timeout "$COV_TIMEOUT" "$COVERAGE_BIN" "${cmd_args[@]}" < "$tmp" >/dev/null 2>&1 &
else
    timeout "$COV_TIMEOUT" "$COVERAGE_BIN" "${cmd_args[@]}" >/dev/null 2>&1 &
fi
wait $! 2>/dev/null || true
rm -f "$tmp"

# Capture coverage
echo "[INFO] Capturing coverage..."
if ! lcov --capture \
          --directory "$target_source_dir" \
          --output-file /report/single.info \
          --rc lcov_branch_coverage=1 \
          -q 2>/dev/null; then
    echo "[ERROR] lcov capture failed"
    exit 1
fi

# Generate HTML report
echo "[INFO] Generating HTML report..."
genhtml /report/single.info \
        --output-directory /report/html \
        --rc genhtml_branch_coverage=1 \
        --title "${TARGET} - single input coverage" \
        -q

SUMMARY=$(lcov --summary /report/single.info --rc lcov_branch_coverage=1 2>&1)
echo "[INFO] $(echo "$SUMMARY" | grep 'lines')"
echo "[INFO] $(echo "$SUMMARY" | grep 'branches')"
echo "[INFO] $(echo "$SUMMARY" | grep 'functions')"
