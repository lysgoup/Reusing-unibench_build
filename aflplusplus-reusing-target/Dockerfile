# aflplusplus-reusing-target -- unibench targets cross-built for both plain
# AFL++ (normal afl-clang-fast coverage instrumentation) and the real-DFSan
# dtaint companion binary (dfsan_legacy/angora_dfsan_clang.sh in
# /home/yunseo/AFLplusplus_reusing, see that directory's README.md).
#
# Mirrors angora-reusing-target/Dockerfile's fast/taint two-stage-per-target
# pattern, but unlike Angora (one compiler wrapper, env-var-switched
# behavior, same CC path both times) this needs the configure/cmake step
# re-run between stages: AFL++'s afl-clang-fast and the dtaint wrapper are
# two genuinely different compiler binaries (different LLVM major versions),
# so the build system's cached CC= path must actually change, not just the
# runtime behavior of a single fixed binary.
#
# Scoped to tiffsplit only for now (see tools/build.sh's "aflplusplus-
# reusing" case) -- a validation pass proving the whole pipeline
# (Dockerfile + build.sh + run.sh) end-to-end on one target before
# expanding to the rest of unibench's ~18 programs. Extend by copying
# aflplusplus/Dockerfile's per-target RUN blocks and applying the same
# fast/dtaint two-stage split shown below.

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

RUN mkdir -p /d/p/aflplusplus-reusing/fast /d/p/aflplusplus-reusing/dtaint &&\
    apt update && apt install -y nasm libglib2.0-dev gtk-doc-tools libtiff-dev libpng-dev tcl-dev \
      libjpeg-dev zlib1g-dev libjbig-dev autoconf automake libtool gettext autopoint pkg-config

# --- tiffsplit (libtiff) ------------------------------------------------
# Fast (plain AFL++ coverage instrumentation) stage.
RUN cd /unibench/libtiff-3.9.7 && ./autogen.sh && \
    CC=afl-clang-fast CXX=afl-clang-fast++ ./configure --disable-shared && \
    make -j && \
    cp tools/tiffsplit /d/p/aflplusplus-reusing/fast/tiffsplit && \
    make clean

# Auto-generated "discard taint through this library" abilist, covering
# every shared library the fast build actually links against (jpeg/z/jbig
# codec support, libc, etc.) except the always-excluded core runtime libs.
# Mirrors angora-reusing-target/Dockerfile's own recipe exactly (ldd a
# reference binary, gen_library_abilist.sh each dependency with `discard`)
# so both fuzzers trace comparisons through the same set of "opaque"
# libraries for a fair cross-fuzzer taint comparison on the same target/
# seed -- without this, DFSan traces straight through libjpeg/libz/libjbig
# internals that Angora deliberately discards, producing a much larger,
# non-comparable set of cond records.
# Ubuntu Noble's libjpeg8/libjpeg-turbo8 uses ELF symbol versioning on
# *every* exported symbol (nm -D shows e.g. `jpeg_read_scanlines@@LIBJPEG_8.0`,
# confirmed via `nm -D libjpeg.so.8`), unlike libjbig (no versioning at all)
# or libz (only some newer symbols are versioned). DFSan's abilist matches
# against the bare function name as it appears in the IR (the version suffix
# is an ELF/dynamic-linker construct, invisible to the compiler) -- so a
# generated rule like `fun:jpeg_read_scanlines@@LIBJPEG_8.0=discard` silently
# never matches, and DFSan then treats the symbol as needing an indirect-call
# trampoline it has no definition for, breaking the link
# (`undefined reference to 'dfs$jpeg_read_scanlines'`) -- confirmed exactly
# reproducing libtiff's own `checking for jpeg_read_scanlines in -ljpeg`
# configure test standalone. Stripping the `@@VERSION` suffix here fixes
# this for any similarly-versioned library, not just libjpeg.
RUN ldd /d/p/aflplusplus-reusing/fast/tiffsplit | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

