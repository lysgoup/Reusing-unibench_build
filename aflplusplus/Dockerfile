FROM yunseo/aflplusplus

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

# Copy libpng build script
COPY target/libpng /unibench/libpng

# Build libpng for Angora
RUN cd /unibench/libpng &&\
    bash build_for_aflpp.sh &&\
    cp afl-out/libpng_read_fuzzer /d/p/aflplusplus/libpng_read_fuzzer

RUN ls -alh /d/p/*

# Install daemontools for multilog
RUN apt-get update && apt-get install -y daemontools && rm -rf /var/lib/apt/lists/*