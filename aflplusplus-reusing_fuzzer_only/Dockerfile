# Mirrors angora-reusing_fuzzer_only/Dockerfile's role: FROMs the already
# fully-built target image (compiler toolchain + all 19 unibench targets
# already baked in, expensive, rarely needs to change) and rebuilds *only*
# afl-fuzz itself from a fresh copy of the fuzzer-only sources. Nothing
# here touches instrumentation/ (the LLVM passes afl-clang-fast uses) or
# any of the already-compiled unibench target binaries, so tools/build.sh
# only needs to run this (fast) layer when afl-fuzz*.c / afl-main.c
# change, instead of the full ~20 minute base+target rebuild every single
# fuzzer-logic tweak used to require.
#
# It used to build afl-taint-scan here too -- the C seed-taint pre-pass
# that drove a DFSan-instrumented binary over a corpus. That tool is gone:
# the taint cache -r reads is built by taint_scan (Reusing_mut's
# fuzzer/src/bin/taint_scan.rs), which runs Angora's own pipeline instead
# of re-implementing it.
#
# `make afl-fuzz` is a real, independent GNUmakefile target (see
# AFLplusplus_reusing/GNUmakefile's own rules) -- it only rebuilds its own
# object files plus a handful of shared .o's, never afl-cc/the LLVM
# passes/qemu_mode/etc, so this step is seconds, not minutes.
FROM unifuzz/unibench:aflplusplus-reusing-target

# Fresh copy of just the sources relevant to `make afl-fuzz` (copying the
# whole src/+include/ dirs is simpler than enumerating exact files, and
# harmless: the make target only rebuilds what's actually stale for its
# own dependency graph, regardless of what else got copied in).
COPY src /AFLplusplus/src
COPY include /AFLplusplus/include
COPY GNUmakefile /AFLplusplus/GNUmakefile

# CFLAGS_FLTO= (LTO off) works around a GCC 11 ICE hit repeatedly, and only
# in this Docker build (never in a plain host `make`): "internal compiler
# error: in copy_to_mode_reg, at explow.c" inside XXH3_hashLong_64b_default
# (xxHash, pulled in via afl-performance.c) during LTO's whole-program
# codegen. LTO repartitions which functions land in which LTRANS unit based
# on everything being linked together, so it's sensitive to unrelated
# changes elsewhere -- adding the -r CLI option was enough to move
# XXH3_hashLong_64b_default into a partition that triggers it here,
# consistently, across many retries.
# Also `rm -f` the shared .o's the target image baked in -- those were
# themselves compiled WITH LTO (GIMPLE-bytecode-only objects), so even
# after adding CFLAGS_FLTO= to THIS link, re-using them still drags the
# same buggy codegen back in via the linker. Forcing them to recompile here
# (also without LTO) is what actually fixes it -- confirmed by testing
# CFLAGS_FLTO= alone (reusing the old .o's) still failed 3/3 tries, while
# adding this `rm -f` succeeded 3/3.
RUN cd /AFLplusplus && \
    rm -f src/afl-common.o src/afl-sharedmem.o src/afl-forkserver.o src/afl-performance.o && \
    make CFLAGS_FLTO= afl-fuzz && \
    install -m 755 afl-fuzz "$(command -v afl-fuzz)"