# Dtaint (real DFSan, LLVM 11.1.0 toolchain) stage -- re-runs ./configure
# so the Makefile's CC=/CXX= actually switch to the other toolchain (see
# this file's header comment for why that's necessary here).
RUN cd /unibench/libtiff-3.9.7 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    CXX=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp tools/tiffsplit /d/p/aflplusplus-reusing/dtaint/tiffsplit && \
    make clean

# --- cflow ---------------------------------------------------------------
# Second target (after tiffsplit) validating the pipeline generalizes --
# plain autotools build, no external codec/library dependencies, so no new
# abilist-discard entries are expected beyond what's already in
# /tmp/abilist.txt.
# cflow's bundled lib/obstack.c relies on old, lenient C rules for an
# incompatible function-pointer assignment; AFL++'s LLVM 20 toolchain
# treats that as a hard error by default (-Wincompatible-function-pointer-
# types), unlike the LLVM 11 toolchain used for the dtaint stage below,
# which only warns. Downgrade it back to a warning for both stages for
# consistency.
RUN cd /unibench/cflow-1.6 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ \
    CFLAGS="-Wno-error=incompatible-function-pointer-types" \
    ./configure && \
    make -j && \
    cp src/cflow /d/p/aflplusplus-reusing/fast/cflow && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/cflow | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/cflow-1.6 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    CXX=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp src/cflow /d/p/aflplusplus-reusing/dtaint/cflow && \
    make clean

# ============ remaining unibench targets (mirrors angora-reusing-target/
# Dockerfile's build recipes 1:1, minus StorFuzz variants which don't apply
# to AFL++) ============
#
# Two structural differences from angora's single-angora-clang approach,
# both already called out in this file's header comment:
#  - cmake-based targets need CMakeCache.txt/CMakeFiles wiped before the
#    dtaint-stage `cmake .` re-run, or cmake keeps using the fast stage's
#    cached afl-clang-fast compiler path instead of picking up the new
#    CC=angora_dfsan_clang.sh (autotools' ./configure has no such cache).
#  - every target gets its own ldd-based abilist-gen step (even ones that
#    plausibly only link libc/libm/libpthread/libdl, already excluded
#    below) for uniformity and because /tmp/abilist.txt accumulates across
#    the whole build -- cheap, and each new target's dtaint stage benefits
#    from every earlier target's discovered shared-library discard rules.

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

RUN ldd /d/p/aflplusplus-reusing/fast/exiv2 | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/exiv2-0.26 && \
    rm -f CMakeCache.txt && rm -rf CMakeFiles && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    CXX=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    cmake -DEXIV2_ENABLE_SHARED=OFF \
      -DCMAKE_C_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
      -DCMAKE_CXX_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh . && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make exiv2 -j && \
    cp bin/exiv2 /d/p/aflplusplus-reusing/dtaint/exiv2 && \
    make clean

# --- gdk-pixbuf (autotools, C) -------------------------------------------
RUN cd /unibench/gdk-pixbuf-2.31.1 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ \
    ./autogen.sh --enable-static=yes --enable-shared=no --with-included-loaders=yes && \
    make -j && \
    cp gdk-pixbuf/gdk-pixbuf-pixdata /d/p/aflplusplus-reusing/fast/gdk-pixbuf-pixdata && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/gdk-pixbuf-pixdata | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    for L in libpng16 libtiff libjpeg; do \
      F=$(ls /usr/lib/x86_64-linux-gnu/${L}.a /usr/lib/x86_64-linux-gnu/${L}.so /usr/lib/x86_64-linux-gnu/${L}.so.* 2>/dev/null | head -1); \
      [ -n "$F" ] && /AFLplusplus/dfsan_legacy/gen_library_abilist.sh "$F" discard | sed 's/@@[^=]*=/=/' >> /tmp/abilist.txt; \
    done && \
    cat /tmp/abilist.txt

RUN cd /unibench/gdk-pixbuf-2.31.1 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    CXX=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./autogen.sh --enable-static=yes --enable-shared=no --with-included-loaders=yes && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp gdk-pixbuf/gdk-pixbuf-pixdata /d/p/aflplusplus-reusing/dtaint/gdk-pixbuf-pixdata && \
    make clean

