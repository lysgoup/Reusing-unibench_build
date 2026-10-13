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

# NOTE: aflplusplus (plain, no taint tracking) is its own build:
# aflplusplus/Dockerfile clones upstream AFL++ directly and applies a
# dryrun_finish.patch (mirrors the marker file AFLplusplus_reusing emits),
# so it falls through to the default else-branch below like any other
# $FUZZER directory with a Dockerfile.

# aflplusplus and aflplusplus-autoextras are the exact same image/binary
# (see tools/volume/aflplusplus-autoextras/run.sh -- the only difference is
# a runtime env var, not a build difference). Whichever of the two gets
# built, re-tag the other to match, so building "aflplusplus" doesn't leave
# "aflplusplus-autoextras" stale until someone happens to ask for it.
sync_aflplusplus_tags() {
    local base_id current_id
    base_id=$(docker images -q unifuzz/unibench:aflplusplus)
    current_id=$(docker images -q unifuzz/unibench:aflplusplus-autoextras)
    if [ "$base_id" != "$current_id" ]; then
        echo_time "Tagging unifuzz/unibench:aflplusplus-autoextras to match aflplusplus ($base_id)."
        docker tag "unifuzz/unibench:aflplusplus" "unifuzz/unibench:aflplusplus-autoextras"
    else
        echo_time "unifuzz/unibench:aflplusplus-autoextras already up to date."
    fi
}

if [ "$FUZZER" = "aflplusplus-autoextras" ]; then
    echo_time "Smart build for aflplusplus-autoextras (shares the aflplusplus image)"
    FUZZER=aflplusplus "$UNIBENCH/tools/build.sh"
    sync_aflplusplus_tags
elif [ "$FUZZER" = "aflplusplus" ]; then
    echo_time "Building aflplusplus (also syncing aflplusplus-autoextras tag)"
    set -x
    docker build -t "$IMG_NAME" -f "$UNIBENCH/$FUZZER/Dockerfile" "$UNIBENCH/../"
    set +x
    sync_aflplusplus_tags
