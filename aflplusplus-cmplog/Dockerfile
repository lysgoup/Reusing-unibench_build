#
# Build context: $UNIBENCH/../ (default else-branch in tools/build.sh), i.e.
# COPY paths below need the Reusing-unibench_build/ prefix.
#
# AFL++ with cmplog ON, auto-extras OFF -- for exiv2/mp3gain/mujs/imginfo/
# infotocap/lame/jq/tiffsplit only (see
# tools/captainrc_aflpp_autoextras_compare's target set; add more RUN blocks
# below, mirroring the pattern, if more targets are needed later).
#
# Same self-contained clone+patch base as ../aflplusplus/Dockerfile (same
# AFLPP_COMMIT, same dryrun_finish.patch + no_auto_extras.patch -- reused
# directly from ../aflplusplus/, not duplicated). Auto-extras OFF is baked
# into tools/volume/aflplusplus-cmplog/run.sh (export AFL_NO_AUTO_EXTRAS=1),
# same as ../aflplusplus/run.sh.
#
# cmplog requires a SECOND, separately-instrumented binary per target (AFL++
# reads its own logged comparisons from a build compiled with
# AFL_LLVM_CMPLOG=1, then afl-fuzz is pointed at it via `-c`) -- unlike
# AFL_NO_AUTO_EXTRAS, this can't be a pure runtime toggle. Each target below
# is built twice: normal binary first (unmodified recipe from
# ../aflplusplus/Dockerfile), then `make clean` + AFL_LLVM_CMPLOG=1 + same
# build command again, copied to a separate cmplog/ subdirectory. No second
# `cmake`/`configure` needed -- CC stays afl-clang-fast throughout, and
# AFL_LLVM_CMPLOG is read by afl-clang-fast itself during compilation, not
# by the target's own build system.
#
FROM ubuntu:24.04 AS aflplusplus-cmplog
LABEL "maintainer"="AFL++ team <afl@aflplus.plus>"
LABEL "about"="AFL++ docker container image (cmplog ON, auto-extras OFF)"

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

# Pinned to the same commit as ../aflplusplus/Dockerfile -- bump deliberately,
# not implicitly via `main`, and keep both in sync if you do.
ARG AFLPP_COMMIT=05507e1880dc6df997c19e01423444ef37c36846

WORKDIR /AFLplusplus
RUN git clone https://github.com/AFLplusplus/AFLplusplus.git . && \
    git checkout ${AFLPP_COMMIT}

# Same two patches as ../aflplusplus/Dockerfile, reused directly (not
# duplicated) -- dryrun_finish marker + runtime AFL_NO_AUTO_EXTRAS toggle.
COPY Reusing-unibench_build/aflplusplus/dryrun_finish.patch /tmp/dryrun_finish.patch
RUN git apply /tmp/dryrun_finish.patch && rm /tmp/dryrun_finish.patch

COPY Reusing-unibench_build/aflplusplus/no_auto_extras.patch /tmp/no_auto_extras.patch
RUN git apply /tmp/no_auto_extras.patch && rm /tmp/no_auto_extras.patch

ARG CC=gcc-$GCC_VERSION
ARG CXX=g++-$GCC_VERSION

RUN python3 -m venv .venv
ENV PATH="/AFLplusplus/.venv/bin:$PATH"

# The CFLAGS_FLTO neutering (2nd -e) works around a GCC 11 LTO
# internal-compiler-error (ICE) in XXH3_hashLong_64b_default's SSE2
# intrinsics during whole-program codegen -- observed as a flaky, but
# eventually consistent, build failure in aflplusplus-reusing's own build
# (same GCC 11.5.0, same xxHash-via-afl-performance.c code path); disabled
# here too so all fuzzer variants being compared get afl-fuzz built the
# same way (LTO on for one and off for another would itself be a confound
# in any cross-fuzzer throughput comparison).
RUN sed -i.bak -e 's/^	-/	/g' -e 's/CFLAGS_FLTO ?= -flto.*/CFLAGS_FLTO ?=/' GNUmakefile && \
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

