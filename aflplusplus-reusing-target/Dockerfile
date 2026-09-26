# aflplusplus-reusing-target -- unibench targets built with plain AFL++
# coverage instrumentation (afl-clang-fast), for afl-fuzz -r.
#
# One stage per target, same as aflplusplus/Dockerfile. There used to be a
# second, real-DFSan stage per target (dfsan_legacy/angora_dfsan_clang.sh)
# producing a dtaint/ companion binary, from when afl-fuzz did its own taint
# tracking. It no longer does: -r reads a cache taint_scan built ahead of time
# from Angora's own track binary, so nothing here ever executed those binaries
# -- run.sh only stat()ed them -- and the DFSan stage was pure build time
# (-j1, and an ldd-based abilist gen per target on top).
#
# Dropped with them: <name>.cmpid_log.txt, the cmpid -> file:line:col table
# that ANGORA_OUTPUT_COND_LOC=1 emitted during that stage. Nothing else
# produces it -- not taint_scan, not angora-reusing-target -- so looking up
# where a .dtaint record's cmpid lives in the source now needs a one-off
# build with that env var set. Deliberate: the table cost a full second
# compile of every target on every image build.

FROM yunseo/aflplusplus-reusing

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

RUN mkdir -p /d/p/aflplusplus-reusing/fast &&\
    apt update && apt install -y nasm libglib2.0-dev gtk-doc-tools libtiff-dev libpng-dev tcl-dev \
      libjpeg-dev zlib1g-dev libjbig-dev autoconf automake libtool gettext autopoint pkg-config

# --- tiffsplit (libtiff) ------------------------------------------------
# Fast (plain AFL++ coverage instrumentation) stage.
RUN cd /unibench/libtiff-3.9.7 && ./autogen.sh && \
    CC=afl-clang-fast CXX=afl-clang-fast++ ./configure --disable-shared && \
    make -j && \
    cp tools/tiffsplit /d/p/aflplusplus-reusing/fast/tiffsplit && \
    make clean

# --- cflow ---------------------------------------------------------------
# cflow's bundled lib/obstack.c relies on old, lenient C rules for an
# incompatible function-pointer assignment; AFL++'s LLVM 20 toolchain
# treats that as a hard error by default
# (-Wincompatible-function-pointer-types). Downgrade it back to a warning.
RUN cd /unibench/cflow-1.6 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ \
    CFLAGS="-Wno-error=incompatible-function-pointer-types" \
    ./configure && \
    make -j && \
    cp src/cflow /d/p/aflplusplus-reusing/fast/cflow && \
    make clean

# ============ remaining unibench targets (mirrors angora-reusing-target/
# Dockerfile's build recipes 1:1, minus StorFuzz variants which don't apply
# to AFL++) ============

# --- exiv2 (cmake, C++) --------------------------------------------------
# src/futils.cpp re-declares strerror_r itself, guarded by
# EXV_HAVE_DECL_STRERROR_R (from CMake's CheckSymbolExists, which runs its
# own tiny standalone test program without _GNU_SOURCE defined -- unlike
# the real exiv2 sources, which do get it project-wide). On this glibc
# (_GNU_SOURCE auto-defined), <string.h> really does declare the GNU
# char*-returning strerror_r, but the CMake check reports "not declared",
# so futils.cpp falls through to hand-declaring the POSIX int-returning
# signature instead -- a real declaration conflict with the header's own
# `char *strerror_r(...)`, a hard error under modern clang
# ("functions that differ only in their return type cannot be
# overloaded"). The redeclaration is unconditionally unnecessary here
# (string.h already provides a correct declaration either way), so just
# delete the whole guarded block once, before either build stage.
RUN cd /unibench/exiv2-0.26 && \
    sed -i '/#if defined EXV_HAVE_STRERROR_R && !defined EXV_HAVE_DECL_STRERROR_R/,/^#endif$/d' src/futils.cpp

RUN cd /unibench/exiv2-0.26 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ \
    cmake -DEXIV2_ENABLE_SHARED=OFF . && \
    make exiv2 -j && \
    cp bin/exiv2 /d/p/aflplusplus-reusing/fast/exiv2 && \
    make clean