elif [ "$FUZZER" = "aflplusplus-reusing" ]; then
    echo_time "Special build for aflplusplus-reusing"
    # The AFL++ fork is the superproject this repo is a submodule of.
    AFLPP_REUSING_ROOT="${AFLPP_REUSING_ROOT:-$UNIBENCH/..}"

    if [ ! -d "$AFLPP_REUSING_ROOT" ]; then
        echo_time "AFLPP_REUSING_ROOT ($AFLPP_REUSING_ROOT) not found."
        exit 1
    fi

    # Hash-based rebuild-skip caching, split along the fault line: "does this affect how targets get
    # COMPILED" (afl-cc/instrumentation passes --
    # expensive, rebuilds the base image + all 19 unibench targets) vs
    # "does this only affect the fuzzer ORCHESTRATOR itself"
    # (src/afl-fuzz*.c + afl-main.c -- cheap, only an afl-fuzz rebuild
    # + reinstall via aflplusplus-reusing_fuzzer_only/Dockerfile). Found
    # the hard way: a one-line afl-fuzz.c change (the dryrun_finish
    # marker) was triggering the full ~20 minute base+target rebuild even
    # though not a single unibench target actually depends on afl-fuzz's
    # own source.
    #
    # include/afl-fuzz.h joined the fuzzer-only list once the reusing-pool
    # work started touching it regularly -- verified first, not assumed:
    # `grep -rl "afl-fuzz\.h" instrumentation/` only turns up a mention in
    # a .md doc comment, nothing instrumentation passes or the compiler-rt
    # runtime actually #include, and this Dockerfile only ever `make
    # afl-fuzz` (never afl-showmap/afl-tmin/custom_mutators, the other
    # things in this repo that do include it) -- so nothing this pipeline
    # builds for a *target* can ever see this header. If that ever stops
    # being true (afl-fuzz.h starts declaring something instrumentation-
    # side code needs), this needs to come back out.
    #
    # include/reusing_*.h joined the same way, same
    # verification: `grep -rl` for each header's own name across the whole
    # repo turns up only src/afl-fuzz-reusing-*.c and afl-fuzz.h/afl-fuzz.c
    # as includers -- nothing under instrumentation/ or elsewhere. Their
    # src/afl-fuzz-reusing-*.c implementations already matched
    # '^src/afl-fuzz' below without needing a separate entry.
    #
    # TOOLCHAIN_HASH deliberately covers "everything except the fuzzer
    # files" (via git ls-files, so build artifacts/.git aren't included)
    # rather than trying to enumerate every toolchain-relevant path --
    # safer default is "unrecognized file changed -> full rebuild" than
    # risking a silently-stale target image.
    FUZZER_FILE_LIST=$(cd "$AFLPP_REUSING_ROOT" && git ls-files | grep -E '^src/afl-fuzz|^src/afl-main\.c$|^include/afl-fuzz\.h$|^include/reusing_')
    TOOLCHAIN_FILE_LIST=$(cd "$AFLPP_REUSING_ROOT" && git ls-files | grep -vE '^src/afl-fuzz|^src/afl-main\.c$|^include/afl-fuzz\.h$|^include/reusing_')
    FUZZER_HASH=$(cd "$AFLPP_REUSING_ROOT" && echo "$FUZZER_FILE_LIST" | tar -cf - -T - 2>/dev/null | sha256sum | cut -d' ' -f1)
    TOOLCHAIN_HASH=$(cd "$AFLPP_REUSING_ROOT" && echo "$TOOLCHAIN_FILE_LIST" | tar -cf - -T - 2>/dev/null | sha256sum | cut -d' ' -f1)

    CACHE_DIR="$AFLPP_REUSING_ROOT/_build_cache"
    mkdir -p "$CACHE_DIR"
    CACHED_TOOLCHAIN_HASH=""
    CACHED_FUZZER_HASH=""
    [ -f "$CACHE_DIR/aflpp_toolchain.hash" ] && CACHED_TOOLCHAIN_HASH=$(cat "$CACHE_DIR/aflpp_toolchain.hash")
    [ -f "$CACHE_DIR/aflpp_fuzzer.hash" ] && CACHED_FUZZER_HASH=$(cat "$CACHE_DIR/aflpp_fuzzer.hash")

    TARGET_IMG="unifuzz/unibench:aflplusplus-reusing-target"

    if [ "$TOOLCHAIN_HASH" != "$CACHED_TOOLCHAIN_HASH" ] || [ -z "$(docker images -q "$TARGET_IMG")" ]; then
        echo_time "Toolchain/instrumentation changed (or target image missing). Full rebuild (base + all 19 unibench targets + fuzzer)."
        set -x
        # 1) toolchain base: AFL++'s own LLVM 20 build -- see
        #    AFLplusplus_reusing's Dockerfile.
        docker build -t "yunseo/aflplusplus-reusing" "$AFLPP_REUSING_ROOT"
        # 2) target image: unibench targets built into fast/ (afl-clang-fast).
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
elif [ "$FUZZER" = "reusing-scanner" ]; then
    # Not a fuzzer: it scans a corpus once and writes the cache afl-fuzz -r
    # reads. Its own repository, a sibling submodule of this one.
    REUSING_SCANNER_ROOT="${REUSING_SCANNER_ROOT:-$UNIBENCH/../Reusing_scanner}"

    if [ ! -d "$REUSING_SCANNER_ROOT" ]; then
        echo_time "REUSING_SCANNER_ROOT ($REUSING_SCANNER_ROOT) not found."
        echo_time "       Set it to wherever Reusing_scanner is checked out."
        exit 1
    fi

    # Both inputs, not just the scanner repo: step 2's Dockerfile and ffmpeg's
    # abilist live here, and editing either would otherwise report "no changes"
    # and hand back a stale target image. One hash, not two -- there is no
    # "only the fuzzer changed" for a scan.
    SCANNER_HASH=$( { cd "$REUSING_SCANNER_ROOT" && git ls-files | tar -cf - -T - 2>/dev/null;
                      cd "$UNIBENCH" && tar -cf - reusing-scanner-target 2>/dev/null; } \
                    | sha256sum | cut -d' ' -f1)

    CACHE_DIR="$REUSING_SCANNER_ROOT/_build_cache"
    mkdir -p "$CACHE_DIR"
    CACHED_SCANNER_HASH=""
    [ -f "$CACHE_DIR/scanner.hash" ] && CACHED_SCANNER_HASH=$(cat "$CACHE_DIR/scanner.hash")

    TARGET_IMG="unifuzz/unibench:reusing-scanner"

    if [ "$SCANNER_HASH" != "$CACHED_SCANNER_HASH" ] || [ -z "$(docker images -q "$TARGET_IMG")" ]; then
        echo_time "Scanner or its toolchain changed (or target image missing). Rebuild."
        set -x
        # 1) toolchain + taint_scan
        docker build -t "reusing-scanner" "$REUSING_SCANNER_ROOT"
        # 2) the unibench targets built with it
        docker build -t "$TARGET_IMG" -f "$UNIBENCH/reusing-scanner-target/Dockerfile" "$UNIBENCH/../"
        set +x
        echo "$SCANNER_HASH" > "$CACHE_DIR/scanner.hash"
    else
        echo_time "No changes detected. Skipping build."
    fi
else
    set -x
    docker build -t "$IMG_NAME" -f "$UNIBENCH/$FUZZER/Dockerfile" "$UNIBENCH/../"
    set +x
fi

echo "$IMG_NAME"