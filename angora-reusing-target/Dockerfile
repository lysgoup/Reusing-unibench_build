FROM myeonggyu/angora-reusing
ENV CC=/angora/bin/angora-clang
ENV CXX=/angora/bin/angora-clang++
RUN apt-get update && apt-get install -y unzip git build-essential sudo

ARG USER_ID=1009
ARG GROUP_ID=1009

RUN mkdir /volume
RUN groupadd -g ${GROUP_ID} user && \
    useradd -l -u ${USER_ID} -K UMASK=0000 -d /data -g user user && \
    chown user:user /volume

RUN echo "user:user" | chpasswd && usermod -a -G sudo user

RUN git clone https://github.com/UNIFUZZ/unibench /unibench &&\
    cd /unibench && \
    mkdir mp3gain-1.5.2 && cd mp3gain-1.5.2 && mv ../mp3gain-1.5.2.zip ./ && unzip -q mp3gain-1.5.2.zip && rm mp3gain-1.5.2.zip && cd .. &&\
    ls *.zip|xargs -i unzip -q '{}' &&\
    ls *.tar.gz|xargs -i tar xf '{}' &&\
    rm -r .git/ *.tar.gz *.zip &&\
    mv SQLite-8a8ffc86 SQLite-3.8.9 && mv binutils_5279478 binutils-5279478 && mv libtiff-Release-v3-9-7 libtiff-3.9.7 &&\
    ls -alh

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Seoul

RUN mkdir -p /d/p/angora/taint /d/p/angora/fast /d/p/angora/fast_storfuzz &&\
    apt update && apt install -y nasm libglib2.0-dev gtk-doc-tools libtiff-dev libpng-dev tcl-dev autoconf automake libtool gettext autopoint

COPY --from=unifuzz/unibench:gcc  /d/p/normal /d/p/normal

