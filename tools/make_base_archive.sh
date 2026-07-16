#!/bin/bash
##
# make_base_archive.sh SRC OUT.tar.gz
#
# Builds a coverage "base" snapshot (the iter_0000 baseline) with the internal
# path findings/queue/id:* that offline coverage (find "*/queue/id:*") replays.
# Idempotent (skips if OUT exists), concurrency-safe (unique mktemp + atomic mv).
# SRC is auto-detected, cheapest first:
#
#   (1) a .tar.gz FILE (a prebuilt full base, e.g. from a SATURATION_GEN run)
#       -> copied through. Cheapest: ~one compressed copy, no tar.
#
#   (2) a DIRECTORY of id:* files (a fuzzer findings/queue) -> tarred directly
#       (symlink + tar -h, original mtimes preserved). No per-file cp.
#
#   (3) a DIRECTORY of iter_*.tar.gz (a coverage-archive SERIES) -> every iter
#       extracted CUMULATIVELY and the union re-tarred. Correct for incremental
#       and full-snapshot formats. Heaviest (decompress+extract+recompress);
#       staging lives next to OUT (coverage fs), not /tmp.
##
set -e

SRC="$1"
OUT="$2"

if [ -z "$SRC" ] || [ -z "$OUT" ]; then
    echo "Usage: $0 SRC OUT.tar.gz   (SRC = .tar.gz file | dir of id:* | dir of iter_*.tar.gz)"
    exit 1
fi
if [ ! -e "$SRC" ]; then
    echo "[make_base] ERROR: source not found: $SRC"
    exit 1
fi
if [ -f "$OUT" ]; then
    echo "[make_base] exists, skipping: $OUT"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
OUT_TMP="$(mktemp "${OUT}.XXXXXX")"

if [ -f "$SRC" ]; then
    # (1) prebuilt full tar -> copy through.
    echo "[make_base] passthrough (prebuilt full tar): $SRC"
    cp -f "$SRC" "$OUT_TMP"
    mv -f "$OUT_TMP" "$OUT"
    echo "[make_base] $OUT  <-  $SRC  (copied prebuilt base)"
    exit 0
fi

if ls "$SRC"/iter_*.tar.gz >/dev/null 2>&1; then
    # (3) archive-series mode.
    n_iters=$(ls "$SRC"/iter_*.tar.gz 2>/dev/null | wc -l)
    echo "[make_base] archive-series mode: $n_iters iters from $SRC"
    STAGE="$(mktemp -d -p "$(dirname "$OUT")")"
    while IFS= read -r a; do
        tar xzf "$a" -C "$STAGE" 2>/dev/null || echo "[make_base] WARN: extract failed: $a"
    done < <(ls "$SRC"/iter_*.tar.gz | sort)
    if [ -d "$STAGE/findings" ]; then
        tar czf "$OUT_TMP" -C "$STAGE" --ignore-failed-read findings
        n=$(tar tzf "$OUT_TMP" 2>/dev/null | grep -c '/id:')
    else
        echo "[make_base] WARNING: no findings/ under extracted archives in $SRC"
        tar czf "$OUT_TMP" -T /dev/null 2>/dev/null
        n=0
    fi
    rm -rf "$STAGE"
else
    # (2) seed-dir mode.
    n=$(find "$SRC" -maxdepth 1 -name 'id:*' -type f 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] || echo "[make_base] WARNING: no 'id:*' files in $SRC (offline coverage only replays findings/queue/id:*)"
    SRC_REAL="$(realpath "$SRC")"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/findings"
    ln -s "$SRC_REAL" "$TMP/findings/queue"
    tar czhf "$OUT_TMP" -C "$TMP" --ignore-failed-read findings/queue
    rm -rf "$TMP"
fi

mv -f "$OUT_TMP" "$OUT"
echo "[make_base] $OUT  <-  $SRC  ($n id:* files)"
