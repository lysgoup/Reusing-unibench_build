#!/bin/bash -e

##
# Pre-requirements:
# - env FUZZER: fuzzer name (from fuzzers/)
# - env TARGET: target name (from targets/) - args automatically loaded from targets.conf
# - env FUZZARGS: fuzzer arguments
# - env TIMEOUT: time to run the campaign
# + env SHARED: path to host-local volume where fuzzer findings are saved
#       (default: no shared volume)
# + env SEED: path to seed directory (relative or absolute) to mount as /customized_seed
#       (default: no seed volume)
# + env AFFINITY: the CPU to bind the container to (default: no affinity)
# + env ENTRYPOINT: a custom entry point to launch in the container (default:
#       /volume/entrypoint.sh)
##

cleanup() {
    if [ ! -t 1 ]; then
        docker rm -f $container_id &> /dev/null
    fi
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM

if [ -z $FUZZER ] || [ -z $TARGET ] || [ -z $TIMEOUT ] || [ -z $SHARED ]; then
    echo '$FUZZER, $TARGET, $TIMEOUT, and $SHARED must be specified as' \
         'environment variables.'
    exit 1
fi

UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
export UNIBENCH
source "$UNIBENCH/tools/common.sh"

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

VOLUME_PATH="$(realpath "$UNIBENCH/tools/volume")"
flag_volume_extra="--volume=$VOLUME_PATH:/volume"

# Get host user UID/GID to preserve file permissions
USER_ID=$(id -u)
GROUP_ID=$(id -g)
flag_user="-u $USER_ID:$GROUP_ID"

if [ -t 1 ]; then
    echo_time "Running in interactive mode (TTY attached)"
    docker run -it $flag_volume $flag_volume_extra $flag_seed_volume \
        --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
        --env=FUZZER="$FUZZER" --env=TARGET="$TARGET" \
        --env=FUZZARGS="$FUZZARGS" --env=POLL="$POLL" \
        --env=TIMEOUT="$TIMEOUT" \
        $flag_seed_env \
        $flag_aff $flag_user $flag_ep "$IMG_NAME"
else
    echo_time "Running in non-interactive mode (no TTY)"
    container_id=$(
    docker run -dt $flag_volume $flag_volume_extra $flag_seed_volume \
        --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
        --env=FUZZER="$FUZZER" --env=TARGET="$TARGET" \
        --env=FUZZARGS="$FUZZARGS" --env=POLL="$POLL" --env=TIMEOUT="$TIMEOUT" \
        $flag_seed_env \
        --network=none \
        $flag_aff $flag_user $flag_ep "$IMG_NAME"
    )
    container_id=$(cut -c-12 <<< $container_id)
    echo_time "Container for $FUZZER/$TARGET started in $container_id"
    docker logs -f "$container_id" &
    exit_code=$(docker wait $container_id)
    exit $exit_code
fi