#!/usr/bin/env bash
# mover.sh — drain the SSD landing zone to the HDDs (write-back cache flush).
#
# Uploads hit /mnt/pool, which mergerfs lands on the SSD (fast). This script copies
# settled files to the healthiest data HDD, verifies, then removes the SSD copy.
#
# Policy (env or docker/.env):
#   MOVER_MIN_AGE_MIN   a file must be untouched this long before it moves   (default 15)
#   MOVER_KEEP_DAYS     keep files on the SSD this long as a read cache,
#                       unless the SSD is above the high-water mark          (default 3)
#   MOVER_HIGH_PCT      SSD used% that forces draining regardless of age     (default 70)
#   MOVER_LOW_PCT       drain-until target when over the high-water mark     (default 50)
# Never moves into a disk that is offline or fails its sentinel check — files simply
# stay on the SSD until the disk is back. Single instance (flock).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MIN_AGE="${MOVER_MIN_AGE_MIN:-$(env_get MOVER_MIN_AGE_MIN 15)}"
KEEP_DAYS="${MOVER_KEEP_DAYS:-$(env_get MOVER_KEEP_DAYS 3)}"
HIGH="${MOVER_HIGH_PCT:-$(env_get MOVER_HIGH_PCT 70)}"
LOW="${MOVER_LOW_PCT:-$(env_get MOVER_LOW_PCT 50)}"
SENTINEL=".tvbox-disk"
LOCK="${MOVER_LOCK:-/run/tvbox-mover.lock}"
DRY="${TVBOX_DRY_RUN:-0}"

exec 9>"$LOCK" || die "cannot open lock $LOCK"
flock -n 9 || { echo "mover: already running"; exit 0; }

[ -d "$LANDING_DIR" ] || { echo "mover: no landing dir $LANDING_DIR"; exit 0; }

used_pct() { df --output=pcent "$LANDING_DIR" | tail -n1 | tr -dc '0-9'; }

# Pick the online data disk with the most free space. Prints its mountpoint or nothing.
pick_target() {
  local uuid role label mp best="" bestfree=-1 free
  [ -f "$DISKS_CONF" ] || return 0
  while IFS='|' read -r uuid role label; do
    [ "$role" = data ] || continue
    mp="$HDD_ROOT/$label"
    mountpoint -q "$mp" 2>/dev/null || continue
    [ "$(timeout 5 cat "$mp/$SENTINEL" 2>/dev/null || true)" = "$uuid" ] || continue
    free="$(df -B1 --output=avail "$mp" | tail -n1 | tr -dc '0-9')"
    if [ "${free:-0}" -gt "$bestfree" ]; then best="$mp"; bestfree="$free"; fi
  done < <(grep -vE '^\s*(#|$)' "$DISKS_CONF")
  [ -n "$best" ] && printf '%s' "$best"
}

TARGET="${MOVER_TARGET:-$(pick_target)}"
if [ -z "$TARGET" ]; then
  echo "mover: no healthy data disk online — files stay on the SSD (cache at $(used_pct)%)"
  exit 0
fi

# What to move. Normal pass: settled AND older than the keep window.
# Over the high-water mark: everything settled, oldest first, until under LOW.
LIST="$(mktemp)"; trap 'rm -f "$LIST"' EXIT
select_files() {  # select_files <extra find args...> ; paths relative to landing, oldest first
  ( cd "$LANDING_DIR" && find . -type f -mmin "+$MIN_AGE" "$@" -printf '%T@ %P\0' \
      | sort -z -n | cut -z -d' ' -f2- ) > "$LIST"
}

if [ "$(used_pct)" -ge "$HIGH" ]; then
  echo "mover: SSD at $(used_pct)% (>= $HIGH) — draining aggressively toward $LOW%"
  select_files
  aggressive=1
else
  select_files -mtime "+$KEEP_DAYS"
  aggressive=0
fi

[ -s "$LIST" ] || { echo "mover: nothing to move (SSD at $(used_pct)%)"; exit 0; }

moved=0; failed=0
while IFS= read -r -d '' rel; do
  if [ "$aggressive" = 1 ] && [ "$(used_pct)" -le "$LOW" ]; then break; fi
  src="$LANDING_DIR/$rel"; dst="$TARGET/$rel"
  [ -f "$src" ] || continue
  if [ "$DRY" = 1 ]; then echo "DRY: move $rel -> $TARGET"; moved=$((moved + 1)); continue; fi
  mkdir -p "$(dirname "$dst")"
  # Copy keeping owners/perms/xattrs/times; delete the source only after rsync confirms.
  if rsync -a --xattrs --no-whole-file "$src" "$dst.tvbox-part" 2>/dev/null \
     && mv -f "$dst.tvbox-part" "$dst" \
     && cmp -s "$src" "$dst"; then
    rm -f "$src"; moved=$((moved + 1))
  else
    rm -f "$dst.tvbox-part"; failed=$((failed + 1))
    echo "mover: FAILED $rel (kept on SSD)" >&2
    # A failure usually means the disk just vanished — stop instead of hammering it.
    [ "$(timeout 5 cat "$TARGET/$SENTINEL" 2>/dev/null || true)" ] || { echo "mover: target went away, stopping" >&2; break; }
  fi
done < "$LIST"

# Empty directories are deliberately left behind: inbox/, Photos/ ... must keep existing
# (Samba shares + container bind mounts point at them), and they cost nothing.
echo "mover: moved $moved, failed $failed, SSD now $(used_pct)%"
[ "$failed" -eq 0 ]
