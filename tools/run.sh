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
export TIMEOUT=${TIMEOUT:-1m}

WORKDIR="$(realpath "$WORKDIR")"
export ARDIR="$WORKDIR/ar"
export CACHEDIR="$WORKDIR/cache"
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

        echo_time "Container unifuzz/unibench:$FUZZER/$TARGET/$ARCID started on CPU $AFFINITY"
        "$UNIBENCH"/tools/start.sh &> \
            "${LOGDIR}/${FUZZER}_${TARGET}_${ARCID}.log"
        echo_time "Container $FUZZER/$TARGET/$ARCID stopped"

        # overwrites empty $ARCID directory with the $SHARED directory
        mv -T "$SHARED" "${CAMPAIGN_ARDIR}/${ARCID}"
    }
    export -f launch_campaign

    while : ; do
        export CAMPAIGN_CACHEDIR="$CACHEDIR/$FUZZER/$TARGET"
        export CACHECID=$(mutex $MUX_CID \
                get_next_cid "$CAMPAIGN_CACHEDIR")
        export CAMPAIGN_ARDIR="$ARDIR/$FUZZER/$TARGET"
        export ARCID=$(mutex $MUX_CID \
                get_next_cid "$CAMPAIGN_ARDIR")

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
        export ARGS="$(get_var_or_default "$FUZZER" "$TARGET" 'ARGS')"
        echo_time "Starting campaigns for $TARGET $ARGS"
        for ((i=0; i<REPEAT; i++)); do
            export NUMWORKERS="$(get_var_or_default "$FUZZER" 'CAMPAIGN_WORKERS')"
            export AFFINITY="$(allocate_workers)"
            start_ex &
        done
    done
done