# --- jhead (plain make, C) -----------------------------------------------
RUN cd /unibench/jhead-3.00 && \
    CC=afl-clang-fast make -j && \
    cp jhead /d/p/aflplusplus-reusing/fast/jhead && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/jhead | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/jhead-3.00 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp jhead /d/p/aflplusplus-reusing/dtaint/jhead && \
    make clean

# --- lame (autotools, C) --------------------------------------------------
RUN cd /unibench/lame-3.99.5 && \
    CC=afl-clang-fast ./configure --disable-shared && \
    make -j && \
    cp frontend/lame /d/p/aflplusplus-reusing/fast/lame && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/lame | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/lame-3.99.5 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp frontend/lame /d/p/aflplusplus-reusing/dtaint/lame && \
    make clean

# --- mp3gain (plain make, C) ----------------------------------------------
RUN cd /unibench/mp3gain-1.5.2 && sed -i 's/CC=/CC?=/' Makefile && \
    CC=afl-clang-fast make -j && \
    cp mp3gain /d/p/aflplusplus-reusing/fast/mp3gain && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/mp3gain | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/mp3gain-1.5.2 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp mp3gain /d/p/aflplusplus-reusing/dtaint/mp3gain && \
    make clean

# --- swftools (autotools, C, needs -fcommon for old tentative-def style) --
RUN cd /unibench/swftools-0.9.2/ && \
    CC=afl-clang-fast CXX=afl-clang-fast++ CFLAGS="-fcommon" CXXFLAGS="-fcommon" ./configure && \
    sed -i 's/int inline ActionTagSize/int ActionTagSize/' ./lib/modules/swfaction.c && \
    sed -i 's/byte inline PaethPredictor/byte PaethPredictor/' ./src/png2swf.c && \
    make -j && \
    cp src/wav2swf /d/p/aflplusplus-reusing/fast/wav2swf && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/wav2swf | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/swftools-0.9.2/ && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    CXX=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    CFLAGS="-fcommon" CXXFLAGS="-fcommon" ./configure && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt CFLAGS="-fcommon" CXXFLAGS="-fcommon" make -j && \
    cp src/wav2swf /d/p/aflplusplus-reusing/dtaint/wav2swf && \
    make clean

# --- flvmeta (cmake, C) ---------------------------------------------------
RUN cd /unibench/flvmeta-1.2.1 && \
    CC=afl-clang-fast cmake . && \
    make -j && \
    cp src/flvmeta /d/p/aflplusplus-reusing/fast/flvmeta && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/flvmeta | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/flvmeta-1.2.1 && \
    rm -f CMakeCache.txt && rm -rf CMakeFiles && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    cmake -DCMAKE_C_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh . && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp src/flvmeta /d/p/aflplusplus-reusing/dtaint/flvmeta && \
    make clean

# --- Bento4 (cmake, C++) ---------------------------------------------------
RUN cd /unibench/Bento4-1.5.1-628 && \
    CC=afl-clang-fast CXX=afl-clang-fast++ cmake . && \
    make -j && \
    cp mp42aac /d/p/aflplusplus-reusing/fast/mp42aac && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/mp42aac | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/Bento4-1.5.1-628 && \
    rm -f CMakeCache.txt && rm -rf CMakeFiles && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    cmake -DCMAKE_C_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
      -DCMAKE_CXX_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh . && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp mp42aac /d/p/aflplusplus-reusing/dtaint/mp42aac && \
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

RUN ldd /d/p/aflplusplus-reusing/fast/infotocap | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/ncurses-6.1 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared --without-cxx && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt ASAN_OPTIONS="detect_leaks=0" make -j && \
    cp progs/tic /d/p/aflplusplus-reusing/dtaint/infotocap && \
    make clean

# --- jq (autotools, C) -----------------------------------------------------
RUN cd /unibench/jq-1.5 && \
    CC=afl-clang-fast ./configure --disable-shared && \
    make -j && \
    cp jq /d/p/aflplusplus-reusing/fast/jq && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/jq | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/jq-1.5 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp jq /d/p/aflplusplus-reusing/dtaint/jq && \
    make clean