# --- gdk-pixbuf (autotools, C) -------------------------------------------
RUN cd /unibench/gdk-pixbuf-2.31.1 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ \
    ./autogen.sh --enable-static=yes --enable-shared=no --with-included-loaders=yes && \
    make -j && \
    cp gdk-pixbuf/gdk-pixbuf-pixdata /d/p/aflplusplus-reusing/fast/gdk-pixbuf-pixdata && \
    make clean

# --- jhead (plain make, C) -----------------------------------------------
RUN cd /unibench/jhead-3.00 && \
    CC=afl-clang-fast make -j && \
    cp jhead /d/p/aflplusplus-reusing/fast/jhead && \
    make clean

# --- lame (autotools, C) --------------------------------------------------
RUN cd /unibench/lame-3.99.5 && \
    CC=afl-clang-fast ./configure --disable-shared && \
    make -j && \
    cp frontend/lame /d/p/aflplusplus-reusing/fast/lame && \
    make clean

# --- mp3gain (plain make, C) ----------------------------------------------
RUN cd /unibench/mp3gain-1.5.2 && sed -i 's/CC=/CC?=/' Makefile && \
    CC=afl-clang-fast make -j && \
    cp mp3gain /d/p/aflplusplus-reusing/fast/mp3gain && \
    make clean

# --- swftools (autotools, C, needs -fcommon for old tentative-def style) --
RUN cd /unibench/swftools-0.9.2/ && \
    CC=afl-clang-fast CXX=afl-clang-fast++ CFLAGS="-fcommon" CXXFLAGS="-fcommon" ./configure && \
    sed -i 's/int inline ActionTagSize/int ActionTagSize/' ./lib/modules/swfaction.c && \
    sed -i 's/byte inline PaethPredictor/byte PaethPredictor/' ./src/png2swf.c && \
    make -j && \
    cp src/wav2swf /d/p/aflplusplus-reusing/fast/wav2swf && \
    make clean

# --- flvmeta (cmake, C) ---------------------------------------------------
RUN cd /unibench/flvmeta-1.2.1 && \
    CC=afl-clang-fast cmake . && \
    make -j && \
    cp src/flvmeta /d/p/aflplusplus-reusing/fast/flvmeta && \
    make clean

# --- Bento4 (cmake, C++) ---------------------------------------------------
RUN cd /unibench/Bento4-1.5.1-628 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ cmake . && \
    make -j && \
    cp mp42aac /d/p/aflplusplus-reusing/fast/mp42aac && \
    make clean

# --- ncurses (autotools, C) ------------------------------------------------
# ncurses' own c++/ subdir builds a bundled C++ demo binary with the plain
# system g++ (never respects a single CC= override -- it wants its own
# CXX=), but links it against libform.a/libncurses.a which -- because
# those WERE built with afl-clang-fast -- reference AFL++'s coverage
# runtime (__afl_area_ptr, __sanitizer_cov_trace_pc_guard_init). Plain g++
# doesn't know to link afl-compiler-rt.o, so that demo fails to link. We
# only need progs/tic (copied out below), never the C++ binding demo, so
# just disable it outright via ncurses' own --without-cxx configure flag
# instead of fighting the mismatched toolchain.
RUN cd /unibench/ncurses-6.1 && \
    CC=afl-clang-fast ./configure --disable-shared --without-cxx && \
    make -j && \
    cp progs/tic /d/p/aflplusplus-reusing/fast/infotocap && \
    make clean

# --- jq (autotools, C) -----------------------------------------------------
RUN cd /unibench/jq-1.5 && \
    CC=afl-clang-fast ./configure --disable-shared && \
    make -j && \
    cp jq /d/p/aflplusplus-reusing/fast/jq && \
    make clean

# --- mujs (plain make, C) --------------------------------------------------
RUN cd /unibench/mujs-1.0.2 && \
    CC=afl-clang-fast build=debug make -j && \
    cp build/debug/mujs /d/p/aflplusplus-reusing/fast/mujs && \
    make clean

# --- xpdf (cmake, C++) ------------------------------------------------------
# xpdf-4.00's goo/gmem.h declares functions with C++98-style dynamic
# exception specifications (`throw(GMemException)`), deprecated since
# C++11 and *removed outright* in C++17 (our clang's default standard) --
# a hard parse error ("ISO C++17 does not allow dynamic exception
# specifications"), not just a downgradable warning. Compile in gnu++14
# (the last standard where this syntax still parses) instead of touching
# 20-year-old xpdf source.
RUN cd /unibench/xpdf-4.00 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ CXXFLAGS="-std=gnu++14" cmake . && \
    make -j && \
    cp xpdf/pdftotext /d/p/aflplusplus-reusing/fast/pdftotext && \
    make clean