RUN mkdir -p /d/p/aflplusplus-cmplog/cmplog &&\
    apt update && apt install -y nasm libglib2.0-dev gtk-doc-tools libtiff-dev libpng-dev tcl-dev

# exiv2: normal binary, then make clean + AFL_LLVM_CMPLOG=1 + same build
# again (no second cmake -- CC is unchanged, cmplog is compile-time env only).
RUN cd /unibench/exiv2-0.26 && \
    sed -i '86c\set(GCC_MINOR 0)' CMakeLists.txt && \
    sed -i '/extern int strerror_r/d' src/futils.cpp && \
    cmake \
      -DEXIV2_ENABLE_SHARED=OFF \
      -DEXIV2_ENABLE_NLS=OFF \
      -DCMAKE_C_FLAGS="-std=gnu99" \
      . && \
    make -j && \
    cp bin/exiv2 /d/p/aflplusplus-cmplog/ && \
    make clean && \
    AFL_LLVM_CMPLOG=1 make -j && \
    cp bin/exiv2 /d/p/aflplusplus-cmplog/cmplog/

RUN cd /unibench/mp3gain-1.5.2 && sed -i 's/CC=/CC?=/' Makefile &&\
    make -j &&\
    cp mp3gain /d/p/aflplusplus-cmplog/ &&\
    make clean &&\
    AFL_LLVM_CMPLOG=1 make -j &&\
    cp mp3gain /d/p/aflplusplus-cmplog/cmplog/

RUN cd /unibench/mujs-1.0.2 &&\
    build=debug make -j &&\
    cp build/debug/mujs /d/p/aflplusplus-cmplog/ &&\
    make clean &&\
    AFL_LLVM_CMPLOG=1 build=debug make -j &&\
    cp build/debug/mujs /d/p/aflplusplus-cmplog/cmplog/

RUN cd /unibench/jasper-2.0.12 && \
    cmake -DJAS_ENABLE_SHARED=OFF -DALLOW_IN_SOURCE_BUILD=ON -DCMAKE_C_FLAGS="-Wno-shift-negative-value -Wno-implicit-function-declaration" . &&\
    make -j &&\
    cp src/appl/imginfo /d/p/aflplusplus-cmplog/ &&\
    make clean &&\
    AFL_LLVM_CMPLOG=1 make -j &&\
    cp src/appl/imginfo /d/p/aflplusplus-cmplog/cmplog/

RUN cd /unibench/ncurses-6.1 && ./configure --disable-shared &&\
    make -j &&\
    cp progs/tic /d/p/aflplusplus-cmplog/infotocap &&\
    make clean &&\
    AFL_LLVM_CMPLOG=1 make -j &&\
    cp progs/tic /d/p/aflplusplus-cmplog/cmplog/infotocap

RUN cd /unibench/lame-3.99.5 && ./configure --disable-shared &&\
    make -j &&\
    cp frontend/lame /d/p/aflplusplus-cmplog/ &&\
    make clean &&\
    AFL_LLVM_CMPLOG=1 make -j &&\
    cp frontend/lame /d/p/aflplusplus-cmplog/cmplog/

RUN cd /unibench/jq-1.5 && ./configure --disable-shared &&\
    make -j &&\
    cp jq /d/p/aflplusplus-cmplog/ &&\
    make clean &&\
    AFL_LLVM_CMPLOG=1 make -j &&\
    cp jq /d/p/aflplusplus-cmplog/cmplog/

RUN cd /unibench/libtiff-3.9.7 && ./autogen.sh && ./configure --disable-shared &&\
    make -j &&\
    cp tools/tiffsplit /d/p/aflplusplus-cmplog/ &&\
    make clean &&\
    AFL_LLVM_CMPLOG=1 make -j &&\
    cp tools/tiffsplit /d/p/aflplusplus-cmplog/cmplog/

RUN ls -alh /d/p/aflplusplus-cmplog/ /d/p/aflplusplus-cmplog/cmplog/

# Install daemontools for multilog
RUN apt-get update && apt-get install -y daemontools && rm -rf /var/lib/apt/lists/*