# --- mujs (plain make, C) --------------------------------------------------
RUN cd /unibench/mujs-1.0.2 && \
    CC=afl-clang-fast build=debug make -j && \
    cp build/debug/mujs /d/p/aflplusplus-reusing/fast/mujs && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/mujs | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/mujs-1.0.2 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt build=debug make -j && \
    cp build/debug/mujs /d/p/aflplusplus-reusing/dtaint/mujs && \
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

RUN ldd /d/p/aflplusplus-reusing/fast/pdftotext | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/xpdf-4.00 && \
    rm -f CMakeCache.txt && rm -rf CMakeFiles && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt CXXFLAGS="-std=gnu++14" \
    cmake -DCMAKE_C_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
      -DCMAKE_CXX_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang++.sh . && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp xpdf/pdftotext /d/p/aflplusplus-reusing/dtaint/pdftotext && \
    make clean

# --- SQLite (autotools, C) --------------------------------------------------
RUN cd /unibench/SQLite-3.8.9 && \
    CC=afl-clang-fast ./configure --disable-shared && \
    make -j && \
    cp sqlite3 /d/p/aflplusplus-reusing/fast/sqlite3 && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/sqlite3 | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/SQLite-3.8.9 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt ASAN_OPTIONS="detect_leaks=0" make -j && \
    cp sqlite3 /d/p/aflplusplus-reusing/dtaint/sqlite3 && \
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

RUN ldd /d/p/aflplusplus-reusing/fast/nm | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/binutils-5279478 && \
    MAKEINFO=true CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared --disable-werror --disable-gdb --disable-gdbserver --disable-gold && \
    for i in bfd libiberty opcodes libctf; do \
        cd $i && \
        MAKEINFO=true CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
        ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
        ./configure --disable-shared --disable-werror && \
        ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && cd ..; \
    done && \
    cd binutils && \
    MAKEINFO=true CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared --disable-werror && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make nm-new && \
    cp nm-new /d/p/aflplusplus-reusing/dtaint/nm && \
    cd /unibench/binutils-5279478 && make distclean 2>/dev/null; true

# --- binutils-2.28 (autotools, C, needs flex/bison already in base image) --
RUN cd /unibench/binutils-2.28 && \
    CC=afl-clang-fast ./configure --disable-shared LEXLIB= && \
    make -j LEXLIB= && \
    cp binutils/objdump /d/p/aflplusplus-reusing/fast/objdump && \
    make clean

RUN ldd /d/p/aflplusplus-reusing/fast/objdump | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/binutils-2.28 && \
    find . -name config.cache -delete && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    ./configure --disable-shared LEXLIB= && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt ASAN_OPTIONS="detect_leaks=0" make -j LEXLIB= && \
    cp binutils/objdump /d/p/aflplusplus-reusing/dtaint/objdump && \
    make clean

# --- libpcap + tcpdump (autotools, C, sibling-directory auto-discovery) ----
# tcpdump-4.8.1's configure has an AC_RUN_IFELSE check for a 64-bit printf
# format specifier whose test programs are bare K&R-style `main()` with no
# return type -- "implicit int" was only a *warning* when this was
# written, but modern clang (our afl-clang-fast/angora_dfsan_clang.sh, both
# recent LLVM) makes it a hard compile error by default, so ALL THREE
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

RUN ldd /d/p/aflplusplus-reusing/fast/tcpdump | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

