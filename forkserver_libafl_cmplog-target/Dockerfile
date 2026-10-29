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
# Only the targets of the current comparisons get a cmplog build; add more
# RUN blocks below, mirroring the pattern, when more are needed.

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

# exiv2-0.26 -- in-source cmake: the main build's CMakeCache.txt pins
# libafl_cc as the compiler, so the cache goes before reconfiguring. The base
# image's source edits (GCC_MINOR, strerror_r) are already in the tree.
RUN cd $TARGET_DIR/exiv2-0.26 && \
    (make clean || true) && rm -rf CMakeCache.txt CMakeFiles && \
    cmake \
      -DEXIV2_ENABLE_SHARED=OFF \
      -DEXIV2_ENABLE_NLS=OFF \
      -DCMAKE_C_COMPILER=afl-clang-fast \
      -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
      -DCMAKE_C_FLAGS="-std=gnu99" \
      . && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp bin/exiv2 /root/projects/targets/cmplog/

# mp3gain-1.5.2 (the base image already made its Makefile take CC from outside)
RUN cd $TARGET_DIR/mp3gain-1.5.2 && \
    (make clean || true) && \
    AFL_LLVM_CMPLOG=1 make CC=afl-clang-fast -j && \
    cp mp3gain /root/projects/targets/cmplog/

# xpdf-4.00 / pdftotext -- in-source cmake, same cache reset as exiv2
RUN cd $TARGET_DIR/xpdf-4.00 && \
    (make clean || true) && rm -rf CMakeCache.txt CMakeFiles && \
    cmake -DCMAKE_CXX_FLAGS="-std=c++11" \
          -DCMAKE_C_COMPILER=afl-clang-fast \
          -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
          . && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp xpdf/pdftotext /root/projects/targets/cmplog/

# mujs-1.0.2
RUN cd $TARGET_DIR/mujs-1.0.2 && \
    (make clean || true) && \
    CC=afl-clang-fast AFL_LLVM_CMPLOG=1 build=debug make -j && \
    cp build/debug/mujs /root/projects/targets/cmplog/
# libtiff-3.9.7 / tiffsplit
RUN cd $TARGET_DIR/libtiff-3.9.7 && \
    (make distclean || make clean || true) && \
    CC=afl-clang-fast ./configure --disable-shared && \
    AFL_LLVM_CMPLOG=1 make CC=afl-clang-fast -j && \
    cp tools/tiffsplit /root/projects/targets/cmplog/

# jhead-3.00
# CC on the make command line, as the main build does: jhead's Makefile
# assigns CC itself, and a makefile assignment beats the environment.
RUN cd $TARGET_DIR/jhead-3.00 && \
    (make clean || true) && \
    AFL_LLVM_CMPLOG=1 make CC=afl-clang-fast -j && \
    cp jhead /root/projects/targets/cmplog/

# flvmeta-1.2.1
# cmake caches the compiler, so the compiler has to be re-pointed here; the
# main build left a CMakeCache naming $LIBAFL_CC.
RUN cd $TARGET_DIR/flvmeta-1.2.1 && \
    (make clean || true) && rm -f CMakeCache.txt && \
    cmake -DCMAKE_C_COMPILER=afl-clang-fast . && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp src/flvmeta /root/projects/targets/cmplog/

# jasper-2.0.12 / imginfo
# Same warning suppressions as the main build: clang 17 errors on these
# without them.
RUN cd $TARGET_DIR/jasper-2.0.12 && \
    (make clean || true) && rm -f CMakeCache.txt && \
    cmake -DJAS_ENABLE_SHARED=OFF \
    -DALLOW_IN_SOURCE_BUILD=ON \
    -DCMAKE_C_COMPILER=afl-clang-fast \
    -DCMAKE_C_FLAGS="-Wno-shift-negative-value -Wno-implicit-function-declaration" \
    . && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp src/appl/imginfo /root/projects/targets/cmplog/

# swftools-0.9.2 / wav2swf -- configure caches the compiler, so it reruns;
# the base image already applied the two inline fixes. Only the two
# libraries wav2swf links, as in the main build.
RUN cd $TARGET_DIR/swftools-0.9.2 && \
    (make clean || true) && \
    CC=afl-clang-fast CXX=afl-clang-fast++ CFLAGS="-fcommon" CXXFLAGS="-fcommon" ./configure && \
    AFL_LLVM_CMPLOG=1 make -j -C lib librfxswf.a libbase.a && \
    AFL_LLVM_CMPLOG=1 make -C src wav2swf && \
    cp src/wav2swf /root/projects/targets/cmplog/

