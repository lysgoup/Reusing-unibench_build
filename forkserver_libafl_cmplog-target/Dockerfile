# syntax=docker/dockerfile:1.2
# Build context: $UNIBENCH/../ (see tools/build.sh's forkserver_libafl_cmplog
# branch), i.e. COPY paths need the submodule prefix.
#
# forkserver_libafl_cmplog: the baseline forkserver fuzzer plus cmplog
# (RedQueen), nothing else. FROMs the reusing arm's target image so the MAIN
# binaries are the exact ones every other LibAFL arm runs -- same libafl_cc,
# same build flags -- and the only thing added is what cmplog needs:
#
#   * AFL++ (pinned to the same commit as ../aflplusplus/Dockerfile), only
#     for afl-clang-fast: cmplog requires a SECOND, separately-instrumented
#     binary per target, compiled with AFL_LLVM_CMPLOG=1, which libafl_cc
#     cannot produce. The fuzzer points its tracing executor at it via -c.
#   * That second build per campaign target, into /root/projects/targets/cmplog/.
#   * The cmplog_forkserver_cc fuzzer binary.
#
# Only the four targets of the current comparison get a cmplog build; add
# more RUN blocks below, mirroring the pattern, when more are needed.

FROM unifuzz/unibench:forkserver_libafl_reusing-target

# --- AFL++, for afl-clang-fast only ------------------------------------------
# Pinned to the same commit as ../aflplusplus/Dockerfile -- bump deliberately,
# not implicitly via `main`, and keep them in sync if you do.
ARG AFLPP_COMMIT=05507e1880dc6df997c19e01423444ef37c36846

ENV NO_CORESIGHT=1
ENV NO_NYX=1

WORKDIR /AFLplusplus
RUN git clone https://github.com/AFLplusplus/AFLplusplus.git . && \
    git checkout ${AFLPP_COMMIT}

# The base image carries LLVM 17 (libafl_cc's toolchain); afl-clang-fast
# builds against the same one. source-only skips qemu and friends.
RUN LLVM_CONFIG=llvm-config-17 make source-only && \
    LLVM_CONFIG=llvm-config-17 make install

# --- cmplog builds of the campaign targets -----------------------------------
# Same recipes as the main builds in the base image, with afl-clang-fast for
# libafl_cc and AFL_LLVM_CMPLOG=1 on the compile. The sources still hold the
# main build's objects, so each block cleans first. AFL_LLVM_CMPLOG is read
# by afl-clang-fast itself during compilation, not by the build system.
RUN mkdir -p /root/projects/targets/cmplog

# jq-1.5
RUN cd $TARGET_DIR/jq-1.5 && \
    (make distclean || make clean || true) && \
    ./configure CC=afl-clang-fast --disable-shared && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp jq /root/projects/targets/cmplog/

# cflow-1.6
RUN cd $TARGET_DIR/cflow-1.6 && \
    (make distclean || make clean || true) && \
    ./configure CC=afl-clang-fast CFLAGS="-Wno-incompatible-function-pointer-types" && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp src/cflow /root/projects/targets/cmplog/

# SQLite-3.8.9
RUN cd $TARGET_DIR/SQLite-3.8.9 && \
    (make distclean || make clean || true) && \
    CC=afl-clang-fast ./configure --disable-shared --disable-amalgamation && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp sqlite3 /root/projects/targets/cmplog/

# lame-3.99.5
RUN cd $TARGET_DIR/lame-3.99.5 && \
    (make distclean || make clean || true) && \
    CC=afl-clang-fast ./configure --disable-shared && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp frontend/lame /root/projects/targets/cmplog/

# --- the fuzzer ---------------------------------------------------------------
# COPYed from the build context, not cloned, for the same reasons as the base
# image: local commits are testable, and docker cannot serve a stale clone.
COPY LibAFL_reusing /root/LibAFL-reusing

WORKDIR /root/LibAFL-reusing/fuzzers/cmplog_forkserver_cc
RUN unset CFLAGS CXXFLAGS && \
    export LIBAFL_EDGES_MAP_SIZE_MAX=4194304 && \
    CFLAGS="" CXXFLAGS="" cargo build --release
