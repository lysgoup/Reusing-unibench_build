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

# angora, angora-storfuzz, and angora-reusing-storfuzz all share the exact same
# binary as angora-reusing (they only differ in which --enable-* flags run.sh
# passes at runtime). Whichever of the four is requested, make sure every one
# of these tags points at the same, current angora-reusing image -- so a single
# build invocation, no matter which name it's under, brings all of them back in
# sync instead of leaving the others stale until someone happens to ask for them.
sync_shared_tags() {
    local reusing_id
    reusing_id=$(docker images -q unifuzz/unibench:angora-reusing)
    local tag current_id
    for tag in angora angora-storfuzz angora-reusing-storfuzz; do
        current_id=$(docker images -q "unifuzz/unibench:$tag")
        if [ "$reusing_id" != "$current_id" ]; then
            echo_time "Tagging unifuzz/unibench:$tag to match angora-reusing ($reusing_id)."
            docker tag "unifuzz/unibench:angora-reusing" "unifuzz/unibench:$tag"
        else
            echo_time "unifuzz/unibench:$tag already up to date."
        fi
    done
}

if [ "$FUZZER" = "aflplusplus" ]; then
    echo_time "Smart build for aflplusplus (shares the aflplusplus-reusing image; taint tracking is simply left off at runtime -- see tools/volume/aflplusplus/run.sh, which never sets AFL_DTAINT_BINARY)"
    FUZZER=aflplusplus-reusing "$UNIBENCH/tools/build.sh"
    reusing_id=$(docker images -q unifuzz/unibench:aflplusplus-reusing)
    current_id=$(docker images -q unifuzz/unibench:aflplusplus)
    if [ "$reusing_id" != "$current_id" ]; then
        echo_time "Tagging unifuzz/unibench:aflplusplus to match aflplusplus-reusing ($reusing_id)."
        docker tag unifuzz/unibench:aflplusplus-reusing unifuzz/unibench:aflplusplus
    else
        echo_time "unifuzz/unibench:aflplusplus already up to date."
    fi
elif [ "$FUZZER" = "angora" ] || [ "$FUZZER" = "angora-storfuzz" ] || [ "$FUZZER" = "angora-reusing-storfuzz" ]; then
    echo_time "Smart build for $FUZZER (shares the angora-reusing image; syncing all shared tags)"
    FUZZER=angora-reusing "$UNIBENCH/tools/build.sh"
    sync_shared_tags
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
    sync_shared_tags
