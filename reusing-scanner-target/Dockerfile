# reusing-scanner-target -- the unibench targets built with the standalone
# scanner's toolchain, the same shape angora-reusing-target has: FROM the
# toolchain image tools/build.sh made in step 1, then one block per target.
#
# The recipes are angora-reusing-target/Dockerfile's with the paths moved:
# /angora/bin -> /reusing-scanner/bin. StorFuzz variants are dropped -- a scan
# never runs them. Each target is built twice: plain (the "fast" binary the
# forkserver needs) and USE_TRACK=1 (the DFSan binary a scan actually reads).
#
# ANGORA_KEEP_BUILTINS=1 on a track build opts that target out of
# angora-clang's -fno-builtin. Measured reasons, per target, at its block.

FROM reusing-scanner

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Seoul
ENV CC=/reusing-scanner/bin/angora-clang
ENV CXX=/reusing-scanner/bin/angora-clang++

# tcl: SQLite generates sqlite3.h with a tclsh script.
# flex/bison: tcpdump's and cflow's parsers.
# nasm/yasm: ffmpeg's x86 assembly.
# daemontools: tools/volume/entrypoint.sh pipes the run through multilog.
RUN apt-get update && apt-get install -y unzip wget xz-utils flex bison tcl \
      nasm yasm zlib1g-dev autoconf automake libtool pkg-config daemontools \
      && apt-get clean

# mp3gain's zip has no top-level directory, so it gets one before the bulk
# unzip would spill its sources into /unibench itself.
RUN git clone --depth=1 https://github.com/UNIFUZZ/unibench /unibench &&\
    cd /unibench &&\
    mkdir mp3gain-1.5.2 && cd mp3gain-1.5.2 && mv ../mp3gain-1.5.2.zip ./ &&\
    unzip -q mp3gain-1.5.2.zip && rm mp3gain-1.5.2.zip && cd .. &&\
    ls *.zip | xargs -i unzip -q '{}' &&\
    ls *.tar.gz | xargs -i tar xf '{}' &&\
    rm -rf .git/ *.tar.gz *.zip &&\
    mv SQLite-8a8ffc86 SQLite-3.8.9

RUN mkdir -p /d/p/taint /d/p/fast

# Start the abilist empty; each block appends what its own binary links.
RUN touch /tmp/abilist.txt
ENV ANGORA_TAINT_RULE_LIST=/tmp/abilist.txt

# --- cflow -----------------------------------------------------------------
# Opts its track build out of -fno-builtin. With the flag on, 2960 of its 6452
# seeds -- 46% -- went past the track timeout, against 0.8% for tcpdump on the
# same toolchain, and the scan ran at 16 s per seed.
RUN cd /unibench/cflow-1.6 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure &&\
    make -j && cp src/cflow /d/p/fast/ && make clean &&\
    ANGORA_KEEP_BUILTINS=1 USE_TRACK=1 make -j &&\
    cp src/cflow /d/p/taint/ && make clean

# --- sqlite3 ---------------------------------------------------------------
# Opts out too. It runs the SQL it is handed, so the VDBE loop is traced as
# well as the parser: 9 MB of .dtaint per seed (nm: 0.9 MB) and 14 s per seed,
# which put a full 88497-seed scan at 10 days and 780 GB.
RUN cd /unibench/SQLite-3.8.9 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    ./configure --disable-shared &&\
    make -j && cp sqlite3 /d/p/fast/ && make clean &&\
    ANGORA_KEEP_BUILTINS=1 USE_TRACK=1 ASAN_OPTIONS="detect_leaks=0" make -j &&\
    cp sqlite3 /d/p/taint/ && make clean

