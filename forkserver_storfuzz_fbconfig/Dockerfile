# syntax=docker/dockerfile:1.2
# Build context: $UNIBENCH/../ (COPY paths carry the Reusing-unibench_build/ prefix)
#
# StorFuzz as FuzzBench runs it, on forkserver unibench targets. Standalone:
# nothing here comes from the forkserver_storfuzz image or its fuzzer.
#
#   fuzzer   fuzzers/storfuzz_fuzzbench_in_process, the crate FuzzBench builds,
#            with FuzzBench's storfuzz_dryrun.patch, copied to
#            src/bin/storfuzz_fbconfig.rs and changed from in-process to
#            forkserver by storfuzz_fbconfig.patch. Built with the crate's own
#            Cargo.lock and FuzzBench's build command.
#   targets  compiled by fuzzers/forkserver_libafl_cc's libafl_cc wrapper with
#            storfuzz_forkserver_target.patch: the StorFuzz passes FuzzBench's
#            wrapper adds, and a forkserver runtime that shares the StorFuzz
#            data map. Only the wrapper and runtime are built, not that
#            crate's fuzzer.
FROM rust:1.90.0
LABEL "about"="forkserver_storfuzz_fbconfig: StorFuzz's FuzzBench fuzzer, forkserver"

ENV HOME=/root
ENV IS_DOCKER="1"

ENV LLVM_VERSION=17
ENV LLVM_CONFIG=llvm-config-${LLVM_VERSION}
RUN apt-get update && \
    apt-get install -y \
    build-essential cmake curl git gnupg less \
    libclang-dev libglib2.0-dev \
    lsb-release ninja-build python3 \
    ca-certificates wget unzip \
    gettext autotools-dev pkg-config texinfo nasm \
    gtk-doc-tools libtiff-dev libpng-dev \
    tcl-dev libjpeg-dev daemontools
RUN wget https://apt.llvm.org/llvm.sh && \
    chmod +x llvm.sh && \
    ./llvm.sh ${LLVM_VERSION}

# FuzzBench runs the fuzzer with LD_PRELOAD=libjemalloc.so.2 (fuzzer.py);
# run.sh does the same, and the forkserver target inherits it.
RUN apt-get install -y libjemalloc2

RUN git clone https://github.com/rub-SoftSec/StorFuzz-LibAFL.git /StorFuzz && \
    cd /StorFuzz && \
    git checkout dd13ddb23a946aedc197abe0e451eeed012028f5

# ----- Fuzzer -----
# storfuzz_dryrun.patch is a verbatim copy of
# Reusing-StorFuzz-fuzzbench/fuzzers/storfuzz/storfuzz_dryrun.patch.
COPY Reusing-unibench_build/forkserver_storfuzz_fbconfig/storfuzz_dryrun.patch \
     Reusing-unibench_build/forkserver_storfuzz_fbconfig/storfuzz_fbconfig.patch /
RUN cd /StorFuzz && git apply /storfuzz_dryrun.patch && \
    cp fuzzers/storfuzz_fuzzbench_in_process/src/lib.rs \
       fuzzers/storfuzz_fuzzbench_in_process/src/bin/storfuzz_fbconfig.rs && \
    git apply /storfuzz_fbconfig.patch

# FuzzBench's build command (builder.Dockerfile), with --locked to hold the
# crate's Cargo.lock and only this binary built.
WORKDIR /StorFuzz/fuzzers/storfuzz_fuzzbench_in_process
RUN unset CFLAGS CXXFLAGS && \
    export LIBAFL_EDGES_MAP_SIZE_MAX=4194304 && \
    cargo build --profile release --locked --features no_link_main --bin storfuzz_fbconfig

# ----- Target compiler -----
COPY Reusing-unibench_build/forkserver_storfuzz_fbconfig/storfuzz_forkserver_target.patch /
RUN cd /StorFuzz && git apply /storfuzz_forkserver_target.patch

WORKDIR /StorFuzz/fuzzers/forkserver_libafl_cc
RUN unset CFLAGS CXXFLAGS && \
    export LIBAFL_EDGES_MAP_SIZE_MAX=4194304 && \
    CFLAGS="" CXXFLAGS="" cargo build --release --lib --bin libafl_cc --bin libafl_cxx

WORKDIR /root

# unibench setup
RUN git clone https://github.com/UNIFUZZ/unibench && \
    cd unibench && \
    mkdir mp3gain-1.5.2 && cd mp3gain-1.5.2 && mv ../mp3gain-1.5.2.zip ./ && unzip -q mp3gain-1.5.2.zip && rm mp3gain-1.5.2.zip && cd .. && \
    ls *.zip | xargs -i unzip -q '{}' && \
    ls *.tar.gz | xargs -i tar xf '{}' && \
    rm -r .git/ *.tar.gz *.zip && \
    mv SQLite-8a8ffc86 SQLite-3.8.9 && mv binutils_5279478 binutils-5279478 && mv libtiff-Release-v3-9-7 libtiff-3.9.7 && \
    ls -alh

