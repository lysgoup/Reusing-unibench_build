# Mirrors forkserver_libafl_reusing_fuzzer_only/Dockerfile: FROMs the fully
# built target image (AFL++ toolchain, main + cmplog target binaries, all
# expensive and rarely changing) and rebuilds only the fuzzer binary from a
# fresh copy of the sources.
#
# Safe along the same fault line as the reusing arm: the target binaries come
# from src/bin/libafl_cc.rs + src/lib.rs (main) and afl-clang-fast (cmplog),
# and the cmplog pipeline lives entirely in src/main.rs, which only ever ends
# up in the fuzzer binary. tools/build.sh's forkserver_libafl_cmplog branch
# decides which of the two paths to take.
#
# cargo's target/ directory is already inside the image, so this is an
# incremental build.
FROM unifuzz/unibench:forkserver_libafl_cmplog-target

COPY LibAFL_reusing /root/LibAFL-reusing

WORKDIR /root/LibAFL-reusing/fuzzers/cmplog_forkserver_cc
RUN unset CFLAGS CXXFLAGS && \
    export LIBAFL_EDGES_MAP_SIZE_MAX=4194304 && \
    CFLAGS="" CXXFLAGS="" cargo build --release