elif [ "$FUZZER" = "angora-original" ]; then
    echo_time "Special build for angora-original"
    # angora-reusing과는 독립된 별도 저장소(/home/yunseo/Angora_original)를 소스로 사용.
    ANGORA_ORIGINAL_ROOT="${ANGORA_ORIGINAL_ROOT:-/home/yunseo/Angora_original}"

    if [ ! -d "$ANGORA_ORIGINAL_ROOT" ]; then
        echo_time "ANGORA_ORIGINAL_ROOT ($ANGORA_ORIGINAL_ROOT) not found."
        exit 1
    fi

    # fuzzer, common, llvm_mode 폴더의 해시 계산
    FUZZER_HASH=$(tar -cf - "$ANGORA_ORIGINAL_ROOT/fuzzer" 2>/dev/null | sha256sum | cut -d' ' -f1)
    COMMON_HASH=$(tar -cf - "$ANGORA_ORIGINAL_ROOT/common" 2>/dev/null | sha256sum | cut -d' ' -f1)
    LLVM_HASH=$(tar -cf - "$ANGORA_ORIGINAL_ROOT/llvm_mode" 2>/dev/null | sha256sum | cut -d' ' -f1)

    # 캐시 디렉토리 및 파일 확인 (angora-reusing처럼 소스코드가 있는 곳에 캐시 생성)
    CACHE_DIR="$ANGORA_ORIGINAL_ROOT/_build_cache"
    mkdir -p "$CACHE_DIR"
    CACHED_LLVM_HASH=""
    CACHED_FUZZER_HASH=""
    CACHED_COMMON_HASH=""

    # cache miss only if all hashes are missing
    if [ ! -f "$CACHE_DIR/llvm.hash" ] && [ ! -f "$CACHE_DIR/fuzzer.hash" ] && [ ! -f "$CACHE_DIR/common.hash" ]; then
        echo_time "Cache miss: no hashes found. Full rebuild required."
    else
        [ -f "$CACHE_DIR/llvm.hash" ] && CACHED_LLVM_HASH=$(cat "$CACHE_DIR/llvm.hash")
        [ -f "$CACHE_DIR/fuzzer.hash" ] && CACHED_FUZZER_HASH=$(cat "$CACHE_DIR/fuzzer.hash")
        [ -f "$CACHE_DIR/common.hash" ] && CACHED_COMMON_HASH=$(cat "$CACHE_DIR/common.hash")
    fi

    if [ "$LLVM_HASH" != "$CACHED_LLVM_HASH" ] || [ "$COMMON_HASH" != "$CACHED_COMMON_HASH" ]; then
        echo_time "llvm_mode or common changed. Full rebuild (toolchain base + angora-original-target + fuzzer)."
        set -x
        # 1) toolchain base (LLVM + angora-clang + passes + fuzzer) from Angora_original repo root
        docker build -t "yunseo/angora-original" "$ANGORA_ORIGINAL_ROOT"
        # 2) consolidated target image: all unibench targets rebuilt with Angora_original's angora-clang
        docker build -t "unifuzz/unibench:angora-original-target" -f "$UNIBENCH/angora-original-target/Dockerfile" "$UNIBENCH/../"
        # 3) fuzzer_only: rebuild just the angora_fuzzer binary (from Angora_original source) on top of the target image
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-original_fuzzer_only/Dockerfile" "$ANGORA_ORIGINAL_ROOT"
        set +x
        echo "$LLVM_HASH" > "$CACHE_DIR/llvm.hash"
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
        echo "$COMMON_HASH" > "$CACHE_DIR/common.hash"
    elif [ "$FUZZER_HASH" != "$CACHED_FUZZER_HASH" ]; then
        echo_time "Fuzzer code changed. Rebuilding fuzzer only."
        set -x
        docker build -t "$IMG_NAME" -f "$UNIBENCH/angora-original_fuzzer_only/Dockerfile" "$ANGORA_ORIGINAL_ROOT"
        set +x
        echo "$FUZZER_HASH" > "$CACHE_DIR/fuzzer.hash"
    else
        echo_time "No changes detected. Skipping build."
    fi