# --- tcpdump (+ libpcap) ---------------------------------------------------
# Keeps -fno-builtin: 0.8% timeouts, 0.47 s per seed, the fastest of cflow/sqlite3/tcpdump/ffmpeg.
RUN cd /unibench/libpcap-1.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    ./configure --disable-shared && make -j &&\
    cd /unibench/tcpdump-4.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    ./configure && make -j && cp tcpdump /d/p/fast/ &&\
    make clean && cd /unibench/libpcap-1.8.1 && make clean &&\
    USE_TRACK=1 make -j &&\
    cd /unibench/tcpdump-4.8.1 && USE_TRACK=1 make -j &&\
    cp tcpdump /d/p/taint/ &&\
    make clean && cd /unibench/libpcap-1.8.1 && make clean

# --- ffmpeg ----------------------------------------------------------------
# Needs its own abilist on top of the shared one; without it DFSan traces
# straight through libav* internals. (The scan it produced on the shared list
# alone came back with tags=0 -- length conds only, no byte offsets at all.)
COPY Reusing-unibench_build/reusing-scanner-target/ffmpeg_abilist.txt /tmp/ffmpeg_abilist.txt
RUN cat /tmp/abilist.txt /tmp/ffmpeg_abilist.txt | tr -d '\r' > /tmp/abilist_ffmpeg.txt &&\
    export ANGORA_TAINT_RULE_LIST=/tmp/abilist_ffmpeg.txt &&\
    cd /unibench/ffmpeg-4.0.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    ./configure --disable-doc --disable-shared --cc="$CC" --cxx="$CXX" &&\
    make -j$(nproc) && cp ffmpeg_g /d/p/fast/ffmpeg && make clean

RUN cd /unibench/ffmpeg-4.0.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    export ANGORA_TAINT_RULE_LIST=/tmp/abilist_ffmpeg.txt &&\
    USE_TRACK=1 make -j$(nproc) &&\
    cp ffmpeg_g /d/p/taint/ffmpeg && make clean

# --- jq --------------------------------------------------------------------
# Keeps -fno-builtin: measured on the AFL++ corpora at 0.74 s per seed, well
# inside the track timeout, and jq's comparisons are exactly the kind the flag
# recovers (its lexer compares literal keywords).
RUN cd /unibench/jq-1.5 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\
    make -j && cp jq /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j &&\
    cp jq /d/p/taint/ && make clean

# --- lame ------------------------------------------------------------------
# Keeps -fno-builtin, and the revisit the comment here used to promise has
# been done: rebuilt with ANGORA_KEEP_BUILTINS=1 and rescanned the same
# corpus (libafl_saturation_server2, 3302 seeds), the drops were identical
# seed for seed -- 664 timeouts and 139 crashes over ids 0-921 either way.
# lame's track cost is the encoder itself under DFSan, not the flag, so the
# flag stays for the taint quality it buys on lame's own comparisons.
RUN cd /unibench/lame-3.99.5 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\
    make -j && cp frontend/lame /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j &&\
    cp frontend/lame /d/p/taint/ && make clean

# --- exiv2 -----------------------------------------------------------------
# src/futils.cpp hand-declares the POSIX int-returning strerror_r whenever
# CMake's standalone check (run without _GNU_SOURCE) reports it undeclared,
# which clang rejects against <string.h>'s GNU char* declaration. The block is
# unnecessary either way; same fix as aflplusplus-reusing-target.
# Links zlib and expat: without abilist entries the track build calls their
# dfs$-prefixed names, which the uninstrumented system libraries do not have.
RUN for l in libz libexpat; do \
      /reusing-scanner/tools/gen_library_abilist.sh /usr/lib/x86_64-linux-gnu/$l.so discard \
        >> /tmp/abilist.txt; \
    done &&\
    cd /unibench/exiv2-0.26 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    sed -i '/#if defined EXV_HAVE_STRERROR_R && !defined EXV_HAVE_DECL_STRERROR_R/,/^#endif$/d' src/futils.cpp &&\
    cmake -DEXIV2_ENABLE_SHARED=OFF . &&\
    make exiv2 -j && cp bin/exiv2 /d/p/fast/ && make clean &&\
    USE_TRACK=1 make exiv2 -j &&\
    cp bin/exiv2 /d/p/taint/ && make clean

