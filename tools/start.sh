#!/bin/bash -e

##
# Pre-requirements:
# - env FUZZER: fuzzer name (from fuzzers/)
# - env TARGET: target name (from targets/) - args automatically loaded from targets.conf
# - env SHARED: path to host-local volume where fuzzer findings are saved
# - env FUZZARGS: fuzzer arguments
# + env TIMEOUT: time to run the campaign (optional - if not set, runs indefinitely)
# + env SEED: path to seed directory (relative or absolute) to mount as /customized_seed
#       (default: no seed volume)
# + env AFFINITY: the CPU to bind the container to (default: no affinity)
# + env ENTRYPOINT: a custom entry point to launch in the container (default:
#       /volume/entrypoint.sh)
##

cleanup() {
    if [ ! -t 1 ]; then
        docker stop $container_id &> /dev/null
        docker rm -f $container_id &> /dev/null
    fi
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM

if [ -z $FUZZER ] || [ -z $TARGET ] || [ -z $SHARED ]; then
    echo '$FUZZER, $TARGET, and $SHARED must be specified as environment variables.'
    exit 1
fi

UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

# TIMEOUT is optional - if not specified, will run until user stops
if [ -z $TIMEOUT ]; then
    echo_time "Note: TIMEOUT not specified, container will run until manually stopped"
fi

# DRYRUN is optional - if set, stop the container as soon as its dry-run
# (initial seed-processing) phase finishes, instead of waiting for TIMEOUT.
# Useful for smoke-testing a build/target.
watch_dryrun() {
    local container_id=$1
    local shared=$2
    while docker inspect -f '{{.State.Running}}' "$container_id" &>/dev/null; do
        if [ -f "$shared/findings/queue/signal/dryrun_finish" ] || \
           [ -f "$shared/findings/default/queue/signal/dryrun_finish" ]; then
            echo_time "dryrun_finish detected, stopping container $container_id"
            docker kill --signal=INT "$container_id" &>/dev/null
            break
        fi
        sleep 3
    done
}

IMG_NAME="unifuzz/unibench:$FUZZER"

if [ ! -z $AFFINITY ]; then
    flag_aff="--cpuset-cpus=$AFFINITY --env=AFFINITY=$AFFINITY"
fi

if [ ! -z "$ENTRYPOINT" ]; then
    flag_ep="--entrypoint=$ENTRYPOINT"
else
    flag_ep="--entrypoint=/volume/entrypoint.sh"
fi

SHARED="$(realpath "$SHARED")"
flag_volume="--volume=$SHARED:/unibench_shared"

if [ ! -z "$SEED" ]; then
    SEED="$(realpath "$SEED")"
    flag_seed_volume="--volume=$SEED:/customized_seed"
    flag_seed_env="--env=SEED=/customized_seed"
fi

# Opt-out toggle for AFL++'s auto-detected dictionary tokens (a_extras) --
# see aflplusplus/no_auto_extras.patch. Default (unset) leaves it on, same
# as upstream AFL++. Only forwarded into the container when set, so an
# unset captainrc var never overrides the patch's own default.
if [ ! -z "$AFL_NO_AUTO_EXTRAS" ]; then
    flag_afl_no_auto_extras="--env=AFL_NO_AUTO_EXTRAS=$AFL_NO_AUTO_EXTRAS"
fi

if [ ! -z "$QUEUE_FILE" ]; then
    QUEUE_FILE="$(realpath "$QUEUE_FILE")"
    flag_queue_volume="--volume=$QUEUE_FILE:/restore/cond_queue.csv:ro"
    flag_queue_env="--env=QUEUE_FILE=/restore/cond_queue.csv"
fi

VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"
flag_volume_extra="--volume=$VOLUME_PATH:/volume"

# Get host user UID/GID to preserve file permissions
if [ -z "$ROOT_MODE" ]; then
    USER_ID=$(id -u)
    GROUP_ID=$(id -g)
    flag_user="-u $USER_ID:$GROUP_ID"
fi

# Container name with timestamp (fuzzer-target-timestamp format)
container_name="${FUZZER}-${TARGET}-$(date +%s%N)"
flag_name="--name=$container_name"

if [ -t 1 ]; then
    echo_time "Running in interactive mode (TTY attached)"
    docker run -it $flag_volume $flag_volume_extra $flag_seed_volume $flag_queue_volume \
        --cap-add=SYS_PTRACE --security-opt seccomp=unconfined --ulimit core=0 \
        --env=FUZZER="$FUZZER" --env=TARGET="$TARGET" \
        --env=FUZZARGS="$FUZZARGS" \
        --env=TIMEOUT="$TIMEOUT" \
        $flag_seed_env $flag_queue_env $flag_afl_no_auto_extras \
        $flag_aff $flag_user $flag_name $flag_ep "$IMG_NAME"
else
    echo_time "Running in non-interactive mode (no TTY)"
    container_id=$(
    docker run -dt $flag_volume $flag_volume_extra $flag_seed_volume $flag_queue_volume \
        --cap-add=SYS_PTRACE --security-opt seccomp=unconfined --ulimit core=0 \
        --env=FUZZER="$FUZZER" --env=TARGET="$TARGET" \
        --env=FUZZARGS="$FUZZARGS" --env=TIMEOUT="$TIMEOUT" \
        $flag_seed_env $flag_queue_env $flag_afl_no_auto_extras \
        --network=none \
        $flag_aff $flag_user $flag_name $flag_ep "$IMG_NAME"
    )
    container_id=$(cut -c-12 <<< $container_id)
    echo_time "Container for $FUZZER/$TARGET started in $container_id"
    docker logs -f "$container_id" &
    if [ "${DRYRUN:-0}" = 1 ]; then
        watch_dryrun "$container_id" "$SHARED" &
    fi
    exit_code=$(docker wait $container_id)
    exit $exit_code
fi