#!/bin/bash -e

##
# Pre-requirements:
# + $1: path to captainrc (default: ./captainrc)
##

if [ -z $1 ]; then
    set -- "./captainrc"
fi

# load the configuration file (captainrc)
set -a
source "$1"
set +a

if [ -z $WORKDIR ] || [ -z $REPEAT ]; then
    echo '$WORKDIR and $REPEAT must be specified as environment variables.'
    exit 1
fi

UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

if [ -z "$WORKER_POOL" ]; then
    # WORKER_POOL을 설정 안했을 때 사용가능한 모든 CPU ID 목록을 WORKER_POOL로 사용
    WORKER_MODE=${WORKER_MODE:-1}
    WORKERS_ALL=($(lscpu -b -p | sed '/^#/d' | sort -u -t, -k ${WORKER_MODE}g | cut -d, -f1))
    WORKERS=${WORKERS:-${#WORKERS_ALL[@]}}
    export WORKER_POOL="${WORKERS_ALL[@]:0:WORKERS}"
fi
# 캠페인 1개가 몇 개의 코어를 사용하는가
export CAMPAIGN_WORKERS=${CAMPAIGN_WORKERS:-1}

export POLL=${POLL:-5}
# TIMEOUT is optional - if not specified, campaigns run indefinitely until user stops
export TIMEOUT="${TIMEOUT}"

if [ -z "$TIMEOUT" ]; then
    echo_time "WARNING: TIMEOUT not specified in captainrc"
    echo_time "Campaigns will run indefinitely until manually stopped (docker stop/kill)"
fi

WORKDIR="$(realpath "$WORKDIR")"
export ARDIR="$WORKDIR/ar"
export CACHEDIR="$WORKDIR/cache"
export COVERAGEDIR="$WORKDIR/coverage"   # must match archive_campaigns.sh
export LOGDIR="$WORKDIR/log"
export POCDIR="$WORKDIR/poc"
export LOCKDIR="$WORKDIR/lock"
mkdir -p "$ARDIR"
mkdir -p "$CACHEDIR"
mkdir -p "$LOGDIR"
mkdir -p "$POCDIR"
mkdir -p "$LOCKDIR"

# 오래된 lock 파일 청소
shopt -s nullglob
rm -f "$LOCKDIR"/*
shopt -u nullglob

export MUX_TAR=unibench_tar
export MUX_CID=unibench_cid

get_next_cid()
{
    ##
    # Pre-requirements:
    # - $1: the directory where campaigns are stored
    ##
    shopt -s nullglob
    campaigns=("$1"/*)
    if [ ${#campaigns[@]} -eq 0 ]; then
        echo 0
        dir="$1/0"
    else
        cids=($(sort -n < <(basename -a "${campaigns[@]}")))
        for ((i=0;;i++)); do
            if [ -z ${cids[i]} ] || [ ${cids[i]} -ne $i ]; then
                echo $i
                dir="$1/$i"
                break
            fi
        done
    fi
    # ensure the directory is created to prevent races
    mkdir -p "$dir"
    while [ ! -d "$dir" ]; do sleep 1; done
}
export -f get_next_cid

mutex()
{
    ##
    # Pre-requirements:
    # - $1: the mutex ID (file descriptor)
    # - $2..N: command to run
    ##
    trap 'rm -f "$LOCKDIR/$mux"' EXIT
    mux=$1
    shift
    (
      flock -xF 200 &> /dev/null
      "${@}"
    ) 200>"$LOCKDIR/$mux"
}
export -f mutex

start_campaign()
{
    launch_campaign()
    {
        export SHARED="$CAMPAIGN_CACHEDIR/$CACHECID"
        mkdir -p "$SHARED" && chmod 777 "$SHARED"

        # Saturation-seed base: install THIS campaign's seed corpus as its
        # iter_0000 baseline, so archive_queue skips the ~100k dry-run queue and
        # archives only post-start deltas. Keyed by SEED (not target), so a
        # per-trial ${TARGET}_SEEDS=(seed0 seed1 ...) array yields a distinct
        # base per trial, while a shared ${TARGET}_SEED is tarred once and
        # hardlinked to every campaign. We are inside launch_campaign, so $SEED
        # and $CACHECID are the ACTUAL pair for this campaign (no trial<->cacheid
        # guessing). flock serializes building the same base once.
        if [ "${SATURATION_MODE:-0}" = 1 ] && [ -n "$SEED" ] && [ -d "$SEED" ]; then
            seed_real="$(realpath "$SEED" 2>/dev/null)"; [ -n "$seed_real" ] || seed_real="$SEED"
            seed_key=$(printf '%s' "$seed_real" | sha1sum | cut -c1-16)
            base_cache="$COVERAGEDIR/_base/$seed_key/iter_0000.tar.gz"
            (
                flock 201
                [ -f "$base_cache" ] || \
                    "$UNIBENCH/tools/make_base_archive.sh" "$SEED" "$base_cache" \
                        >> "${LOGDIR}/make_base_${seed_key}.log" 2>&1
            ) 201>"$LOCKDIR/base_${seed_key}.lock" || true   # a base hiccup must never abort the campaign (set -e)
            camp_arch="$COVERAGEDIR/$FUZZER/$TARGET/$CACHECID/archives"
            mkdir -p "$camp_arch"
            # Tell archive_queue to skip the dry-run queue even if the base build
            # failed, so a failure never degrades iter_0000 into a full-queue dump
            # (which would inflate this trial's baseline vs its siblings).
            : > "$camp_arch/.skip_preloaded"
            if [ -f "$base_cache" ] && \
               { ln -f "$base_cache" "$camp_arch/iter_0000.tar.gz" 2>/dev/null || \
                 cp -f "$base_cache" "$camp_arch/iter_0000.tar.gz"; } && \
               [ -f "$camp_arch/iter_0000.tar.gz" ]; then
                echo_time "Saturation base installed: $FUZZER/$TARGET/$CACHECID/iter_0000 (seed_key=$seed_key)"
            else
                echo_time "ERROR: saturation base MISSING for $FUZZER/$TARGET/$CACHECID (seed=$SEED, seed_key=$seed_key); iter_0000 baseline absent (see make_base_${seed_key}.log)"
            fi
        fi

        echo_time "Container unifuzz/unibench:$FUZZER/$TARGET/$ARCID started on CPU $AFFINITY"
        "$UNIBENCH"/tools/start.sh &> \
            "${LOGDIR}/${FUZZER}_${TARGET}_${ARCID}.log"
        echo_time "Container $FUZZER/$TARGET/$ARCID stopped"

        # overwrites empty $ARCID directory with the $SHARED directory
        mv -T "$SHARED" "${CAMPAIGN_ARDIR}/${ARCID}"
    }
    export -f launch_campaign

    while : ; do
        export CAMPAIGN_ARDIR="$ARDIR/$FUZZER/$TARGET"
        export ARCID=$(mutex $MUX_CID \
                get_next_cid "$CAMPAIGN_ARDIR")
        export CAMPAIGN_CACHEDIR="$CACHEDIR/$FUZZER/$TARGET"
        export CACHECID="$ARCID"

        # Create CACHECID directory, delete if exists
        if [ -d "$CAMPAIGN_CACHEDIR/$CACHECID" ]; then
            rm -rf "$CAMPAIGN_CACHEDIR/$CACHECID"
        fi
        mkdir -p "$CAMPAIGN_CACHEDIR/$CACHECID"

        errno_lock=69
        SHELL=/bin/bash flock -xnF -E $errno_lock "${CAMPAIGN_CACHEDIR}/${CACHECID}" \
            flock -xnF -E $errno_lock "${CAMPAIGN_ARDIR}/${ARCID}" \
                -c launch_campaign || \
        if [ $? -eq $errno_lock ]; then
            continue
        fi
        break
    done
}
export -f start_campaign

start_ex()
{
    release_workers()
    {
        IFS=','
        read -a workers <<< "$AFFINITY"
        unset IFS
        for i in "${workers[@]}"; do
            rm -rf "$LOCKDIR/unibench_cpu_$i"
        done
    }
    trap release_workers EXIT

    start_campaign
    exit 0
}
export -f start_ex

allocate_workers()
{
    ##
    # Pre-requirements:
    # - env NUMWORKERS
    # - env WORKERSET
    ##
    cleanup()
    {
        IFS=','
        read -a workers <<< "$WORKERSET"
        unset IFS
        for i in "${workers[@]:1}"; do
            rm -rf "$LOCKDIR/unibench_cpu_$i"
        done
        exit 0
    }
    trap cleanup SIGINT

    while [ $NUMWORKERS -gt 0 ]; do
        for i in $WORKER_POOL; do
            if ( set -o noclobber; > "$LOCKDIR/unibench_cpu_$i" ) &>/dev/null; then
                export WORKERSET="$WORKERSET,$i"
                export NUMWORKERS=$(( NUMWORKERS - 1 ))
                allocate_workers
                return
            fi
        done
        # This times-out every 1 second to force a refresh, since a worker may
        #   have been released by the time inotify instance is set up.
        inotifywait -qq -t 1 -e delete "$LOCKDIR" &> /dev/null
    done
    cut -d',' -f2- <<< $WORKERSET
}
export -f allocate_workers


# 어떤 이유로든 스크립트 종료시 호출될 함수
cleanup()
{
    trap 'echo Cleaning up...' SIGINT
    echo_time "Waiting for jobs to finish"
    for job in `jobs -p`; do
        if ! wait $job; then
            continue
        fi
    done

    find "$LOCKDIR" -type f | while read lock; do
        if inotifywait -qq -e delete_self "$lock" &> /dev/null; then
            continue
        fi
    done
}
trap cleanup EXIT

# build Docker images
BUILT_FUZZER=()
for FUZZER in "${FUZZERS[@]}"; do
    export FUZZER
    IMG_NAME="unifuzz/unibench:$FUZZER"
    echo_time "Building $IMG_NAME"

    if "$UNIBENCH"/tools/build.sh &> "${LOGDIR}/${FUZZER}_build.log"; then
        BUILT_FUZZER+=("${FUZZER}")
    else
        echo_time "Failed to build $IMG_NAME. Check build log for info."
    fi
done

for FUZZER in "${BUILT_FUZZER[@]}"; do
    export FUZZER
    TARGETS=($(get_var_or_default $FUZZER 'TARGETS'))
    for TARGET in "${TARGETS[@]}"; do
        export TARGET
        export FUZZARGS="$(get_var_or_default "$FUZZER" "$TARGET" 'FUZZARGS')"
        export QUEUE_FILE="$(get_var_or_default "$TARGET" 'QUEUE_FILE')"
        DEFAULT_SEED="$(get_var_or_default "$TARGET" 'SEED')"
        echo_time "Starting campaigns for $TARGET $ARGS"
        for ((i=0; i<REPEAT; i++)); do
            # Per-trial seed: use TARGET_SEEDS[i] if defined, else fall back to TARGET_SEED
            TARGET_NORMALIZED="${TARGET//-/_}"
            seeds_var="${TARGET_NORMALIZED}_SEEDS[@]"
            trial_seeds=("${!seeds_var}")
            if [ ${#trial_seeds[@]} -gt 0 ] && [ -n "${trial_seeds[$i]}" ]; then
                export SEED="${trial_seeds[$i]}"
            else
                export SEED="$DEFAULT_SEED"
            fi
            export NUMWORKERS="$(get_var_or_default "$FUZZER" 'CAMPAIGN_WORKERS')"
            export AFFINITY="$(allocate_workers)"
            start_ex &
        done
    done
done