# --- mp3gain ---------------------------------------------------------------
# Keeps -fno-builtin, same finding as lame: ~46% of the server1 corpus times
# out, the large files (timeout median 157 KB against 28 KB overall), and an
# ANGORA_KEEP_BUILTINS=1 rebuild dropped the same share over ids 0-90 (40
# against 38). The cost is the decoder under DFSan, not the flag.
RUN cd /unibench/mp3gain-1.5.2 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    sed -i 's/CC=/CC?=/' Makefile &&\
    make -j && cp mp3gain /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j &&\
    cp mp3gain /d/p/taint/ && make clean

# --- mujs ------------------------------------------------------------------
RUN cd /unibench/mujs-1.0.2 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    build=debug make -j && cp build/debug/mujs /d/p/fast/ && make clean &&\
    USE_TRACK=1 build=debug make -j &&\
    cp build/debug/mujs /d/p/taint/ && make clean

# --- pdftotext (xpdf) ------------------------------------------------------
RUN cd /unibench/xpdf-4.00 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake . &&\
    make -j && cp xpdf/pdftotext /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j &&\
    cp xpdf/pdftotext /d/p/taint/ && make clean
# The four below are the targets a forkserver_libafl saturation run produces
# corpora for (seed/libafl_saturation_server4). All four keep -fno-builtin;
# measured on those corpora, per seed and as the share left without usable
# taint: jhead 2.2 s / 4.5%, imginfo 1.1 s / 5.3%, tiffsplit 32 s / 15%,
# flvmeta not finished at the time of writing.

# --- tiffsplit (libtiff) ---------------------------------------------------
# libtiff-Release-v3-9-7 is the name the unibench tarball unpacks to.
# aflplusplus-reusing-target renames it to libtiff-3.9.7 in its clone step;
# this image's clone step only renames SQLite, and adding a mv there would
# invalidate the layer every target above it is built on, so the upstream name
# is used as-is.
#
# Needs zlib on the abilist, the way exiv2 does: libtiff's zip and pixarlog
# codecs call into the system libz, which DFSan never instrumented, so the
# track link fails on dfs$inflateInit_ and nine more. Appended here rather
# than relied on from exiv2's block above, so this one does not break if that
# block moves or goes; a repeated entry costs nothing. Not --disable-zlib
# instead: that would drop both codecs and leave the scanned binary parsing a
# different set of TIFFs than the one being fuzzed.
#
# The 32 s per seed is the DFSan decoder, not the flag -- same finding lame
# and mp3gain record. Rebuilt with ANGORA_KEEP_BUILTINS=1 and re-scanned over
# ids 2999-3018: 932 s against 930, the same 366 pool entries, the same 3
# seeds dropped.
RUN /reusing-scanner/tools/gen_library_abilist.sh /usr/lib/x86_64-linux-gnu/libz.so discard \
      >> /tmp/abilist.txt &&\
    cd /unibench/libtiff-Release-v3-9-7 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    ./autogen.sh && ./configure --disable-shared &&\
    make -j && cp tools/tiffsplit /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j &&\
    cp tools/tiffsplit /d/p/taint/ && make clean

# --- jhead -----------------------------------------------------------------
# CC goes on the make command line, not in the environment: jhead ships a
# plain Makefile that assigns CC itself, and a makefile assignment beats the
# environment (command line beats both).
RUN cd /unibench/jhead-3.00 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make -j CC="$CC" && cp jhead /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j CC="$CC" &&\
    cp jhead /d/p/taint/ && make clean

# --- flvmeta (cmake) -------------------------------------------------------
# cmake caches the compiler, not USE_TRACK, so the second pass only needs a
# clean: angora-clang reads USE_TRACK when it is invoked.
RUN cd /unibench/flvmeta-1.2.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    cmake . &&\
    make -j && cp src/flvmeta /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j &&\
    cp src/flvmeta /d/p/taint/ && make clean