# --- SQLite (autotools, C) --------------------------------------------------
RUN cd /unibench/SQLite-3.8.9 && \
    CC=afl-clang-fast ./configure --disable-shared && \
    make -j && \
    cp sqlite3 /d/p/aflplusplus-reusing/fast/sqlite3 && \
    make clean

# --- binutils-5279478 (nested configure, C) --------------------------------
RUN cd /unibench/binutils-5279478 && \
    MAKEINFO=true CC=afl-clang-fast ./configure \
      --disable-shared --disable-werror --disable-gdb --disable-gdbserver --disable-gold && \
    for i in bfd libiberty opcodes libctf; do \
        cd $i && MAKEINFO=true CC=afl-clang-fast ./configure --disable-shared --disable-werror && make -j && cd ..; \
    done && \
    cd binutils && MAKEINFO=true CC=afl-clang-fast ./configure --disable-shared --disable-werror && \
    make nm-new && \
    cp nm-new /d/p/aflplusplus-reusing/fast/nm && \
    cd /unibench/binutils-5279478 && make distclean 2>/dev/null; true

# --- binutils-2.28 (autotools, C, needs flex/bison already in base image) --
RUN cd /unibench/binutils-2.28 && \
    CC=afl-clang-fast ./configure --disable-shared LEXLIB= && \
    make -j LEXLIB= && \
    cp binutils/objdump /d/p/aflplusplus-reusing/fast/objdump && \
    make clean

# --- libpcap + tcpdump (autotools, C, sibling-directory auto-discovery) ----
# tcpdump-4.8.1's configure has an AC_RUN_IFELSE check for a 64-bit printf
# format specifier whose test programs are bare K&R-style `main()` with no
# return type -- "implicit int" was only a *warning* when this was
# written, but modern clang (afl-clang-fast, LLVM 20) makes it a hard
# compile error by default, so ALL THREE
# candidate test programs (%llx/%Lx/%qx) fail to even compile, and
# autoconf reports "no" for all of them identically -- including %llx,
# which is trivially the objectively correct answer on this glibc, proving
# the failure has nothing to do with which format specifier actually
# works. Relaxing the specific removed/hardened check (not touching
# 2016-era tcpdump source) instead, same category as the isoc23/xpdf
# language-version fixes elsewhere in this file.
RUN cd /unibench/libpcap-1.8.1 && CC=afl-clang-fast ./configure --disable-shared && make -j && \
    cd /unibench/tcpdump-4.8.1 && CC=afl-clang-fast CFLAGS="-Wno-error=implicit-int -Wno-error=implicit-function-declaration" ./configure && make -j && \
    cp tcpdump /d/p/aflplusplus-reusing/fast/tcpdump && \
    make clean && cd /unibench/libpcap-1.8.1 && make clean

# --- jasper (cmake, C, JPEG2000) --------------------------------------------
# jasper-2.0.12 calls jas_eprintf() (and similar) without a visible
# declaration in some translation units -- implicit function declarations
# were only a warning when this was written, but modern clang makes it a
# hard error by default (same category as tcpdump's implicit-int fix
# above). Downgrading back to a warning rather than touching 2018-era
# jasper source.
RUN cd /unibench/jasper-2.0.12 && \
    CC=afl-clang-fast CFLAGS="-Wno-error=implicit-function-declaration" \
    cmake -DJAS_ENABLE_SHARED=OFF -DALLOW_IN_SOURCE_BUILD=ON . && \
    make -j && \
    cp src/appl/imginfo /d/p/aflplusplus-reusing/fast/imginfo && \
    make clean

# ffmpeg and libpng are intentionally skipped for now: angora's ffmpeg
# binary is a prebuilt tarball fetched from unibench_build's own artifact
# host (no source available in this tree to cross-build against AFL++),
# and libpng uses a custom libFuzzer-harness build script
# (build_for_angora.sh + libfuzz-harness-proxy.c) that would need its own
# AFL++-specific port rather than a mechanical CC= swap. Revisit separately
# if these two targets are needed.

RUN ls -alh /d/p/aflplusplus-reusing/*

# Install daemontools for multilog
RUN apt-get update && apt-get install -y daemontools && rm -rf /var/lib/apt/lists/*
