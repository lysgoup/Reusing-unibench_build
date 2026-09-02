#!/bin/bash -e

##
# Merge queue files across ALL fuzzers (and all run/campaign ids) for each
# target into one deduplicated seed corpus per target. Uses SHA-256 hashing
# to eliminate duplicate inputs, same as merge_saturated_seed.sh.
#
# Unlike merge_saturated_seed.sh (single fuzzer/target, trials 0-4 under a
# path you specify directly) or merge_trial0_cross_fuzzer.sh (you list the
# queue dirs by hand), this one takes a single WORKDIR-style base dir (e.g.
# a day1/ produced by archive_campaigns.sh + run.sh), auto-discovers every
# target under <base_dir>/ar/*/<target>, and for each target merges the
# queues from every fuzzer x every run id found for that target.
#
# Usage: $0 <base_dir> [-t TARGET[,TARGET...]]
# Example: $0 /home/projects/reusing/seed/saturation_parallel/day1
#          $0 /home/projects/reusing/seed/saturation_parallel/day2 -t exiv2,imginfo
#
#   -t TARGET   (opt): only merge these targets (comma-separated). Default:
#                every target found under <base_dir>/ar/*. Useful while a
#                campaign is still running and only some targets are fully
#                done across all fuzzers yet -- a target still mid-run for one
#                fuzzer won't have moved into ar/ for that fuzzer yet, so an
#                unfiltered run would silently merge it with that fuzzer
#                missing; -t lets you restrict to the targets you know are
#                actually finished everywhere.
#
# Expects: <base_dir>/ar/<fuzzer>/<target>/<run_id>/findings/queue
#       or: <base_dir>/ar/<fuzzer>/<target>/<run_id>/findings/default/queue
# Output:  <base_dir>/saturated_seed/<target>/id:NNNNNN  (one dir per target,
#          merged across every fuzzer/run_id that has that target)
##

TARGET_FILTER=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        -t) TARGET_FILTER="$2"; shift 2 ;;
        -h|--help) POSITIONAL=() ; break ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ -z "$1" ]; then
    echo "Usage: $0 <base_dir> [-t TARGET[,TARGET...]]"
    echo "  e.g. $0 /home/projects/reusing/seed/saturation_parallel/day1"
    echo "       $0 /home/projects/reusing/seed/saturation_parallel/day2 -t exiv2,imginfo"
    exit 1
fi

BASE_DIR="$(realpath "$1")"
AR_DIR="$BASE_DIR/ar"
DEST_BASE="$BASE_DIR/saturated_seed"

if [ ! -d "$AR_DIR" ]; then
    echo "Error: ar directory not found: $AR_DIR"
    exit 1
fi

mkdir -p "$DEST_BASE"

declare -A all_targets
if [ -n "$TARGET_FILTER" ]; then
    IFS=',' read -ra _filter_list <<< "$TARGET_FILTER"
    for t in "${_filter_list[@]}"; do
        all_targets["$t"]=1
    done
else
    # Discover every target across every fuzzer (union of basenames).
    shopt -s nullglob
    for fuzzer_dir in "$AR_DIR"/*; do
        [ -d "$fuzzer_dir" ] || continue
        for target_dir in "$fuzzer_dir"/*; do
            [ -d "$target_dir" ] || continue
            all_targets["$(basename "$target_dir")"]=1
        done
    done
    shopt -u nullglob
fi

if [ "${#all_targets[@]}" -eq 0 ]; then
    echo "Error: no targets found under $AR_DIR"
    exit 1
fi

for target in "${!all_targets[@]}"; do
    dest="$DEST_BASE/$target"
    mkdir -p "$dest"

    declare -A seen_hashes
    counter=0
    total=0

    shopt -s nullglob
    for fuzzer_dir in "$AR_DIR"/*; do
        [ -d "$fuzzer_dir" ] || continue
        fuzzer="$(basename "$fuzzer_dir")"
        target_path="$fuzzer_dir/$target"
        [ -d "$target_path" ] || continue

        for run_dir in "$target_path"/*; do
            [ -d "$run_dir" ] || continue

            # AFL++-style output puts the queue under findings/default/queue
            # (the "default" fuzzer-instance name), not findings/queue --
            # same fallback run.sh/merge_saturated_seed.sh use.
            queue_dir="$run_dir/findings/queue"
            [ -d "$queue_dir" ] || queue_dir="$run_dir/findings/default/queue"
            [ -d "$queue_dir" ] || continue

            for f in "$queue_dir"/id:*; do
                [[ -f "$f" ]] || continue
                total=$((total + 1))
                hash=$(sha256sum "$f" | cut -d' ' -f1)
                if [[ -z "${seen_hashes[$hash]+x}" ]]; then
                    seen_hashes[$hash]=1
                    printf -v new_name "id:%06d" $counter
                    cp "$f" "$dest/$new_name"
                    counter=$((counter + 1))
                fi
            done
        done
    done
    shopt -u nullglob

    duplicates=$((total - counter))
    echo "Target      : $target"
    echo "Output dir  : $dest"
    echo "Total inputs: $total"
    echo "Unique files: $counter"
    echo "Duplicates  : $duplicates"
    echo

    unset seen_hashes
done
