FROM unifuzz/unibench:angora-reusing_step2
RUN apt-get update && apt-get install -y flex bison

RUN cd /unibench/binutils-2.28 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared LEXLIB= &&\
    make -j LEXLIB= &&\
    cp binutils/objdump /d/p/angora/fast/ &&\
    make clean && USE_TRACK=1 ASAN_OPTIONS="detect_leaks=0" make -j LEXLIB= &&\
    cp binutils/objdump /d/p/angora/taint/ &&\
    make clean

RUN cd /unibench/libpcap-1.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure --disable-shared &&\
    make -j &&\
    cd /unibench/tcpdump-4.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) && ./configure &&\
    make -j &&\
    cp tcpdump /d/p/angora/fast/ &&\
    cd /unibench/libpcap-1.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make clean && USE_TRACK=1 make -j &&\
    cd /unibench/tcpdump-4.8.1 && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    make clean && USE_TRACK=1 make -j &&\
    cp tcpdump /d/p/angora/taint/ &&\
    make clean && cd /unibench/libpcap-1.8.1 && make clean

# this will add /d/p/angora/fast/ffmpeg and /d/p/angora/taint/ffmpeg
RUN wget --quiet https://gitlab.com/unifuzz/unibench_build/raw/master/ffmpeg/angora.tar.gz &&\
    tar xf angora.tar.gz -C / &&\
    rm angora.tar.gz

RUN cd /unibench/jasper-2.0.12 && export ANGORA_PASS_LOG_DIR=$(pwd) && cmake -DJAS_ENABLE_SHARED=OFF -DALLOW_IN_SOURCE_BUILD=ON . &&\
    make -j &&\
    cp src/appl/imginfo /d/p/angora/fast/ &&\
    make clean && USE_TRACK=1 make -j &&\
    cp src/appl/imginfo /d/p/angora/taint/ &&\
    make clean

# Copy libpng build script
COPY target/libpng /unibench/libpng

# Build libpng for Angora
RUN cd /unibench/libpng && export ANGORA_PASS_LOG_DIR=$(pwd) &&\
    bash build_for_angora.sh &&\
    cp angora-out/libpng_angora.fast /d/p/angora/fast/libpng_read_fuzzer &&\
    cp angora-out/libpng_angora.taint /d/p/angora/taint/libpng_read_fuzzer

RUN ls -alh /d/p/angora/*