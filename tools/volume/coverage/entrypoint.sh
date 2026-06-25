#!/bin/bash

##
# Offline coverage-over-time measurement (runs inside the coverage container).
#
# Consumes the iter_NNNN.tar.gz snapshots produced by archive_queue.sh during a
# campaign and replays them cumulatively through the gcov-instrumented binary to
# reconstruct the branch-coverage time series the live measurer used to compute
# online -- but here it runs AFTER the campaign, on free cores, so it steals no
# cycles from the fuzzer. Each snapshot index maps to one INTERVAL time bucket.
#
# Key differences from the old live entrypoint.sh:
#   * lcov --summary (cheap) instead of a full genhtml render every interval
#   * configurable, larger per-input timeout (recovers coverage from slow inputs
#     that the old hard `timeout 1` SIGTERM dropped before the gcov atexit flush)
#   * optional CAPTURE_STRIDE to capture every Nth snapshot for very long runs
#   * a single optional genhtml at the very end (FINAL_HTML=1)
#
# Mount structure:
#   Host .../archives        -> /archives      (ro, iter_NNNN.tar.gz)
#   Host output dir          -> /coverage_out
#   Host tools/volume/       -> /volume
#
# ENV:
#   TARGET               (required) target name (targets.conf)
#   MEASUREMENT_INTERVAL (default 900) seconds per snapshot, only for the CSV time axis
#   COV_TIMEOUT          (default 5)   per-input replay timeout in seconds
#   COV_RUNS             (default 8)   times each input is replayed (non-determinism union)
#   CAPTURE_STRIDE       (default 1)   capture coverage every Nth snapshot (last is always captured)
#   FINAL_HTML           (default 0)   if 1, also genhtml the final coverage.info
#
# Non-determinism handling: each input is replayed COV_RUNS times. Because gcov
# accumulates hit counts into the same .gcda, the UNION of branches taken across
# the repeated runs is what gets captured, so order-/uninitialised-/timing-
# dependent branches that a single run would miss are recovered.
#
# Outputs (in /coverage_out):
#   coverage_over_time.csv   rich per-snapshot series (branches/lines/functions)
#   coverage.log             legacy 3-lines-per-snapshot format for plot_coverage.py
#   coverage_final.info      final lcov tracefile
##

umask 0000
ulimit -c 0

if [ -z "${TARGET:-}" ]; then
    echo "[ERROR] TARGET environment variable must be set"
    exit 1
fi

ARCHIVES_DIR="/archives"
OUT_DIR="/coverage_out"
COVERAGE_BIN="/d/p/cov/${TARGET}"
MEASUREMENT_INTERVAL="${MEASUREMENT_INTERVAL:-900}"
COV_TIMEOUT="${COV_TIMEOUT:-5}"
COV_RUNS="${COV_RUNS:-8}"
CAPTURE_STRIDE="${CAPTURE_STRIDE:-1}"
FINAL_HTML="${FINAL_HTML:-0}"

[ -d "$ARCHIVES_DIR" ] || { echo "[ERROR] archives dir not found: $ARCHIVES_DIR"; exit 1; }
[ -f "$COVERAGE_BIN" ] || { echo "[ERROR] coverage binary not found: $COVERAGE_BIN"; ls -la /d/p/cov/ 2>/dev/null; exit 1; }
command -v lcov >/dev/null 2>&1 || { echo "[ERROR] lcov not found in image"; exit 1; }

TARGETS_CONF="/volume/targets.conf"
[ -f "$TARGETS_CONF" ] || { echo "[ERROR] targets.conf not found at $TARGETS_CONF"; exit 1; }
set -a; source "$TARGETS_CONF"; set +a

