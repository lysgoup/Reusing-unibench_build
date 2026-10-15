# Mirrors aflplusplus-reusing_fuzzer_only/Dockerfile's role: FROMs the already
# fully-built target image (LibAFL toolchain + all unibench targets already
# compiled, expensive, rarely needs to change) and rebuilds *only* the fuzzer
# binary from a fresh copy of the sources.
#
# Safe because of what the reusing work actually touches. The target binaries
# were compiled by libafl_cc and linked against libforkserver_libafl_cc.a,
# which come from fuzzers/reusing_forkserver_cc/src/bin/libafl_cc.rs and
# src/lib.rs. Neither is part of the reusing stage: that lives in
# fuzzers/reusing_core and is wired in from src/main.rs, both of which only
# ever end up in the fuzzer binary. So a change there leaves every compiled
# target valid, and rebuilding them would be ~hours of nothing.
#
# tools/build.sh decides which of the two paths to take, by hashing the two
# groups of files separately -- see its forkserver_libafl_reusing branch. If
# libafl_cc.rs, lib.rs or anything under libafl/ ever starts mattering to the
# fuzzer-only group, that split is what needs fixing, not this file.
#
# cargo's target/ directory is already inside the image, so this is an
# incremental build: a main.rs edit recompiles two crates, not six hundred.
FROM unifuzz/unibench:forkserver_libafl_reusing-target

# Build context is the umbrella repo (see tools/build.sh), the same as the
# target image's, so the fork comes in at the same path it was built from.
COPY LibAFL_reusing /root/LibAFL-reusing

WORKDIR /root/LibAFL-reusing/fuzzers/reusing_forkserver_cc
RUN unset CFLAGS CXXFLAGS && \
    export LIBAFL_EDGES_MAP_SIZE_MAX=4194304 && \
    CFLAGS="" CXXFLAGS="" cargo build --release
