#!/bin/bash
##
# make_base_archive.sh SEED_DIR OUT.tar.gz
#
# Builds a coverage "base" snapshot (the iter_0000 baseline) from a seed
# directory, with the internal path findings/queue/id:* that the offline
# coverage tool (coverage/entrypoint_offline.sh: find "*/findings/queue/id:*")
# expects. Used for saturation-seed experiments so the fixed saturation corpus
# is the controlled t=0 baseline, instead of re-dumping the ~100k dry-run queue
# into iter_0000 on every run.
#
# - Idempotent: if OUT already exists, does nothing (base is shared per target).
# - No per-file cp: a symlink + `tar -h` archives the real seeds directly, and
#   original file mtimes are preserved.
##
set -e

SEED_DIR="$1"
OUT="$2"

if [ -z "$SEED_DIR" ] || [ -z "$OUT" ]; then
    echo "Usage: $0 SEED_DIR OUT.tar.gz"
    exit 1
fi
if [ ! -d "$SEED_DIR" ]; then
    echo "[make_base] ERROR: seed dir not found: $SEED_DIR"
    exit 1
fi
if [ -f "$OUT" ]; then
    echo "[make_base] exists, skipping: $OUT"
    exit 0
fi

SEED_DIR="$(realpath "$SEED_DIR")"
n_id=$(find "$SEED_DIR" -maxdepth 1 -name 'id:*' -type f 2>/dev/null | wc -l)
if [ "$n_id" -eq 0 ]; then
    echo "[make_base] WARNING: no 'id:*' files in $SEED_DIR"
    echo "[make_base] (offline coverage only replays files matching findings/queue/id:*)"
fi

mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp -d)
mkdir -p "$TMP/findings"
ln -s "$SEED_DIR" "$TMP/findings/queue"

# -h dereferences the symlink: real seeds are stored under findings/queue/,
# with their original mtimes. Recurses the directory, so no argument-list limit.
# Unique temp output + atomic mv => safe if two campaigns build the same base.
OUT_TMP="$(mktemp "${OUT}.XXXXXX")"
tar czhf "$OUT_TMP" -C "$TMP" findings/queue
mv -f "$OUT_TMP" "$OUT"
rm -rf "$TMP"

echo "[make_base] $OUT  <-  $SEED_DIR  ($n_id id:* seeds)"