elif [ "$FUZZER" = "aflplusplus-reusing" ]; then
    echo_time "Special build for aflplusplus-reusing"
    # Separate repo, like angora-original: this AFL++ fork lives outside
    # $UNIBENCH's own source tree.
    AFLPP_REUSING_ROOT="${AFLPP_REUSING_ROOT:-/home/yunseo/AFLplusplus_reusing}"

    if [ ! -d "$AFLPP_REUSING_ROOT" ]; then
        echo_time "AFLPP_REUSING_ROOT ($AFLPP_REUSING_ROOT) not found."
        exit 1
    fi

    # Same hash-based rebuild-skip caching as angora-reusing above, split
    # along the same fault line: "does this affect how targets get
    # COMPILED" (afl-cc/instrumentation passes/dfsan_legacy toolchain --
    # expensive, rebuilds the base image + all 19 unibench targets) vs
    # "does this only affect the fuzzer ORCHESTRATOR itself"
    # (src/afl-fuzz*.c + afl-main.c -- cheap, only an afl-fuzz rebuild
    # + reinstall via aflplusplus-reusing_fuzzer_only/Dockerfile). Found
    # the hard way: a one-line afl-fuzz.c change (the dryrun_finish
    # marker) was triggering the full ~20 minute base+target rebuild even
    # though not a single unibench target actually depends on afl-fuzz's
    # own source.
    #
    # TOOLCHAIN_HASH deliberately covers "everything except the fuzzer
    # files" (via git ls-files, so build artifacts/.git aren't included)
    # rather than trying to enumerate every toolchain-relevant path --
    # safer default is "unrecognized file changed -> full rebuild" than
    # risking a silently-stale target image.
    FUZZER_FILE_LIST=$(cd "$AFLPP_REUSING_ROOT" && git ls-files | grep -E '^src/afl-fuzz|^src/afl-main\.c$')
    TOOLCHAIN_FILE_LIST=$(cd "$AFLPP_REUSING_ROOT" && git ls-files | grep -vE '^src/afl-fuzz|^src/afl-main\.c$')
    FUZZER_HASH=$(cd "$AFLPP_REUSING_ROOT" && echo "$FUZZER_FILE_LIST" | tar -cf - -T - 2>/dev/null | sha256sum | cut -d' ' -f1)
    TOOLCHAIN_HASH=$(cd "$AFLPP_REUSING_ROOT" && echo "$TOOLCHAIN_FILE_LIST" | tar -cf - -T - 2>/dev/null | sha256sum | cut -d' ' -f1)

    CACHE_DIR="$UNIBENCH/../_build_cache"
    mkdir -p "$CACHE_DIR"
    CACHED_TOOLCHAIN_HASH=""
    CACHED_FUZZER_HASH=""
    [ -f "$CACHE_DIR/aflpp_toolchain.hash" ] && CACHED_TOOLCHAIN_HASH=$(cat "$CACHE_DIR/aflpp_toolchain.hash")
    [ -f "$CACHE_DIR/aflpp_fuzzer.hash" ] && CACHED_FUZZER_HASH=$(cat "$CACHE_DIR/aflpp_fuzzer.hash")

    TARGET_IMG="unifuzz/unibench:aflplusplus-reusing-target"

    if [ "$TOOLCHAIN_HASH" != "$CACHED_TOOLCHAIN_HASH" ] || [ -z "$(docker images -q "$TARGET_IMG")" ]; then
        echo_time "Toolchain/instrumentation/dfsan_legacy changed (or target image missing). Full rebuild (base + all 19 unibench targets + fuzzer)."
        set -x
        # 1) toolchain base: AFL++'s own LLVM 20 build plus the vendored real
        #    DFSan (LLVM 11.1.0) dtaint toolchain -- see AFLplusplus_reusing's
        #    Dockerfile and dfsan_legacy/README.md.
        docker build -t "yunseo/aflplusplus-reusing" "$AFLPP_REUSING_ROOT"
        # 2) target image: unibench targets cross-built fast/ (afl-clang-fast)
        #    + dtaint/ (dfsan_legacy/angora_dfsan_clang.sh).
        docker build -t "$TARGET_IMG" -f "$UNIBENCH/aflplusplus-reusing-target/Dockerfile" "$UNIBENCH/../"
        # 3) fuzzer_only: rebuild just afl-fuzz on top of the target image.
        docker build -t "$IMG_NAME" -f "$UNIBENCH/aflplusplus-reusing_fuzzer_only/Dockerfile" "$AFLPP_REUSING_ROOT"
        set +x
        echo "$TOOLCHAIN_HASH" > "$CACHE_DIR/aflpp_toolchain.hash"
        echo "$FUZZER_HASH" > "$CACHE_DIR/aflpp_fuzzer.hash"
    elif [ "$FUZZER_HASH" != "$CACHED_FUZZER_HASH" ] || [ -z "$(docker images -q "$IMG_NAME")" ]; then
        echo_time "Only afl-fuzz*.c/afl-main.c changed. Rebuilding fuzzer only."
        set -x
        docker build -t "$IMG_NAME" -f "$UNIBENCH/aflplusplus-reusing_fuzzer_only/Dockerfile" "$AFLPP_REUSING_ROOT"
        set +x
        echo "$FUZZER_HASH" > "$CACHE_DIR/aflpp_fuzzer.hash"
    else
        echo_time "No changes detected. Skipping build."
    fi
else
    set -x
    docker build -t "$IMG_NAME" -f "$UNIBENCH/$FUZZER/Dockerfile" "$UNIBENCH/../"
    set +x
fi

echo "$IMG_NAME"