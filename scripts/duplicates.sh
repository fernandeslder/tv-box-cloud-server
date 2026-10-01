#!/usr/bin/env bash
# duplicates.sh — review or delete exact-duplicate files in $POOL/duplicates/.
# Usage: duplicates.sh list | purge
#   list:  path, size, sha12 of each duplicate.
#   purge: asks per file, then deletes what you confirm. Nothing else is touched.
set -euo pipefail
POOL="${POOL_ROOT:-/mnt/pool}"
DUP="$POOL/duplicates"
CMD="${1:?usage: duplicates.sh list|purge}"
[ -d "$DUP" ] || { echo "no duplicates dir yet"; exit 0; }
case "$CMD" in
  list)
    find "$DUP" -type f -printf '%s %p\n' | sort -n | while read -r size path; do
      echo "$size bytes  $path  sha:$(sha256sum < "$path" | cut -c1-12)"
    done
    ;;
  purge)
    find "$DUP" -type f | sort | while read -r f; do
      ls -la "$f"
      printf 'delete %s? [y/N] ' "$f" >/dev/tty
      read -r ans </dev/tty
      [ "$ans" = "y" ] && rm -v "$f"
    done
    ;;
  *) echo "usage: duplicates.sh list|purge" >&2; exit 2;;
esac
