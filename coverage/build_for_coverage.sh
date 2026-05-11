#!/usr/bin/env bash
set -euo pipefail

PNG_SRC_ROOT="${PNG_SRC_ROOT:-$(pwd)}"
SHIM_SRC="${SHIM_SRC:-$PNG_SRC_ROOT/libfuzz-harness-proxy.c}"
OUT_DIR="${OUT_DIR:-/d/p/cov}"
PNG_PREFIX="${PNG_PREFIX:-COV_}"

mkdir -p "$OUT_DIR"
echo "[*] OUT_DIR = $OUT_DIR"

echo "[*] 1) libpng 옵션 일부 비활성화"
cp "$PNG_SRC_ROOT/scripts/pnglibconf.dfa" "$PNG_SRC_ROOT/scripts/pnglibconf.dfa.bak"
sed -e "s/option STDIO/option STDIO disabled/" \
    -e "s/option WARNING /option WARNING disabled/" \
    -e "s/option WRITE enables WRITE_INT_FUNCTIONS/option WRITE disabled/" \
    "$PNG_SRC_ROOT/scripts/pnglibconf.dfa.bak" > "$PNG_SRC_ROOT/scripts/pnglibconf.dfa"

echo "[*] 2) autotools 갱신"
autoreconf -f -i

echo "[*] 3) Coverage 빌드 디렉토리 생성"
BDIR="$PNG_SRC_ROOT/build-coverage"
rm -rf "$BDIR"
mkdir -p "$BDIR"
cd "$BDIR"

echo "[*] 4) configure"
export CC="gcc -fprofile-arcs -ftest-coverage"
export CXX="g++ -fprofile-arcs -ftest-coverage"
export LD="gcc"

"$PNG_SRC_ROOT/configure" \
  --disable-shared \
  --with-libpng-prefix="$PNG_PREFIX"

echo "[*] 5) make"
make -j$(nproc) clean
make -j$(nproc) libpng16.la

LIBPNG_A="$BDIR/.libs/libpng16.a"
if [[ ! -f "$LIBPNG_A" ]]; then
  echo "[-] 정적 라이브러리를 찾을 수 없습니다: $LIBPNG_A"
  exit 1
fi

echo "[*] 6) fuzzer 링크"
g++ -std=c++11 -O2 -fprofile-arcs -ftest-coverage \
    -I"$PNG_SRC_ROOT" -I. \
    "$PNG_SRC_ROOT/contrib/oss-fuzz/libpng_read_fuzzer.cc" \
    "$SHIM_SRC" \
    "$LIBPNG_A" -lz \
    -o "$OUT_DIR/libpng_read_fuzzer"

echo "[+] 생성됨: $OUT_DIR/libpng_read_fuzzer"
echo "[*] 완료!"
