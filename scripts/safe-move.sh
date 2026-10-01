#!/usr/bin/env bash
# safe-move.sh <src-file> <dest-dir> — move WITHOUT ever overwriting. Prints final path.
#   Same content (sha256) as the file already there -> $POOL/duplicates/<name>
#     (review it yourself, delete with ./duplicates.sh).
#   Different content -> Windows-style "name (1).ext", "name (2).ext", ... keep both.
set -euo pipefail
SRC="${1:?usage: safe-move.sh <src-file> <dest-dir>}"
DIR="${2:?usage: safe-move.sh <src-file> <dest-dir>}"
POOL="${POOL_ROOT:-/mnt/pool}"
DUP="$POOL/duplicates"
mkdir -p "$DIR"
name="$(basename "$SRC")"
if [[ "$name" == *.* && "$name" != .* ]]; then
  stem="${name%.*}"; ext=".${name##*.}"
else
  stem="$name"; ext=""
fi
if [ ! -e "$DIR/$name" ]; then
  mv "$SRC" "$DIR/$name"; echo "$DIR/$name"; exit 0
fi
if [ -f "$DIR/$name" ] && [ "$(sha256sum < "$SRC" | cut -d' ' -f1)" = "$(sha256sum < "$DIR/$name" | cut -d' ' -f1)" ]; then
  mkdir -p "$DUP"
  target="$DUP/$name"; i=1
  while [ -e "$target" ]; do i=$((i + 1)); target="$DUP/$stem ($i)$ext"; done
  mv "$SRC" "$target"; echo "$target"; exit 0
fi
i=1; target="$DIR/$stem ($i)$ext"
while [ -e "$target" ]; do i=$((i + 1)); target="$DIR/$stem ($i)$ext"; done
mv "$SRC" "$target"; echo "$target"
