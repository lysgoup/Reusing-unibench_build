#!/usr/bin/env bash
set -euo pipefail

ANGORA_ROOT="${ANGORA_ROOT:-/angora}"
ANGORA_CC="$ANGORA_ROOT/bin/angora-clang"
ANGORA_CXX="$ANGORA_ROOT/bin/angora-clang++"

PNG_SRC_ROOT="${PNG_SRC_ROOT:-$(pwd)}"
SHIM_SRC="${SHIM_SRC:-$PNG_SRC_ROOT/libfuzz-harness-proxy.c}"
OUT_DIR="${OUT_DIR:-$PNG_SRC_ROOT/angora-out}"
PNG_PREFIX="${PNG_PREFIX:-ANGORA_}"

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

build_one () {
  local MODE="$1"
  local BDIR="$2"

  echo "[*] ========== $MODE 빌드 시작 =========="
  rm -rf "$BDIR"
  mkdir -p "$BDIR"
  pushd "$BDIR" >/dev/null

  export CC="$ANGORA_CC"
  export CXX="$ANGORA_CXX"
  export LD="$ANGORA_CC"

  if [[ "$MODE" == "TRACK" ]]; then
    export ANGORA_TAINT_RULE_LIST="/angora/bin/rules/zlib_abilist.txt"
  else
    unset ANGORA_TAINT_RULE_LIST || true
  fi

  "$PNG_SRC_ROOT/configure" \
    --disable-shared \
    --with-libpng-prefix="$PNG_PREFIX"

  make -j$(nproc) clean

  local BIN_OUT
  local LIBPNG_A="$BDIR/.libs/libpng16.a"

  if [[ "$MODE" == "TRACK" ]]; then
    USE_TRACK=1 LIBS="/angora/bin/lib/libZlibRt.a" make -j$(nproc) libpng16.la
    BIN_OUT="$OUT_DIR/libpng_angora.taint"
    USE_TRACK=1 "$ANGORA_CXX" -std=c++11 -O2 -I"$PNG_SRC_ROOT" -I. \
      -c "$PNG_SRC_ROOT/contrib/oss-fuzz/libpng_read_fuzzer.cc" \
      -o "$OUT_DIR/fuzzer_track.o"
    USE_TRACK=1 "$ANGORA_CC" -O2 \
      -c "$SHIM_SRC" \
      -o "$OUT_DIR/proxy_track.o"
    USE_TRACK=1 "$ANGORA_CXX" \
      "$OUT_DIR/fuzzer_track.o" "$OUT_DIR/proxy_track.o" \
      "$LIBPNG_A" /angora/bin/lib/libZlibRt.a -lz \
      -o "$BIN_OUT"
  else
    USE_FAST=1 make -j$(nproc) libpng16.la
    BIN_OUT="$OUT_DIR/libpng_angora.fast"
    USE_FAST=1 "$ANGORA_CXX" -std=c++11 -O2 -I"$PNG_SRC_ROOT" -I. \
      -c "$PNG_SRC_ROOT/contrib/oss-fuzz/libpng_read_fuzzer.cc" \
      -o "$OUT_DIR/fuzzer_fast.o"
    USE_FAST=1 "$ANGORA_CC" -O2 \
      -c "$SHIM_SRC" \
      -o "$OUT_DIR/proxy_fast.o"
    USE_FAST=1 "$ANGORA_CXX" \
      "$OUT_DIR/fuzzer_fast.o" "$OUT_DIR/proxy_fast.o" \
      "$LIBPNG_A" -lz \
      -o "$BIN_OUT"
  fi

  if [[ ! -f "$LIBPNG_A" ]]; then
    echo "[-] 정적 라이브러리를 찾을 수 없습니다: $LIBPNG_A"
    exit 1
  fi

  echo "[+] 생성됨: $BIN_OUT"
  popd >/dev/null
}

build_one "TRACK" "$PNG_SRC_ROOT/build-angora-track"
build_one "FAST"  "$PNG_SRC_ROOT/build-angora-fast"

echo "[*] 완료!"
echo "    - TRACK 실행파일: $OUT_DIR/libpng_angora.taint"
echo "    - FAST  실행파일: $OUT_DIR/libpng_angora.fast"
