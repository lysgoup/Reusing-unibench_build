#
# Build context: $UNIBENCH/../ (default else-branch in tools/build.sh), i.e.
# COPY paths below need the Reusing-unibench_build/ prefix.
#
# Self-contained clone+patch build, mirroring forkserver_libafl/Dockerfile's
# pattern: clone upstream AFL++ straight from GitHub inside the image (no
# host checkout dependency), pin a commit for reproducibility, apply our
# dryrun_finish.patch, then build. Base stage content (deps/LLVM/GCC
# versions, build recipe) is copied from upstream's own Dockerfile
# (AFLplusplus/Dockerfile) with `COPY . .` swapped for `git clone` + `git
# apply` since we have no local source tree to COPY here.
#
FROM ubuntu:24.04 AS aflplusplus
LABEL "maintainer"="AFL++ team <afl@aflplus.plus>"
LABEL "about"="AFL++ docker container image (plain, no taint tracking)"

ENV NO_CORESIGHT=1
ENV NO_NYX=1
ENV LLVM_VERSION=20
ENV GCC_VERSION=11

ARG DEBIAN_FRONTEND=noninteractive

ENV NO_ARCH_OPT=1
ENV IS_DOCKER=1

RUN apt-get update && apt-get full-upgrade -y && \
    apt-get install -y --no-install-recommends wget ca-certificates apt-utils && \
    rm -rf /var/lib/apt/lists/*

RUN apt-get update && \
    apt-get -y install --no-install-recommends \
    make cmake automake meson ninja-build bison flex \
    git xz-utils bzip2 wget jupp nano bash-completion less vim joe ssh psmisc \
    python3 python3-dev python3-pip python-is-python3 python3-venv \
    libtool libtool-bin libglib2.0-dev \
    apt-transport-https gnupg dialog \
    gnuplot-nox libpixman-1-dev bc \
    gcc-${GCC_VERSION} g++-${GCC_VERSION} gcc-${GCC_VERSION}-plugin-dev gdb lcov \
    clang-${LLVM_VERSION} clang-tools-${LLVM_VERSION} libc++1-${LLVM_VERSION} \
    libc++-${LLVM_VERSION}-dev libc++abi1-${LLVM_VERSION} libc++abi-${LLVM_VERSION}-dev \
    libclang1-${LLVM_VERSION} libclang-${LLVM_VERSION}-dev \
    libclang-common-${LLVM_VERSION}-dev libclang-rt-${LLVM_VERSION}-dev libclang-cpp${LLVM_VERSION} \
    libclang-cpp${LLVM_VERSION}-dev liblld-${LLVM_VERSION} \
    liblld-${LLVM_VERSION}-dev liblldb-${LLVM_VERSION} liblldb-${LLVM_VERSION}-dev \
    libllvm${LLVM_VERSION} libomp-${LLVM_VERSION}-dev libomp5-${LLVM_VERSION} \
    lld-${LLVM_VERSION} lldb-${LLVM_VERSION} llvm-${LLVM_VERSION} \
    llvm-${LLVM_VERSION}-dev llvm-${LLVM_VERSION}-runtime llvm-${LLVM_VERSION}-tools \
    gcc-${GCC_VERSION}-multilib gcc-multilib && \
    rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 0 && \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} 0 && \
    update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-${GCC_VERSION} 0 && \
    update-alternatives --install /usr/bin/clang clang /usr/bin/clang-${LLVM_VERSION} 0 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-${LLVM_VERSION} 0

RUN wget -qO- https://sh.rustup.rs | CARGO_HOME=/etc/cargo sh -s -- -y -q --no-modify-path
ENV PATH=$PATH:/etc/cargo/bin

RUN apt clean -y

ENV LLVM_CONFIG=llvm-config-${LLVM_VERSION}
ENV AFL_SKIP_CPUFREQ=1
ENV AFL_TRY_AFFINITY=1
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1

# Pinned to the same commit already validated locally in a plain checkout
# (/home/yunseo/AFLplusplus) -- bump deliberately, not implicitly via `main`.
ARG AFLPP_COMMIT=05507e1880dc6df997c19e01423444ef37c36846

WORKDIR /AFLplusplus
RUN git clone https://github.com/AFLplusplus/AFLplusplus.git . && \
    git checkout ${AFLPP_COMMIT}

# Adds a dryrun_finish marker at <out_dir>/queue/signal/dryrun_finish once
# initial seed calibration (perform_dry_run) completes -- same marker
# AFLplusplus_reusing's afl-fuzz.c and angora-reusing already emit, so
# start.sh's watch_dryrun / archive_queue.sh's dryrun-wait work unmodified
# against this fuzzer too.
COPY Reusing-unibench_build/aflplusplus/dryrun_finish.patch /tmp/dryrun_finish.patch
RUN git apply /tmp/dryrun_finish.patch && rm /tmp/dryrun_finish.patch

# Adds a runtime AFL_NO_AUTO_EXTRAS toggle (mirrors AFL_NO_FASTRESUME's
# existing pattern in afl-fuzz-state.c/afl-fuzz.h/envs.h): a single guard in
# maybe_add_auto() (src/afl-fuzz-extras.c), the sole writer of
# afl->a_extras[], so it kills both live collection (bitflip/effector-map
# stage + redqueen) and resume-time reload (load_auto() funnels through the
# same function) without touching the MAX_AUTO_EXTRAS/USE_AUTO_EXTRAS
# compile-time constants. Applied after dryrun_finish.patch -- both touch
# src/afl-fuzz.c but at disjoint locations (dry-run marker vs. help text),
# verified to apply cleanly in this order.
COPY Reusing-unibench_build/aflplusplus/no_auto_extras.patch /tmp/no_auto_extras.patch
RUN git apply /tmp/no_auto_extras.patch && rm /tmp/no_auto_extras.patch

ARG CC=gcc-$GCC_VERSION
ARG CXX=g++-$GCC_VERSION

RUN python3 -m venv .venv
ENV PATH="/AFLplusplus/.venv/bin:$PATH"

RUN sed -i.bak 's/^	-/	/g' GNUmakefile && \
    make clean && make distrib && make install && \
    mv GNUmakefile.bak GNUmakefile

RUN echo "set encoding=utf-8" > /root/.vimrc && \
    echo ". /etc/bash_completion" >> ~/.bashrc && \
    echo 'alias joe="joe --wordwrap --joe_state -nobackup"' >> ~/.bashrc && \
    echo "export PS1='"'[AFL++ \h] \w \$ '"'" >> ~/.bashrc

ENV CC=afl-clang-fast
ENV CXX=afl-clang-fast++

RUN apt-get update && apt-get install -y unzip git build-essential sudo

ARG USER_ID=1009
ARG GROUP_ID=1009

RUN mv /AFLplusplus /aflplusplus

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

RUN apt update && apt install -y gettext autotools-dev pkg-config texinfo

RUN mkdir -p /d/p/aflplusplus &&\
    apt update && apt install -y nasm libglib2.0-dev gtk-doc-tools libtiff-dev libpng-dev tcl-dev

RUN cd /unibench/exiv2-0.26 && \
    sed -i '86c\set(GCC_MINOR 0)' CMakeLists.txt && \
    sed -i '/extern int strerror_r/d' src/futils.cpp && \
    cmake \
      -DEXIV2_ENABLE_SHARED=OFF \
      -DEXIV2_ENABLE_NLS=OFF \
      -DCMAKE_C_FLAGS="-std=gnu99" \
      . && \
    make -j && \
    cp bin/exiv2 /d/p/aflplusplus/

# RUN cd /unibench/gdk-pixbuf-2.31.1 && ./configure --enable-static=yes --enable-shared=no --with-included-loaders=yes &&\
#     make -j &&\
#     cp gdk-pixbuf/gdk-pixbuf-pixdata /d/p/aflplusplus/

RUN cd /unibench/jasper-2.0.12 && \
    cmake -DJAS_ENABLE_SHARED=OFF -DALLOW_IN_SOURCE_BUILD=ON -DCMAKE_C_FLAGS="-Wno-shift-negative-value -Wno-implicit-function-declaration" . &&\
    make -j &&\
    cp src/appl/imginfo /d/p/aflplusplus/

RUN cd /unibench/jhead-3.00 &&\
    make -j &&\
    cp jhead /d/p/aflplusplus/

RUN cd /unibench/libtiff-3.9.7 && ./autogen.sh && ./configure --disable-shared &&\
    make -j &&\
    cp tools/tiffsplit /d/p/aflplusplus/

RUN cd /unibench/lame-3.99.5 && ./configure --disable-shared &&\
    make -j &&\
    cp frontend/lame /d/p/aflplusplus/

RUN cd /unibench/mp3gain-1.5.2 && sed -i 's/CC=/CC?=/' Makefile &&\
    make -j &&\
    cp mp3gain /d/p/aflplusplus/

RUN cd /unibench/swftools-0.9.2/ && ./configure CFLAGS="-fcommon" &&\
    make -j &&\
    cp src/wav2swf /d/p/aflplusplus/

RUN cd /unibench/flvmeta-1.2.1 && cmake . &&\
    make -j &&\
    cp src/flvmeta /d/p/aflplusplus/

RUN cd /unibench/Bento4-1.5.1-628 && cmake . &&\
    make -j &&\
    cp mp42aac /d/p/aflplusplus/

RUN cd /unibench/cflow-1.6 && ./configure CFLAGS="-Wno-incompatible-function-pointer-types" &&\
    make -j &&\
    cp src/cflow /d/p/aflplusplus/

RUN cd /unibench/ncurses-6.1 && ./configure --disable-shared &&\
    make -j &&\
    cp progs/tic /d/p/aflplusplus/infotocap

RUN cd /unibench/jq-1.5 && ./configure --disable-shared &&\
    make -j &&\
    cp jq /d/p/aflplusplus/

RUN cd /unibench/mujs-1.0.2 &&\
    build=debug make -j &&\
    cp build/debug/mujs /d/p/aflplusplus/

RUN cd /unibench/xpdf-4.00 && cmake -DCMAKE_CXX_FLAGS="-Wno-dynamic-exception-spec" . &&\
    make -j &&\
    cp xpdf/pdftotext /d/p/aflplusplus/

RUN apt install -y tcl-dev &&\
    cd /unibench/SQLite-3.8.9 && ./configure --disable-shared --disable-amalgamation  &&\
    make -j &&\
    cp sqlite3 /d/p/aflplusplus/

RUN cd /unibench && rm -rf binutils-5279478-build && mkdir binutils-5279478-build && cd binutils-5279478-build &&\
    ../binutils-5279478/configure --disable-shared --disable-gdb &&\
    make -j &&\
    cp binutils/nm-new /d/p/aflplusplus/nm

RUN cd /unibench/binutils-2.28 && ./configure --disable-shared &&\
    make -j &&\
    cp binutils/objdump /d/p/aflplusplus/

# RUN cd /unibench/libpcap-1.8.1 && ./configure --disable-shared &&\
#     make -j &&\
#     cd /unibench/tcpdump-4.8.1 && ./configure &&\
#     make -j &&\
#     cp tcpdump /d/p/aflplusplus/

RUN rm -r /unibench/ffmpeg-4.0.1 &&\
    wget --quiet https://gitlab.com/unifuzz/unibench_build/raw/master/ffmpeg/coverage.tar.gz &&\
    tar xf coverage.tar.gz -C / &&\
    rm coverage.tar.gz &&\
    cp /unibench/ffmpeg-4.0.1/ffmpeg_g /d/p/aflplusplus/ffmpeg

# libpng intentionally skipped: no working build_for_aflpp.sh exists anywhere
# in this tree (the old `COPY target/libpng` here pointed at a path that
# doesn't exist in the build context), and aflplusplus-reusing-target/
# Dockerfile skips it for the same reason ("libpng uses a custom
# libFuzzer-harness build script" that was never written for AFL++). Revisit
# by porting angora-reusing-target/Dockerfile's libpng recipe if needed.

RUN ls -alh /d/p/*

# Install daemontools for multilog
RUN apt-get update && apt-get install -y daemontools && rm -rf /var/lib/apt/lists/*