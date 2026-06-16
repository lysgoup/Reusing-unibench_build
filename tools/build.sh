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
    echo_time "Smart build for angora (shares binary with angora-reusing)"
    FUZZER_HASH=$(tar -cf - "$UNIBENCH/../fuzzer" 2>/dev/null | sha256sum | cut -d' ' -f1)
    COMMON_HASH=$(tar -cf - "$UNIBENCH/../common" 2>/dev/null | sha256sum | cut -d' ' -f1)
    LLVM_HASH=$(tar -cf - "$UNIBENCH/../llvm_mode" 2>/dev/null | sha256sum | cut -d' ' -f1)
    # angora-reusing과 동일한 캐시를 참조
    CACHE_DIR="$UNIBENCH/../_build_cache"
    CACHED_LLVM_HASH=$(cat "$CACHE_DIR/llvm.hash" 2>/dev/null || echo "")
    CACHED_FUZZER_HASH=$(cat "$CACHE_DIR/fuzzer.hash" 2>/dev/null || echo "")
    CACHED_COMMON_HASH=$(cat "$CACHE_DIR/common.hash" 2>/dev/null || echo "")

    if [ "$LLVM_HASH" = "$CACHED_LLVM_HASH" ] && \
       [ "$COMMON_HASH" = "$CACHED_COMMON_HASH" ] && \
       [ "$FUZZER_HASH" = "$CACHED_FUZZER_HASH" ] && \
       docker image inspect "$IMG_NAME" &>/dev/null; then
        echo_time "No changes detected. Skipping build."
    else
        echo_time "Changes detected or angora image missing. Building angora-reusing and tagging as angora."
        FUZZER=angora-reusing "$UNIBENCH/tools/build.sh"
        docker tag "unifuzz/unibench:angora-reusing" "$IMG_NAME"
    fi
elif [ "$FUZZER" = "angora-reusing" ]; then
    echo_time "Special build for angora-reusing"
    # fuzzer, common, llvm_mode 폴더의 해시 계산
    FUZZER_HASH=$(tar -cf - "$UNIBENCH/../fuzzer" 2>/dev/null | sha256sum | cut -d' ' -f1)
    COMMON_HASH=$(tar -cf - "$UNIBENCH/../common" 2>/dev/null | sha256sum | cut -d' ' -f1)
    LLVM_HASH=$(tar -cf - "$UNIBENCH/../llvm_mode" 2>/dev/null | sha256sum | cut -d' ' -f1)
    # 캐시 디렉토리 및 파일 확인
    CACHE_DIR="$UNIBENCH/../_build_cache"
    mkdir -p "$CACHE_DIR"
    CACHED_LLVM_HASH=""
    CACHED_FUZZER_HASH=""
    CACHED_COMMON_HASH=""

    # cache miss only if all hashes are missing
    if [ ! -f "$CACHE_DIR/llvm.hash" ] && [ ! -f "$CACHE_DIR/fuzzer.hash" ] && [ ! -f "$CACHE_DIR/common.hash" ]; then
        echo_time "Cache miss: no hashes found. Full rebuild required."
    else
        if [ -f "$CACHE_DIR/llvm.hash" ]; then
            CACHED_LLVM_HASH=$(cat "$CACHE_DIR/llvm.hash")
        fi
        if [ -f "$CACHE_DIR/fuzzer.hash" ]; then
            CACHED_FUZZER_HASH=$(cat "$CACHE_DIR/fuzzer.hash")
        fi
        if [ -f "$CACHE_DIR/common.hash" ]; then
            CACHED_COMMON_HASH=$(cat "$CACHE_DIR/common.hash")
        fi
    fi

    # llvm_mode 또는 common 변경 여부 확인 (둘 다 full rebuild 필요)
    if [ "$LLVM_HASH" != "$CACHED_LLVM_HASH" ] || [ "$COMMON_HASH" != "$CACHED_COMMON_HASH" ]; then
        echo_time "llvm_mode or common changed. Full rebuild from step1."
        set -x
        docker build -t "yunseo/angora-reusing" "$UNIBENCH/../"
        docker build -t "unifuzz/unibench:angora-reusing_step1" "$UNIBENCH/angora-reusing_step1"
        docker build -t "unifuzz/unibench:angora-reusing_step2" "$UNIBENCH/angora-reusing_step2"
        docker build -t "${IMG_NAME}-base" -f "$UNIBENCH/angora-reusing/Dockerfile" "$UNIBENCH/../"
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-reusing_fuzzer_only/Dockerfile" "$UNIBENCH/../"
        set +x
        echo "$LLVM_HASH" > "$CACHE_DIR/llvm.hash"
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
        echo "$COMMON_HASH" > "$CACHE_DIR/common.hash"
    elif [ "$FUZZER_HASH" != "$CACHED_FUZZER_HASH" ]; then
        echo_time "Fuzzer code changed. Rebuilding fuzzer only."
        set -x
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-reusing_fuzzer_only/Dockerfile" "$UNIBENCH/../"
        set +x
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
    else
        echo_time "No changes detected. Skipping build."
    fi