RUN ldd /d/p/normal/*|grep .so|awk '{print $3}'|grep .so|sort|uniq|sed 's#^/lib#/usr/lib#g'|sed 's#\.so.*$#.so#g'|grep -v libgcc_s.so|grep -v libstdc++.so|grep -v libc.so|grep -v libm.so|grep -v libpthread.so|xargs -i /angora/tools/gen_library_abilist.sh '{}' discard >> /tmp/abilist.txt

ENV ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt

RUN cd /unibench/exiv2-0.26 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake -DEXIV2_ENABLE_SHARED=OFF . && make -j && cp bin/exiv2 /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp bin/exiv2 /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j && cp bin/exiv2 /d/p/angora/taint/ &&\
    make clean

# RUN cd /unibench/gdk-pixbuf-2.31.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
#     ./autogen.sh --enable-static=yes --enable-shared=no --with-included-loaders=yes && make -j &&\
#     cp gdk-pixbuf/gdk-pixbuf-pixdata /d/p/angora/fast/ &&\
#     make clean && USE_TRACK=1 make -j &&\
#     cp gdk-pixbuf/gdk-pixbuf-pixdata /d/p/angora/taint/ &&\
#     make clean

RUN cd /unibench/jhead-3.00 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make -j &&\
    cp jhead /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp jhead /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j &&\
    cp jhead /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/libtiff-3.9.7 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./autogen.sh && ./configure --disable-shared &&\
    make -j &&\
    cp tools/tiffsplit /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp tools/tiffsplit /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j &&\
    cp tools/tiffsplit /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/lame-3.99.5 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\
    make -j &&\
    cp frontend/lame /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp frontend/lame /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j &&\
    cp frontend/lame /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/mp3gain-1.5.2 && export ANGORA_PASS_LOG_DIR=$(pwd) && sed -i 's/CC=/CC?=/' Makefile &&\
    make -j &&\
    cp mp3gain /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp mp3gain /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j &&\
    cp mp3gain /d/p/angora/taint/ &&\
    make clean

# RUN cd /unibench/swftools-0.9.2/ && ./configure &&\
#     sed -i 's/int inline ActionTagSize/int ActionTagSize/' ./lib/modules/swfaction.c &&\
#     sed -i 's/byte inline PaethPredictor/byte PaethPredictor/' ./src/png2swf.c &&\
#     make -j &&\
#     cp src/wav2swf /d/p/angora/fast/ &&\
#     make clean && USE_TRACK=1 make -j &&\
#     cp src/wav2swf /d/p/angora/taint/ &&\
#     make clean

RUN cd /unibench/swftools-0.9.2/ && \
    export ANGORA_PASS_LOG_DIR=$(pwd) && \
    CFLAGS="-fcommon" CXXFLAGS="-fcommon" ./configure && \
    sed -i 's/int inline ActionTagSize/int ActionTagSize/' ./lib/modules/swfaction.c && \
    sed -i 's/byte inline PaethPredictor/byte PaethPredictor/' ./src/png2swf.c && \
    make -j && \
    cp src/wav2swf /d/p/angora/fast/ && \
    make clean && \
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && \
    cp src/wav2swf /d/p/angora/fast_storfuzz/ && \
    make clean && \
    CFLAGS="-fcommon" CXXFLAGS="-fcommon" USE_TRACK=1 make -j && \
    cp src/wav2swf /d/p/angora/taint/ && \
    make clean

RUN cd /unibench/flvmeta-1.2.1 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake . &&\
    make -j &&\
    cp src/flvmeta /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp src/flvmeta /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j &&\
    cp src/flvmeta /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/Bento4-1.5.1-628 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake . &&\
    make -j &&\
    cp mp42aac /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp mp42aac /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j &&\
    cp mp42aac /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/cflow-1.6 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure &&\
    make -j &&\
    cp src/cflow /d/p/angora/fast/ &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp src/cflow /d/p/angora/fast_storfuzz/ && make clean && USE_TRACK=1 make -j &&\
    cp src/cflow /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/ncurses-6.1 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\
    make -j &&\
    cp progs/tic /d/p/angora/fast/infotocap &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j && cp progs/tic /d/p/angora/fast_storfuzz/infotocap && make clean && USE_TRACK=1 ASAN_OPTIONS="detect_leaks=0" make -j &&\
    cp progs/tic /d/p/angora/taint/infotocap &&\
    make clean

RUN ls -alh /d/p/*
# ============ merged from angora-reusing_step2 ============

RUN cd /unibench/jq-1.5 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\
    make -j &&\
    cp jq /d/p/angora/fast/ &&\
    make clean &&\
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j &&\
    cp jq /d/p/angora/fast_storfuzz/ &&\
    make clean && USE_TRACK=1 make -j &&\
    cp jq /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/mujs-1.0.2 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    build=debug make -j &&\
    cp build/debug/mujs /d/p/angora/fast/ &&\
    make clean &&\
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 build=debug make -j &&\
    cp build/debug/mujs /d/p/angora/fast_storfuzz/ &&\
    make clean && sleep 3 && USE_TRACK=1 build=debug make -j &&\
    cp build/debug/mujs /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/xpdf-4.00 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake . &&\
    make -j &&\
    cp xpdf/pdftotext /d/p/angora/fast/ &&\
    make clean &&\
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j &&\
    cp xpdf/pdftotext /d/p/angora/fast_storfuzz/ &&\
    make clean && USE_TRACK=1 make -j &&\
    cp xpdf/pdftotext /d/p/angora/taint/ &&\
    make clean

#--disable-amalgamation can be used for coverage build
RUN cd /unibench/SQLite-3.8.9 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\ 
    make -j &&\
    cp sqlite3 /d/p/angora/fast/ &&\
    make clean &&\
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j &&\
    cp sqlite3 /d/p/angora/fast_storfuzz/ &&\
    make clean && USE_TRACK=1 ASAN_OPTIONS="detect_leaks=0" make -j &&\
    cp sqlite3 /d/p/angora/taint/ &&\
    make clean

# RUN cd /unibench/binutils-5279478 &&\
#     ./configure --disable-shared &&\
#     for i in bfd libiberty opcodes libctf; do cd $i; ./configure --disable-shared && make -j; cd ..; done  &&\
#     cd binutils  &&\
#     ./configure --disable-shared &&\
#     make nm-new &&\
#     cp nm-new /d/p/angora/fast/nm &&\
#     cd /unibench/binutils-5279478 &&\
#     for i in bfd libiberty opcodes libctf; do cd $i; make clean && USE_TRACK=1 make -j; cd ..; done  &&\
#     cd binutils  && make clean &&\
#     USE_TRACK=1 make nm-new &&\
#     cp nm-new /d/p/angora/taint/nm &&\
#     cd .. && make distclean

RUN cd /unibench/binutils-5279478 && export ANGORA_PASS_LOG_DIR=$(pwd) && \
    MAKEINFO=true ./configure \
      --disable-shared \
      --disable-werror \
      --disable-gdb \
      --disable-gdbserver \
      --disable-gold && \
    for i in bfd libiberty opcodes libctf; do \
        cd $i && \
        MAKEINFO=true ./configure \
          --disable-shared \
          --disable-werror && \
        make -j && \
        cd ..; \
    done && \
    cd binutils && \
    MAKEINFO=true ./configure \
      --disable-shared \
      --disable-werror && \
    make nm-new && \
    cp nm-new /d/p/angora/fast/nm && \
    make clean && \
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 make nm-new && \
    cp nm-new /d/p/angora/fast_storfuzz/nm && \
    cd /unibench/binutils-5279478 && \
    for i in bfd libiberty opcodes libctf; do \
        cd $i && \
        make clean && \
        USE_TRACK=1 make -j && \
        cd ..; \
    done && \
    cd binutils && \
    make clean && \
    USE_TRACK=1 make nm-new && \
    cp nm-new /d/p/angora/taint/nm && \
    cd .. && make distclean

RUN ls -alh /d/p/angora/*
# ============ merged from angora-reusing (former -base) ============
RUN apt-get update && apt-get install -y flex bison

# StorFuzz-instrumented "fast" binaries are placed here (alongside the existing fast/ and taint/)
RUN mkdir -p /d/p/angora/fast_storfuzz

RUN cd /unibench/binutils-2.28 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared LEXLIB= &&\
    make -j LEXLIB= &&\
    cp binutils/objdump /d/p/angora/fast/ &&\
    make clean &&\
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j LEXLIB= &&\
    cp binutils/objdump /d/p/angora/fast_storfuzz/ &&\
    make clean &&\
    USE_TRACK=1 ASAN_OPTIONS="detect_leaks=0" make -j LEXLIB= &&\
    cp binutils/objdump /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/libpcap-1.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\
    make -j &&\
    cd /unibench/tcpdump-4.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure &&\
    make -j &&\
    cp tcpdump /d/p/angora/fast/ &&\
    cd /unibench/libpcap-1.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j &&\
    cd /unibench/tcpdump-4.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make clean && ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j &&\
    cp tcpdump /d/p/angora/fast_storfuzz/ &&\
    make clean && cd /unibench/libpcap-1.8.1 && make clean &&\
    cd /unibench/libpcap-1.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make clean && USE_TRACK=1 make -j &&\
    cd /unibench/tcpdump-4.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make clean && USE_TRACK=1 make -j &&\
    cp tcpdump /d/p/angora/taint/ &&\
    make clean && cd /unibench/libpcap-1.8.1 && make clean

# this will add /d/p/angora/fast/ffmpeg and /d/p/angora/taint/ffmpeg
# NOTE: ffmpeg is a PREBUILT tarball (no source available here), so it cannot be StorFuzz-instrumented.
#       There is intentionally NO /d/p/angora/fast_storfuzz/ffmpeg (skipped).
RUN wget --quiet https://gitlab.com/unifuzz/unibench_build/raw/master/ffmpeg/angora.tar.gz &&\
    tar xf angora.tar.gz -C / &&\
    rm angora.tar.gz

RUN cd /unibench/jasper-2.0.12 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake -DJAS_ENABLE_SHARED=OFF -DALLOW_IN_SOURCE_BUILD=ON . &&\
    make -j &&\
    cp src/appl/imginfo /d/p/angora/fast/ &&\
    make clean &&\
    ANGORA_USE_STORFUZZ=1 USE_FAST=1 make -j &&\
    cp src/appl/imginfo /d/p/angora/fast_storfuzz/ &&\
    make clean &&\
    USE_TRACK=1 make -j &&\
    cp src/appl/imginfo /d/p/angora/taint/ &&\
    make clean

RUN git clone --depth=1 --branch v1.6.51 https://github.com/pnggroup/libpng.git /unibench/libpng

COPY Reusing-unibench_build/angora-reusing-target/build_for_angora.sh /unibench/libpng/
COPY Reusing-unibench_build/angora-reusing-target/libfuzz-harness-proxy.c /unibench/libpng/
# StorFuzz build script for libpng (produces a StorFuzz-instrumented angora-out/libpng_angora.fast)
COPY Reusing-unibench_build/angora-reusing-target/build_for_storfuzz.sh /unibench/libpng/

RUN cd /unibench/libpng && export ANGORA_PASS_LOG_DIR=$(pwd) && \
    bash build_for_angora.sh && \
    cp angora-out/libpng_angora.fast /d/p/angora/fast/libpng_read_fuzzer && \
    cp angora-out/libpng_angora.taint /d/p/angora/taint/libpng_read_fuzzer && \
    cp scripts/pnglibconf.dfa.bak scripts/pnglibconf.dfa && \
    bash build_for_storfuzz.sh && \
    cp angora-out/libpng_angora.fast /d/p/angora/fast_storfuzz/libpng_read_fuzzer

RUN chmod -R a+rX /unibench

RUN ls -alh /d/p/angora/*