# ncurses-6.1 / tic (infotocap), named tic as the main build is
RUN cd $TARGET_DIR/ncurses-6.1 && \
    (make distclean || make clean || true) && \
    CC=afl-clang-fast ./configure --disable-shared --without-cxx && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp progs/tic /root/projects/targets/cmplog/

# Bento4-1.5.1-628 / mp42aac -- in-source cmake, same cache reset as flvmeta.
# Only the one tool: the main build's `make -j` builds every Bento4 app.
RUN cd $TARGET_DIR/Bento4-1.5.1-628 && \
    (make clean || true) && rm -f CMakeCache.txt && \
    cmake -DCMAKE_C_COMPILER=afl-clang-fast -DCMAKE_CXX_COMPILER=afl-clang-fast++ . && \
    AFL_LLVM_CMPLOG=1 make -j mp42aac && \
    cp mp42aac /root/projects/targets/cmplog/

# binutils-5279478 / nm -- the main build configured each library and
# binutils/ on its own, so each gets its own distclean before the same steps.
RUN cd $TARGET_DIR/binutils-5279478 && \
    for i in bfd libiberty opcodes libctf binutils; do \
        (cd $i && (make distclean || true)); \
    done && \
    (make distclean || true) && \
    MAKEINFO=true CC=afl-clang-fast ./configure \
      --disable-shared --disable-werror --disable-gdb --disable-gdbserver --disable-gold && \
    for i in bfd libiberty opcodes libctf; do \
        cd $i && MAKEINFO=true CC=afl-clang-fast ./configure --disable-shared --disable-werror && \
        AFL_LLVM_CMPLOG=1 make -j && cd ..; \
    done && \
    cd binutils && MAKEINFO=true CC=afl-clang-fast ./configure --disable-shared --disable-werror && \
    AFL_LLVM_CMPLOG=1 make nm-new && \
    cp nm-new /root/projects/targets/cmplog/nm

# binutils-2.28 / objdump
RUN cd $TARGET_DIR/binutils-2.28 && \
    (make distclean || true) && \
    CC=afl-clang-fast ./configure --disable-shared LEXLIB= && \
    AFL_LLVM_CMPLOG=1 make -j LEXLIB= && \
    cp binutils/objdump /root/projects/targets/cmplog/objdump

# libpcap-1.8.1 + tcpdump-4.8.1 / tcpdump -- libpcap is linked in statically,
# so it gets the cmplog build too. Same CFLAGS as the main build.
RUN cd $TARGET_DIR/libpcap-1.8.1 && \
    (make distclean || true) && \
    CC=afl-clang-fast ./configure --disable-shared && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cd $TARGET_DIR/tcpdump-4.8.1 && \
    (make distclean || true) && \
    CC=afl-clang-fast CFLAGS="-Wno-error=implicit-int -Wno-error=implicit-function-declaration" ./configure && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp tcpdump /root/projects/targets/cmplog/

# ffmpeg-4.0.1, named ffmpeg as the main build is
RUN cd $TARGET_DIR/ffmpeg-4.0.1 && \
    (make distclean || true) && \
    ./configure --disable-doc --disable-shared --cc=afl-clang-fast --cxx=afl-clang-fast++ && \
    AFL_LLVM_CMPLOG=1 make -j$(nproc) && \
    cp ffmpeg_g /root/projects/targets/cmplog/ffmpeg

# gdk-pixbuf-2.31.1 / gdk-pixbuf-pixdata -- the base image installed autopoint
RUN cd $TARGET_DIR/gdk-pixbuf-2.31.1 && \
    (make distclean || true) && \
    CC=afl-clang-fast CXX=afl-clang-fast++ ./autogen.sh \
      --enable-static=yes --enable-shared=no --with-included-loaders=yes && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp gdk-pixbuf/gdk-pixbuf-pixdata /root/projects/targets/cmplog/

# --- the fuzzer ---------------------------------------------------------------
# COPYed from the build context, not cloned, for the same reasons as the base
# image: local commits are testable, and docker cannot serve a stale clone.
COPY LibAFL_reusing /root/LibAFL-reusing

WORKDIR /root/LibAFL-reusing/fuzzers/cmplog_forkserver_cc
RUN unset CFLAGS CXXFLAGS && \
    export LIBAFL_EDGES_MAP_SIZE_MAX=4194304 && \
    CFLAGS="" CXXFLAGS="" cargo build --release
