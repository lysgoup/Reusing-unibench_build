#!/bin/bash -e

##
# Pre-requirements:
# - env FUZZER: fuzzer name (from fuzzers/)
# + env UNIBENCH: path to magma root (default: ../../)
##

if [ -z "$FUZZER" ]; then
    echo '$FUZZER must be specified as environment variables.'
    exit 1
fi

IMG_NAME="unifuzz/unibench:$FUZZER"
UNIBENCH=${UNIBENCH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../" >/dev/null 2>&1 && pwd)"}
source "$UNIBENCH/tools/common.sh"

# angora and angora-reusing require special handling
if [ "$FUZZER" = "angora" ]; then
    echo_time "Multi-step build for angora"
    set -x
    docker build -t "unifuzz/unibench:angora_step1" "$UNIBENCH/angora_step1"
    docker build -t "unifuzz/unibench:angora_step2" "$UNIBENCH/angora_step2"
    docker build -t "$IMG_NAME" -f "$UNIBENCH/angora/Dockerfile" "$UNIBENCH/../"
    set +x
elif [ "$FUZZER" = "angora-reusing" ]; then
    echo_time "Special build for angora-reusing"
    # fuzzer와 llvm_mode 폴더의 해시 계산
    FUZZER_HASH=$(tar -cf - "$UNIBENCH/../fuzzer" 2>/dev/null | sha256sum | cut -d' ' -f1)
    LLVM_HASH=$(tar -cf - "$UNIBENCH/../llvm_mode" 2>/dev/null | sha256sum | cut -d' ' -f1)
    # 캐시 디렉토리 및 파일 확인
    CACHE_DIR="$UNIBENCH/../_build_cache"
    if [ ! -d "$CACHE_DIR" ] || [ ! -f "$CACHE_DIR/llvm.hash" ] || [ ! -f "$CACHE_DIR/fuzzer.hash" ]; then
        echo_time "Cache miss: rebuilding from scratch"
        CACHED_LLVM_HASH=""
        CACHED_FUZZER_HASH=""
        mkdir -p "$CACHE_DIR"
    else
        CACHED_LLVM_HASH=$(cat "$CACHE_DIR/llvm.hash")
        CACHED_FUZZER_HASH=$(cat "$CACHE_DIR/fuzzer.hash")
    fi

    # llvm_mode 변경 여부 확인
    if [ "$LLVM_HASH" != "$CACHED_LLVM_HASH" ]; then
        echo_time "llvm_mode changed. Full rebuild from step1."
        set -x
        docker build -t "yunseo/angora-reusing" "$UNIBENCH/../"
        docker build -t "unifuzz/unibench:angora-reusing_step1" "$UNIBENCH/angora-reusing_step1"
        docker build -t "unifuzz/unibench:angora-reusing_step2" "$UNIBENCH/angora-reusing_step2"
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-reusing/Dockerfile" "$UNIBENCH/../"
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-reusing_fuzzer_only/Dockerfile" "$UNIBENCH/../"
        set +x
        echo "$LLVM_HASH" > "$CACHE_DIR/llvm.hash"
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
    elif [ "$FUZZER_HASH" != "$CACHED_FUZZER_HASH" ]; then
        echo_time "Fuzzer code changed. Rebuilding fuzzer only."
        set -x
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-reusing_fuzzer_only/Dockerfile" "$UNIBENCH/../"
        set +x
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
    else
        echo_time "No changes detected. Skipping build."
    fi
else
    set -x
    docker build -t "$IMG_NAME" -f "$UNIBENCH/$FUZZER/Dockerfile" "$UNIBENCH/../"
    set +x
fi

echo "$IMG_NAME"