# --- imginfo (jasper, cmake) -----------------------------------------------
# ALLOW_IN_SOURCE_BUILD because the recipe builds in the source tree, as the
# other blocks do. No -Wno-error=implicit-function-declaration here: that is
# needed against a modern clang, and this toolchain is LLVM 4.0, which only
# warns.
RUN cd /unibench/jasper-2.0.12 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    cmake -DJAS_ENABLE_SHARED=OFF -DALLOW_IN_SOURCE_BUILD=ON . &&\
    make -j && cp src/appl/imginfo /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j &&\
    cp src/appl/imginfo /d/p/taint/ && make clean

# The five below complete the campaign target list (tools/volume/targets.conf).
# Recipes follow aflplusplus-reusing-target's, with each target built twice
# as above.

# --- wav2swf (swftools) ----------------------------------------------------
# Same two inline fixes as aflplusplus-reusing-target. Only lib/ and the one
# tool are built: a full `make` fails linking font2swf, as3compile, swfstrings
# and swfrender with this toolchain, none of which a campaign runs.
RUN cd /unibench/swftools-0.9.2 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure &&\
    sed -i 's/int inline ActionTagSize/int ActionTagSize/' lib/modules/swfaction.c &&\
    sed -i 's/byte inline PaethPredictor/byte PaethPredictor/' src/png2swf.c &&\
    make -j -C lib && make -C src wav2swf && cp src/wav2swf /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j -C lib && USE_TRACK=1 make -C src wav2swf &&\
    cp src/wav2swf /d/p/taint/ && make clean

# --- infotocap (ncurses tic) -----------------------------------------------
# --without-cxx: the C++ binding demo is not needed, as in the other arms.
# Copied under the name targets.conf uses.
RUN cd /unibench/ncurses-6.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    ./configure --disable-shared --without-cxx &&\
    make -j && cp progs/tic /d/p/fast/infotocap && make clean &&\
    USE_TRACK=1 make -j &&\
    cp progs/tic /d/p/taint/infotocap && make clean

# --- mp42aac (Bento4, cmake) -----------------------------------------------
RUN cd /unibench/Bento4-1.5.1-628 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake . &&\
    make -j mp42aac && cp mp42aac /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j mp42aac &&\
    cp mp42aac /d/p/taint/ && make clean

# --- nm (binutils-5279478) -------------------------------------------------
# Upstream directory name, for the same reason as tiffsplit's block. The
# nested configure is aflplusplus-reusing-target's. The track pass builds in
# a second copy of the tree so it starts from pristine sources rather than
# relying on distclean across the nested configure directories. Links the
# bundled zlib (-L.../zlib), which is instrumented along with the rest, so no
# abilist entry is needed.
RUN build_nm() { \
      MAKEINFO=true ./configure --disable-shared --disable-werror \
        --disable-gdb --disable-gdbserver --disable-gold &&\
      for i in bfd libiberty opcodes libctf; do \
        (cd $i && MAKEINFO=true ./configure --disable-shared --disable-werror && make -j) || return 1; \
      done &&\
      cd binutils && MAKEINFO=true ./configure --disable-shared --disable-werror &&\
      make nm-new; \
    } &&\
    cp -a /unibench/binutils_5279478 /tmp/nm_track &&\
    cd /unibench/binutils_5279478 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    build_nm && cp nm-new /d/p/fast/nm &&\
    cd /tmp/nm_track && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    export USE_TRACK=1 && build_nm && cp nm-new /d/p/taint/nm &&\
    rm -rf /tmp/nm_track

# --- objdump (binutils-2.28) -----------------------------------------------
RUN cd /unibench/binutils-2.28 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    ./configure --disable-shared LEXLIB= &&\
    make -j LEXLIB= && cp binutils/objdump /d/p/fast/ && make clean &&\
    USE_TRACK=1 make -j LEXLIB= &&\
    cp binutils/objdump /d/p/taint/ && make clean
