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
        BUILT_PAIRS+=("${FUZZER}")
    else
        echo_time "Failed to build $IMG_NAME. Check build log for info."
    fi
done