TARGET_NORMALIZED="${TARGET//-/_}"
target_args_var="${TARGET_NORMALIZED}_args[@]"
target_stdin_var="${TARGET_NORMALIZED}_stdin_from_file"
target_stdin_from_file="${!target_stdin_var:-}"
target_args=( "${!target_args_var}" )
target_source_var="${TARGET_NORMALIZED}_source_dir"
target_source_dir="${!target_source_var}"

# Optional per-target replay timeout override: <target>_cov_timeout in targets.conf
target_cov_timeout_var="${TARGET_NORMALIZED}_cov_timeout"
[ -n "${!target_cov_timeout_var:-}" ] && COV_TIMEOUT="${!target_cov_timeout_var}"

if [ -z "${target_source_dir:-}" ]; then
    echo "[ERROR] No source_dir for target '$TARGET' in targets.conf"
    exit 1
fi
if [ -z "${!target_args_var}" ] && [ "$target_stdin_from_file" != "1" ]; then
    echo "[ERROR] No args for target '$TARGET' and stdin_from_file not set"
    exit 1
fi

cd "$OUT_DIR"
CSV="$OUT_DIR/coverage_over_time.csv"
LOG="$OUT_DIR/offline_coverage.log"

echo "[INFO] Offline coverage for: $TARGET"
echo "[INFO] Binary: $COVERAGE_BIN | source: $target_source_dir"
echo "[INFO] interval=${MEASUREMENT_INTERVAL}s  per-input timeout=${COV_TIMEOUT}s  runs/input=${COV_RUNS}  stride=${CAPTURE_STRIDE}"

run_input() {
    local input_file="$1" tmp
    tmp=$(mktemp)
    cp "$input_file" "$tmp"
    local cmd_args=()
    local arg
    for arg in "${target_args[@]}"; do
        [ "$arg" = "@@" ] && cmd_args+=("$tmp") || cmd_args+=("$arg")
    done
    # Replay the same input COV_RUNS times so non-deterministic coverage is unioned
    # into the accumulating .gcda (see header note).
    local r
    for ((r = 0; r < COV_RUNS; r++)); do
        if [ -n "$target_stdin_from_file" ]; then
            timeout "$COV_TIMEOUT" "$COVERAGE_BIN" "${cmd_args[@]}" < "$tmp" >/dev/null 2>&1 || true
        else
            timeout "$COV_TIMEOUT" "$COVERAGE_BIN" "${cmd_args[@]}" >/dev/null 2>&1 || true
        fi
    done
    rm -f "$tmp"
}

pct() { # covered total -> percentage string
    if [ "${2:-0}" -gt 0 ]; then awk "BEGIN{printf \"%.1f\", $1*100/$2}"; else echo "0.0"; fi
}

# Parse "X of Y" out of an `lcov --summary` line for the given metric keyword.
# Echoes "covered total" (e.g. "40 1300"); "0 0" if not found.
parse_metric() {
    local summary="$1" key="$2"
    echo "$summary" | grep -m1 "$key" | grep -oP '\d+ of \d+' | head -1 | awk '{print $1, $3}'
}

# Reset accumulated counters once; gcov then accumulates across all replays.
lcov --zerocounters --directory "$target_source_dir" -q 2>/dev/null || true

echo "iter,elapsed_seconds,new_inputs,cumulative_inputs,branches_covered,branches_total,branch_pct,lines_covered,lines_total,functions_covered,functions_total" > "$CSV"
: > "$LOG"
# Legacy 3-lines-per-snapshot log consumed by plot_coverage.py (it reads every
# 3rd line for the branch count, so the order lines/functions/branches matters).
LEGACY_LOG="$OUT_DIR/coverage.log"
: > "$LEGACY_LOG"

# Enumerate snapshots in numeric order.
shopt -s nullglob
ARCHIVES=( "$ARCHIVES_DIR"/iter_*.tar.gz )
shopt -u nullglob
if [ "${#ARCHIVES[@]}" -eq 0 ]; then
    echo "[ERROR] no iter_*.tar.gz snapshots found in $ARCHIVES_DIR"
    exit 1