# libpcap's own portability.h unconditionally #defines a compat strlcpy()
# macro whenever HAVE_STRLCPY isn't set (libpcap's 2016-era build never
# actually checks for it at all, at any compiler), rewriting calls to
# strlcpy(x,y,z) as (strncpy((x),(y),(z)), ...). Modern glibc (2.38+, this
# base image) added a *real* strlcpy() to string.h, so the macro's text
# substitution corrupts string.h's own declaration line wherever the
# literal token "strlcpy" appears in it ("expected ')'", "conflicting
# types for 'strncpy'"). Real, reproducible clang-version difference: the
# identical source+flags compile clean under afl-clang-fast (LLVM 20) but
# fail here under angora_dfsan_clang.sh (LLVM 11) -- apparently LLVM 11 and
# 20 disagree on whether glibc's feature-test gating exposes the new
# strlcpy declaration at all. Forcing -DHAVE_STRLCPY makes portability.h
# skip the conflicting macro and just use the real (and, since glibc 2.38,
# genuinely available) libc strlcpy -- the semantically correct outcome
# either way, not merely a suppression.
RUN cd /unibench/libpcap-1.8.1 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    CFLAGS="-DHAVE_STRLCPY" \
    ./configure --disable-shared && ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    # tcpdump's own AC_CHECK_FUNC(...) synthetic conftests (bare extern
    # declaration + address-of, no real header) fail to link against the
    # just-built, DFSan-compiled libpcap.a -- these are all real functions
    # with a body there, so DFSan renames each definition to "dfs$name"
    # (same as sqlite3_step etc. earlier in this file); autoconf's tiny
    # synthetic probes don't reference them the way real application code
    # (tcpdump.c, compiled through the same wrapper) does, so the probes
    # alone fail even though the real functions are genuinely present and
    # real usage links fine -- confirmed the hard way: leaving these
    # undetected made tcpdump fall back to ITS OWN bundled compat shims
    # (missing/dlnames.c, missing/datalinks.c, pcap_dump_ftell.c), which
    # then collided at link time with the real (mis-detected-as-absent)
    # definitions already in libpcap.a ("multiple definition of
    # `dfs$pcap_list_datalinks'" etc). Pre-seeding every affected cache
    # variable with the answer we already know to be true (standard
    # autoconf override mechanism) skips the unreliable probes instead of
    # chasing exactly why their narrower synthetic form doesn't resolve
    # the symbol. (pcap_set_parser_debug/pcap_debug/yydebug/
    # pcap_set_optimizer_debug are correctly "no" for a normal non-debug
    # libpcap build -- left alone.)
    cd /unibench/tcpdump-4.8.1 && \
    CC=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt \
    CFLAGS="-Wno-error=implicit-int -Wno-error=implicit-function-declaration" \
    ac_cv_func_pcap_loop=yes \
    ac_cv_func_pcap_list_datalinks=yes \
    ac_cv_func_pcap_set_datalink=yes \
    ac_cv_func_pcap_datalink_name_to_val=yes \
    ac_cv_func_pcap_datalink_val_to_name=yes \
    ac_cv_func_pcap_datalink_val_to_description=yes \
    ac_cv_func_pcap_breakloop=yes \
    ac_cv_func_pcap_dump_ftell=yes \
    ac_cv_func_pcap_create=yes \
    ac_cv_func_pcap_findalldevs=yes \
    ac_cv_func_pcap_dump_flush=yes \
    ac_cv_func_pcap_lib_version=yes \
    ac_cv_func_pcap_setdirection=yes \
    ac_cv_func_pcap_set_immediate_mode=yes \
    ./configure && ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp tcpdump /d/p/aflplusplus-reusing/dtaint/tcpdump && \
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

RUN ldd /d/p/aflplusplus-reusing/fast/imginfo | grep '\.so' | awk '{print $3}' | grep '\.so' | sort | uniq \
      | grep -v libgcc_s.so | grep -v libstdc++.so | grep -v libc.so | grep -v libm.so | grep -v libpthread.so \
      | xargs -i /AFLplusplus/dfsan_legacy/gen_library_abilist.sh '{}' discard \
      | sed 's/@@[^=]*=/=/' \
      | { grep -v '^fun:crc32=' || true; } >> /tmp/abilist.txt && \
    cat /tmp/abilist.txt

RUN cd /unibench/jasper-2.0.12 && \
    rm -f CMakeCache.txt && rm -rf CMakeFiles && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt CFLAGS="-Wno-error=implicit-function-declaration" \
    cmake -DJAS_ENABLE_SHARED=OFF -DALLOW_IN_SOURCE_BUILD=ON \
      -DCMAKE_C_COMPILER=/AFLplusplus/dfsan_legacy/angora_dfsan_clang.sh . && \
    ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt make -j && \
    cp src/appl/imginfo /d/p/aflplusplus-reusing/dtaint/imginfo && \
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
