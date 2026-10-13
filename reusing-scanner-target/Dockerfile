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

RUN git clone --depth=1 https://github.com/UNIFUZZ/unibench /unibench &&\
    cd /unibench &&\
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
# Keeps -fno-builtin: 0.8% timeouts, 0.47 s per seed, the fastest of the four.
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
