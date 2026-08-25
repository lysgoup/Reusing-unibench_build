# syntax=docker/dockerfile:1.2
# Build context: $UNIBENCH/../  (uses default else-branch in build.sh)
# COPY paths are relative to $UNIBENCH/../, i.e. Reusing-unibench_build/ prefix required
FROM rust:1.90.0 AS libafl
LABEL "maintainer"="afl++ team <afl@aflplus.plus>"
LABEL "about"="forkserver_storfuzz: forkserver fuzzer with StorFuzz data-flow coverage"

RUN curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
RUN cargo binstall --no-confirm just
RUN cargo binstall --no-confirm cargo-nextest
RUN cargo binstall -y cargo-fuzz
RUN cargo binstall -y taplo-cli

ENV HOME=/root
ENV IS_DOCKER="1"
RUN sh -c 'echo set encoding=utf-8 > /root/.vimrc' \
  && echo "export PS1='"'[LibAFL \h] \w$(__git_ps1) \$ '"'" >> ~/.bashrc \
  && mkdir ~/.cargo \
  && echo "[build]\nrustc-wrapper = \"${RUSTC_WRAPPER}\"" >> ~/.cargo/config

RUN rustup component add rustfmt clippy
RUN rustup target add armv7-unknown-linux-gnueabi
RUN rustup target add aarch64-unknown-linux-gnu
RUN rustup target add i686-unknown-linux-gnu
RUN rustup target add powerpc-unknown-linux-gnu

ENV LLVM_VERSION=17
ENV LLVM_CONFIG=llvm-config-${LLVM_VERSION}
RUN dpkg --add-architecture i386
RUN apt-get update && \
    apt-get install -y \
    build-essential cmake curl \
    g++-aarch64-linux-gnu g++-arm-linux-gnueabi g++-i686-linux-gnu \
    g++-mipsel-linux-gnu g++-powerpc-linux-gnu \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi gcc-i686-linux-gnu \
    gcc-mipsel-linux-gnu gcc-powerpc-linux-gnu gcc-riscv64-linux-gnu \
    gdb gdb-multiarch git gnupg less \
    libc6-dev:i386 libclang-dev libglib2.0-dev \
    lsb-release ninja-build python3 python3-pip python3-venv \
    ca-certificates wget \
    gettext autotools-dev pkg-config texinfo nasm \
    libglib2.0-dev gtk-doc-tools libtiff-dev libpng-dev \
    tcl-dev libjpeg-dev daemontools

RUN set -ex && \
    wget https://apt.llvm.org/llvm.sh && \
    chmod +x llvm.sh && \
    ./llvm.sh ${LLVM_VERSION}

RUN apt-get update && apt-get install -y clang-format-${LLVM_VERSION}

WORKDIR /root

# Build LibAFL-Stats
RUN git clone https://github.com/rub-SoftSec/StorFuzz-LibAFL.git /StorFuzz && \
    cd /StorFuzz && \
    git checkout dd13ddb23a946aedc197abe0e451eeed012028f5

# 이 부분 추가
COPY Reusing-unibench_build/forkserver_storfuzz/storfuzz.patch /
RUN cd /StorFuzz && git apply /storfuzz.patch

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
ENV FUZZER=/StorFuzz/fuzzers/forkserver_libafl_cc/target/release/forkserver_libafl_cc
ENV TARGET_DIR=/root/unibench
ENV SEED_DIR=/root/projects/seed_corpus

# Build LibAFL toolchain
WORKDIR /StorFuzz/fuzzers/forkserver_libafl_cc
RUN unset CFLAGS CXXFLAGS && \
    export LIBAFL_EDGES_MAP_SIZE_MAX=4194304 && \
    CFLAGS="" CXXFLAGS="" cargo build --release

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

# gdk-pixbuf-2.31.1: skipped -- its autogen.sh/autoreconf chain needs a
# working autopoint (gettext) that this base image doesn't have; AUTOPOINT=true
# and manually fetching config.rpath weren't enough to get past it. Revisit
# separately if this target is needed.

# jhead-3.00
RUN cd $TARGET_DIR/jhead-3.00 && \
    make CC=$LIBAFL_CC -j && \
    cp jhead /root/projects/targets/

# lame-3.99.5
RUN cd $TARGET_DIR/lame-3.99.5 && \
    CC=$LIBAFL_CC ./configure --disable-shared && \
    make -j && \
    cp frontend/lame /root/projects/targets/

# swftools-0.9.2 / wav2swf: skipped -- needs a real source patch (not just
# a warning-suppression flag) in its bundled xpdf copy (lib/pdf/xpdf/
# GlobalParams.cc:925,927, pointer/int comparison), which would need the
# identical patch on the angora side too for a fair comparison. Revisit
# separately if this target is needed.

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
# Only chmod the three fuzzer binaries, not the entire target/release tree (too slow)
RUN chmod o+x /root && \
    chmod o+rx \
        /StorFuzz/fuzzers/forkserver_libafl_cc/target/release/forkserver_libafl_cc \
        /StorFuzz/fuzzers/forkserver_libafl_cc/target/release/libafl_cc \
        /StorFuzz/fuzzers/forkserver_libafl_cc/target/release/libafl_cxx && \
    chmod -R o+rX /root/projects

# WORKDIR /root/projects
# SHELL ["/bin/bash", "-c"]
# CMD ["/bin/bash"]
