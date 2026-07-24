# Mirrors angora-reusing_fuzzer_only/Dockerfile's role: FROMs the already
# fully-built target image (compiler toolchain + all 19 unibench targets
# already baked in, expensive, rarely needs to change) and rebuilds *only*
# afl-fuzz itself -- the actual fuzzing orchestrator -- from a fresh copy
# of the fuzzer-only sources. Nothing here touches instrumentation/ (the
# LLVM passes afl-clang-fast uses), dfsan_legacy/ (the real-DFSan
# toolchain), or any of the already-compiled unibench target binaries, so
# tools/build.sh only needs to run this (fast) layer when afl-fuzz*.c/
# afl-main.c change, instead of the full ~20 minute base+target rebuild
# every single fuzzer-logic tweak used to require.
#
# `make afl-fuzz` is a real, independent GNUmakefile target (see
# AFLplusplus_reusing/GNUmakefile's own `afl-fuzz:` rule and
# `AFL_FUZZ_FILES = $(wildcard src/afl-fuzz*.c) src/afl-main.c`) --
# it only rebuilds afl-fuzz's own object files plus a handful of shared
# .o's (afl-common.o/afl-sharedmem.o/afl-forkserver.o/afl-performance.o),
# never afl-cc/the LLVM passes/qemu_mode/etc, so this step is seconds, not
# minutes.
FROM unifuzz/unibench:aflplusplus-reusing-target

# Fresh copy of just the sources relevant to `make afl-fuzz` (copying the
# whole src/+include/ dirs is simpler than enumerating exact files, and
# harmless: `make afl-fuzz` only rebuilds what's actually stale for ITS
# OWN dependency graph, regardless of what else got copied in).
COPY src /AFLplusplus/src
COPY include /AFLplusplus/include
COPY GNUmakefile /AFLplusplus/GNUmakefile

RUN cd /AFLplusplus && \
    make afl-fuzz && \
    install -m 755 afl-fuzz "$(command -v afl-fuzz)"