COPY Reusing-unibench_build/tools/volume/seeds /root/projects/seed_corpus
ENV LIBAFL_CC=/StorFuzz/fuzzers/forkserver_libafl_cc/target/release/libafl_cc
ENV LIBAFL_CXX=/StorFuzz/fuzzers/forkserver_libafl_cc/target/release/libafl_cxx
ENV TARGET_DIR=/root/unibench
ENV SEED_DIR=/root/projects/seed_corpus

RUN mkdir -p /root/projects/targets

# ----- Target compile start ------
# exiv2-0.26
RUN cd $TARGET_DIR/exiv2-0.26 && \
    sed -i '86c\set(GCC_MINOR 0)' CMakeLists.txt && \
    sed -i '/extern int strerror_r/d' src/futils.cpp && \
    cmake \
      -DEXIV2_ENABLE_SHARED=OFF \
      -DEXIV2_ENABLE_NLS=OFF \
      -DCMAKE_C_COMPILER=$LIBAFL_CC \
      -DCMAKE_CXX_COMPILER=$LIBAFL_CXX \
      -DCMAKE_C_FLAGS="-std=gnu99" \
      . && \
    make -j && \
    cp bin/exiv2 /root/projects/targets/

# jasper-2.0.12 / imginfo
RUN cd $TARGET_DIR/jasper-2.0.12 && \
    cmake -DJAS_ENABLE_SHARED=OFF \
    -DALLOW_IN_SOURCE_BUILD=ON \
    -DCMAKE_C_COMPILER=$LIBAFL_CC \
    -DCMAKE_C_FLAGS="-Wno-shift-negative-value -Wno-implicit-function-declaration" \
    . && \
    make -j && \
    cp src/appl/imginfo /root/projects/targets/

# mp3gain-1.5.2
RUN cd $TARGET_DIR/mp3gain-1.5.2 && sed -i 's/CC=/CC?=/' Makefile && \
    make CC=$LIBAFL_CC -j && \
    cp mp3gain /root/projects/targets/

# libtiff-3.9.7 / tiffsplit
RUN cd $TARGET_DIR/libtiff-3.9.7 && \
    ./autogen.sh && \
    CC=$LIBAFL_CC ./configure --disable-shared && \
    make CC=$LIBAFL_CC -j && \
    cp tools/tiffsplit /root/projects/targets/

# flvmeta-1.2.1
RUN cd $TARGET_DIR/flvmeta-1.2.1 && \
    cmake -DCMAKE_C_COMPILER=$LIBAFL_CC . && \
    make -j && \
    cp src/flvmeta /root/projects/targets/

# cflow-1.6
RUN cd $TARGET_DIR/cflow-1.6 && ./configure CC=$LIBAFL_CC CFLAGS="-Wno-incompatible-function-pointer-types" && \
    make CC=$LIBAFL_CC -j && \
    cp src/cflow /root/projects/targets/

# jq-1.5
RUN cd $TARGET_DIR/jq-1.5 && ./configure CC=$LIBAFL_CC --disable-shared && \
    make CC=$LIBAFL_CC -j && \
    cp jq /root/projects/targets/

# xpdf-4.00 / pdftotext
RUN cd $TARGET_DIR/xpdf-4.00 && \
    cmake -DCMAKE_CXX_FLAGS="-std=c++11" \
          -DCMAKE_C_COMPILER=$LIBAFL_CC \
          -DCMAKE_CXX_COMPILER=$LIBAFL_CXX \
          . && \
    make -j && \
    cp xpdf/pdftotext /root/projects/targets/

# SQLite-3.8.9
RUN apt-get install -y tcl-dev && \
    cd $TARGET_DIR/SQLite-3.8.9 && ./configure CC=$LIBAFL_CC --disable-shared --disable-amalgamation && \
    make CC=$LIBAFL_CC -j && \
    cp sqlite3 /root/projects/targets/

# gdk-pixbuf-2.31.1 / gdk-pixbuf-pixdata
# autogen.sh runs autopoint, which the base image doesn't have. Configure
# flags as in aflplusplus-reusing-target.
RUN apt-get install -y autopoint && \
    cd $TARGET_DIR/gdk-pixbuf-2.31.1 && \
    CC=$LIBAFL_CC CXX=$LIBAFL_CXX ./autogen.sh \
      --enable-static=yes --enable-shared=no --with-included-loaders=yes && \
    make -j && \
    cp gdk-pixbuf/gdk-pixbuf-pixdata /root/projects/targets/