elif [ "$FUZZER" = "angora-storfuzz" ]; then
    echo_time "Smart build for angora with hash-based caching"
    # Angora 내부의 fuzzer, common, llvm_mode 폴더의 해시 계산
    FUZZER_HASH=$(tar -cf - "$UNIBENCH/../Angora_storfuzz/fuzzer" 2>/dev/null | sha256sum | cut -d' ' -f1)
    COMMON_HASH=$(tar -cf - "$UNIBENCH/../Angora_storfuzz/common" 2>/dev/null | sha256sum | cut -d' ' -f1)
    LLVM_HASH=$(tar -cf - "$UNIBENCH/../Angora_storfuzz/llvm_mode" 2>/dev/null | sha256sum | cut -d' ' -f1)
    # 캐시 디렉토리 및 파일 확인
    CACHE_DIR="$UNIBENCH/../Angora_storfuzz/_build_cache"
    mkdir -p "$CACHE_DIR"
    CACHED_LLVM_HASH=""
    CACHED_FUZZER_HASH=""
    CACHED_COMMON_HASH=""

    # cache miss only if all hashes are missing
    if [ ! -f "$CACHE_DIR/llvm.hash" ] && [ ! -f "$CACHE_DIR/fuzzer.hash" ] && [ ! -f "$CACHE_DIR/common.hash" ]; then
        echo_time "Cache miss: no hashes found. Full rebuild required."
    else
        if [ -f "$CACHE_DIR/llvm.hash" ]; then
            CACHED_LLVM_HASH=$(cat "$CACHE_DIR/llvm.hash")
        fi
        if [ -f "$CACHE_DIR/fuzzer.hash" ]; then
            CACHED_FUZZER_HASH=$(cat "$CACHE_DIR/fuzzer.hash")
        fi
        if [ -f "$CACHE_DIR/common.hash" ]; then
            CACHED_COMMON_HASH=$(cat "$CACHE_DIR/common.hash")
        fi
    fi

    # llvm_mode 변경 여부 확인
    if [ "$LLVM_HASH" != "$CACHED_LLVM_HASH" ]; then
        echo_time "llvm_mode changed. Full rebuild from step1."
        set -x
        docker build -t "yunseo/angora-storfuzz" "$UNIBENCH/../Angora_storfuzz"
        docker build -t "unifuzz/unibench:angora-storfuzz_step1" "$UNIBENCH/angora-storfuzz_step1"
        docker build -t "unifuzz/unibench:angora-storfuzz_step2" "$UNIBENCH/angora-storfuzz_step2"
        docker build -t "${IMG_NAME}-base" -f "$UNIBENCH/angora-storfuzz/Dockerfile" "$UNIBENCH/../"
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-storfuzz_fuzzer_only/Dockerfile" "$UNIBENCH/../"
        set +x
        echo "$LLVM_HASH" > "$CACHE_DIR/llvm.hash"
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
        echo "$COMMON_HASH" > "$CACHE_DIR/common.hash"
    elif [ "$FUZZER_HASH" != "$CACHED_FUZZER_HASH" ] || [ "$COMMON_HASH" != "$CACHED_COMMON_HASH" ]; then
        echo_time "Fuzzer or common code changed. Rebuilding fuzzer only."
        set -x
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-storfuzz_fuzzer_only/Dockerfile" "$UNIBENCH/../Angora_storfuzz"
        set +x
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
        echo "$COMMON_HASH" > "$CACHE_DIR/common.hash"
    else
        echo_time "No changes detected. Skipping build."
    fi
else
    set -x
    docker build -t "$IMG_NAME" -f "$UNIBENCH/$FUZZER/Dockerfile" "$UNIBENCH/../"
    set +x
fi

echo "$IMG_NAME"