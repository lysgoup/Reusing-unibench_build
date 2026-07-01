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
        echo_time "llvm_mode or common changed. Full rebuild (toolchain base + angora-reusing-target + fuzzer)."
        set -x
        # 1) toolchain base (LLVM + angora-clang + passes + fuzzer) from repo root
        docker build -t "yunseo/angora-reusing" "$UNIBENCH/../"
        docker tag "yunseo/angora-reusing" "myeonggyu/angora-reusing"
        # 2) consolidated target image: all targets built as fast/ + fast_storfuzz/ + taint/
        docker build -t "unifuzz/unibench:angora-reusing-target" -f "$UNIBENCH/angora-reusing-target/Dockerfile" "$UNIBENCH/../"
        # 3) fuzzer_only: rebuild the single angora_fuzzer binary on top of the target image
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
    echo_time "Smart build for angora-storfuzz (shares the angora-reusing image)"
    # StorFuzz now shares ONE image with angora-reusing. The angora-reusing image
    # also builds StorFuzz-instrumented fast binaries into /d/p/angora/fast_storfuzz/,
    # and the single angora_fuzzer binary enables data coverage at runtime via
    # --enable-storfuzz (see tools/volume/angora-storfuzz/run.sh). So we just build
    # angora-reusing and tag it as angora-storfuzz (same pattern as 'angora').
    FUZZER_HASH=$(tar -cf - "$UNIBENCH/../fuzzer" 2>/dev/null | sha256sum | cut -d' ' -f1)
    COMMON_HASH=$(tar -cf - "$UNIBENCH/../common" 2>/dev/null | sha256sum | cut -d' ' -f1)
    LLVM_HASH=$(tar -cf - "$UNIBENCH/../llvm_mode" 2>/dev/null | sha256sum | cut -d' ' -f1)
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
        echo_time "Changes detected or image missing. Building angora-reusing and tagging as angora-storfuzz."
        FUZZER=angora-reusing "$UNIBENCH/tools/build.sh"
        docker tag "unifuzz/unibench:angora-reusing" "$IMG_NAME"
    fi
elif [ "$FUZZER" = "angora-reusing-storfuzz" ]; then
    echo_time "Smart build for angora-reusing-storfuzz (shares the angora-reusing image)"
    # reusing + StorFuzz combined. Same image as angora-reusing; the run script uses
    # the StorFuzz-instrumented fast_storfuzz/ binaries and passes BOTH
    # --enable-reusing --enable-storfuzz (see tools/volume/angora-reusing-storfuzz/run.sh).
    FUZZER_HASH=$(tar -cf - "$UNIBENCH/../fuzzer" 2>/dev/null | sha256sum | cut -d' ' -f1)
    COMMON_HASH=$(tar -cf - "$UNIBENCH/../common" 2>/dev/null | sha256sum | cut -d' ' -f1)
    LLVM_HASH=$(tar -cf - "$UNIBENCH/../llvm_mode" 2>/dev/null | sha256sum | cut -d' ' -f1)
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
        echo_time "Changes detected or image missing. Building angora-reusing and tagging as angora-reusing-storfuzz."
        FUZZER=angora-reusing "$UNIBENCH/tools/build.sh"
        docker tag "unifuzz/unibench:angora-reusing" "$IMG_NAME"
    fi
else
    set -x
    docker build -t "$IMG_NAME" -f "$UNIBENCH/$FUZZER/Dockerfile" "$UNIBENCH/../"
    set +x
fi

echo "$IMG_NAME"