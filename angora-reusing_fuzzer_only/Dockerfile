FROM unifuzz/unibench:angora-reusing

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PIN_ROOT=/pin-3.7-97619-g0d0c92f4f-gcc-linux \
    GOPATH=/go \
    PATH=/clang+llvm/bin:/usr/local/cargo/bin:/angora/bin/:/go/bin:$PATH \
    LD_LIBRARY_PATH=/clang+llvm/lib:$LD_LIBRARY_PATH \
    CC= \
    CXX=

# Install daemontools for multilog
RUN apt-get update && apt-get install -y daemontools && rm -rf /var/lib/apt/lists/*

COPY fuzzer angora/fuzzer
COPY build angora/build
WORKDIR /angora

RUN ./build/build.sh

# WORKDIR /data
# ENTRYPOINT [ "/opt/env.init" ]