fi
IFS=$'\n' ARCHIVES=( $(printf '%s\n' "${ARCHIVES[@]}" | sort) ); unset IFS
N=${#ARCHIVES[@]}
echo "[INFO] $N snapshots to process"

cumulative=0
last_index=$((N - 1))
idx=0
for archive in "${ARCHIVES[@]}"; do
    base=$(basename "$archive")
    iter=$(echo "$base" | grep -oP '\d+' | head -1)
    iter=$((10#$iter))

    new_inputs=0
    if [ -s "$archive" ]; then
        extract_dir=$(mktemp -d)
        tar xzf "$archive" -C "$extract_dir" 2>/dev/null || true
        while IFS= read -r f; do
            new_inputs=$((new_inputs + 1))
            run_input "$f"
        done < <(find "$extract_dir" -path "*/findings/queue/id:*" -type f 2>/dev/null)
        rm -rf "$extract_dir"
    fi
    cumulative=$((cumulative + new_inputs))

    # Capture on stride boundaries and always on the last snapshot.
    if [ $(( iter % CAPTURE_STRIDE )) -eq 0 ] || [ "$idx" -eq "$last_index" ]; then
        if lcov --capture --directory "$target_source_dir" --output-file coverage.info \
                --rc lcov_branch_coverage=1 -q >/dev/null 2>&1; then
            summary=$(lcov --summary coverage.info --rc lcov_branch_coverage=1 2>&1)
            read -r br_cov br_tot <<< "$(parse_metric "$summary" branches)"
            read -r ln_cov ln_tot <<< "$(parse_metric "$summary" lines)"
            read -r fn_cov fn_tot <<< "$(parse_metric "$summary" functions)"
            br_cov=${br_cov:-0}; br_tot=${br_tot:-0}
            ln_cov=${ln_cov:-0}; ln_tot=${ln_tot:-0}
            fn_cov=${fn_cov:-0}; fn_tot=${fn_tot:-0}
            br_pct="0.0"
            [ "$br_tot" -gt 0 ] && br_pct=$(awk "BEGIN{printf \"%.2f\", $br_cov*100/$br_tot}")
            elapsed=$(( iter * MEASUREMENT_INTERVAL ))
            echo "$iter,$elapsed,$new_inputs,$cumulative,$br_cov,$br_tot,$br_pct,$ln_cov,$ln_tot,$fn_cov,$fn_tot" >> "$CSV"
            # Legacy coverage.log: 3 lines per captured snapshot for plot_coverage.py.
            {
                echo "  lines......: $(pct "$ln_cov" "$ln_tot")% (${ln_cov} of ${ln_tot} lines)"
                echo "  functions..: $(pct "$fn_cov" "$fn_tot")% (${fn_cov} of ${fn_tot} functions)"
                echo "  branches...: $(pct "$br_cov" "$br_tot")% (${br_cov} of ${br_tot} branches)"
            } >> "$LEGACY_LOG"
            echo "[$(date '+%F %T')] iter $iter | +$new_inputs (cum $cumulative) | branches ${br_cov}/${br_tot} (${br_pct}%) | lines ${ln_cov}/${ln_tot}" | tee -a "$LOG"
        else
            echo "[$(date '+%F %T')] iter $iter | lcov capture FAILED" | tee -a "$LOG"
        fi
    fi
    idx=$((idx + 1))
done

# Persist the final tracefile and optionally a single HTML report.
if [ -f coverage.info ]; then
    cp coverage.info "$OUT_DIR/coverage_final.info"
    if [ "$FINAL_HTML" = "1" ]; then
        echo "[INFO] generating final HTML report..."
        genhtml coverage.info --output-directory "$OUT_DIR/html" \
            --rc genhtml_branch_coverage=1 -q 2>/dev/null || true
    fi
fi

echo "[INFO] done -> $CSV"
tail -1 "$CSV"