# jhead-3.00
RUN cd $TARGET_DIR/jhead-3.00 && \
    make CC=$LIBAFL_CC -j && \
    cp jhead /root/projects/targets/

# lame-3.99.5
RUN cd $TARGET_DIR/lame-3.99.5 && \
    CC=$LIBAFL_CC ./configure --disable-shared && \
    make -j && \
    cp frontend/lame /root/projects/targets/

# swftools-0.9.2 / wav2swf
# Only the two libraries wav2swf links: the bundled xpdf in lib/pdf doesn't
# compile with clang 17 (GlobalParams.cc:925,927, pointer/int comparison),
# and wav2swf never touches it. The two inline fixes are the ones
# aflplusplus-reusing-target and reusing-scanner-target use.
RUN cd $TARGET_DIR/swftools-0.9.2 && \
    CC=$LIBAFL_CC CXX=$LIBAFL_CXX CFLAGS="-fcommon" CXXFLAGS="-fcommon" ./configure && \
    sed -i 's/int inline ActionTagSize/int ActionTagSize/' lib/modules/swfaction.c && \
    sed -i 's/byte inline PaethPredictor/byte PaethPredictor/' src/png2swf.c && \
    make -j -C lib librfxswf.a libbase.a && \
    make -C src wav2swf && \
    cp src/wav2swf /root/projects/targets/

# ncurses-6.1 / tic
RUN cd $TARGET_DIR/ncurses-6.1 && \
    CC=$LIBAFL_CC ./configure --disable-shared --without-cxx && \
    make -j && \
    cp progs/tic /root/projects/targets/

# mujs-1.0.2
RUN cd $TARGET_DIR/mujs-1.0.2 && \
    CC=$LIBAFL_CC build=debug make -j && \
    cp build/debug/mujs /root/projects/targets/

# Bento4-1.5.1-628 / mp42aac
RUN cd $TARGET_DIR/Bento4-1.5.1-628 && \
    cmake -DCMAKE_C_COMPILER=$LIBAFL_CC -DCMAKE_CXX_COMPILER=$LIBAFL_CXX . && \
    make -j && \
    cp mp42aac /root/projects/targets/

# binutils needs flex/bison to regenerate lexer/parser sources
RUN apt-get install -y flex bison

# binutils-5279478 / nm
RUN cd $TARGET_DIR/binutils-5279478 && \
    MAKEINFO=true CC=$LIBAFL_CC ./configure \
      --disable-shared --disable-werror --disable-gdb --disable-gdbserver --disable-gold && \
    for i in bfd libiberty opcodes libctf; do \
        cd $i && MAKEINFO=true CC=$LIBAFL_CC ./configure --disable-shared --disable-werror && make -j && cd ..; \
    done && \
    cd binutils && MAKEINFO=true CC=$LIBAFL_CC ./configure --disable-shared --disable-werror && \
    make nm-new && \
    cp nm-new /root/projects/targets/nm

# binutils-2.28 / objdump
RUN cd $TARGET_DIR/binutils-2.28 && \
    CC=$LIBAFL_CC ./configure --disable-shared LEXLIB= && \
    make -j LEXLIB= && \
    cp binutils/objdump /root/projects/targets/objdump

# libpcap-1.8.1 + tcpdump-4.8.1 / tcpdump
RUN cd $TARGET_DIR/libpcap-1.8.1 && CC=$LIBAFL_CC ./configure --disable-shared && make -j && \
    cd $TARGET_DIR/tcpdump-4.8.1 && \
    CC=$LIBAFL_CC CFLAGS="-Wno-error=implicit-int -Wno-error=implicit-function-declaration" ./configure && \
    make -j && \
    cp tcpdump /root/projects/targets/

# ffmpeg-4.0.1
RUN cd $TARGET_DIR/ffmpeg-4.0.1 && \
    ./configure --disable-doc --disable-shared --cc="$LIBAFL_CC" --cxx="$LIBAFL_CXX" && \
    make -j$(nproc) && \
    cp ffmpeg_g /root/projects/targets/ffmpeg

# ----- Target compile end ------

# Allow non-root users (container runs as host uid) to access /root/
RUN chmod o+x /root && \
    chmod o+rx \
        /StorFuzz/fuzzers/storfuzz_fuzzbench_in_process/target/release/storfuzz_fbconfig \
        /StorFuzz/fuzzers/forkserver_libafl_cc/target/release/libafl_cc \
        /StorFuzz/fuzzers/forkserver_libafl_cc/target/release/libafl_cxx && \
    chmod -R o+rX /root/projects
