#!/usr/bin/env bash
# disks.sh — USB-HDD-safe storage manager.
#
#   disks.sh scan                      list candidate disks (blank / has data / system)
#   disks.sh add <dev> data|backup [label] [--yes] [--force]
#                                      format ext4 (blank disks only unless --force), register it
#   disks.sh adopt                     re-register disks this tool formatted earlier (label tvbox-*), e.g. after a re-flash
#   disks.sh sync                      idempotent: mount what is present, drop what vanished,
#                                      keep the SSD+HDD pool mounted. Safe to run every minute.
#   disks.sh status                    human summary (also used by `tvbox status`)
#
# Design (why it survives a loose USB cable):
#   * Disks are identified by filesystem UUID in /etc/tvbox/disks.conf, never by /dev/sdX.
#   * Pool = mergerfs( SSD landing dir  :  every healthy data disk ), create policy "ff" so
#     new writes always land on the SSD first (fast) — mover.sh drains them to the HDDs.
#   * The SSD landing branch is always present, so /mnt/pool never disappears when a USB
#     disk does; uploads simply keep landing on the SSD until the disk returns.
#   * Unmounted disk mountpoints are chattr +i, so nothing can silently write into an empty
#     mountpoint on the SSD. Every disk carries a .tvbox-disk sentinel, checked before use.
#   * Unplugged-but-still-mounted disks are detected by a timed sentinel read, lazily
#     unmounted, removed from the pool live, and re-added when the UUID reappears.
#
# Test hooks: DISKS_CONF, HDD_ROOT, LANDING_DIR, STORAGE_ROOT, TVBOX_DRY_RUN=1 (prints actions).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SENTINEL=".tvbox-disk"
DRY="${TVBOX_DRY_RUN:-0}"
MIN_FREE="${LANDING_MIN_FREE:-$(env_get LANDING_MIN_FREE 20G)}"
run() { if [ "$DRY" = 1 ]; then echo "DRY: $*"; else "$@"; fi; }

conf_lines() { [ -f "$DISKS_CONF" ] && grep -vE '^\s*(#|$)' "$DISKS_CONF" || true; }
mnt_of() { printf '%s/%s' "$HDD_ROOT" "$1"; }

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

# Disk answers within 5s and carries the right sentinel?
healthy() {  # healthy <mountpoint> <uuid>
  local got
  got="$(timeout 5 cat "$1/$SENTINEL" 2>/dev/null)" || return 1
  [ "$got" = "$2" ]
}

# ---------------------------------------------------------------- scan
# Every physical disk the running root filesystem sits on. Walks the whole device chain
# (btrfs subvolume suffix "[/@]", LVM, LUKS, RAID), so a non-plain-partition root is still found.
root_disks() {
  local src
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"; src="${src%%\[*}"
  [ -n "$src" ] || return 0
  lsblk -srno NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}' || true
}

is_system_disk() {  # is_system_disk /dev/sdX|sdX
  local d; d="$(basename "$1")"
  root_disks | grep -qx "$d"
}

# Disks with a mounted filesystem or active swap anywhere are in use: never format/offer them.
disk_in_use() {  # disk_in_use /dev/sdX
  lsblk -nro MOUNTPOINTS "$1" 2>/dev/null | grep -q . && return 0
  return 1
}

scan() {
  local name size tran model state children fstype
  printf '%-12s %-8s %-5s %-24s %s\n' DEVICE SIZE BUS MODEL STATE
  lsblk -dnpo NAME,SIZE,TRAN,MODEL,TYPE 2>/dev/null | while read -r name size tran model _; do
    [ -n "$name" ] || continue
    case "$(basename "$name")" in loop*|ram*|zram*|sr*) continue ;; esac
    if is_system_disk "$name"; then state="SYSTEM disk (never touched)"
    elif disk_in_use "$name"; then state="in use (mounted; never touched)"
    else
      children="$(lsblk -nro NAME "$name" | tail -n +2 | wc -l)"
      fstype="$(lsblk -ndo FSTYPE "$name" | head -n1)"
      if [ "$children" -eq 0 ] && [ -z "$fstype" ]; then state="blank (can be formatted)"
      elif lsblk -nro LABEL "$name" | grep -q '^tvbox-'; then state="tvbox disk (can be adopted)"
      else state="has data (needs --force to wipe)"; fi
    fi
    printf '%-12s %-8s %-5s %-24s %s\n' "$name" "$size" "${tran:--}" "${model:--}" "$state"
  done
}

# ---------------------------------------------------------------- add
add() {
  local dev="" role="" label="" yes=0 force=0 a
  for a in "$@"; do
    case "$a" in
      --yes) yes=1 ;; --force) force=1 ;;
      /dev/*) dev="$a" ;;
      data|backup) role="$a" ;;
      *) label="$a" ;;
    esac
  done
  [ -b "$dev" ] || die "usage: disks.sh add /dev/sdX data|backup [label] [--yes] [--force]"
  [ -n "$role" ] || die "role must be 'data' or 'backup'"
  is_system_disk "$dev" && die "$dev is the system disk — refusing (even with --force)"
  if lsblk -nro MOUNTPOINT "$dev" | grep -q .; then die "$dev has mounted partitions — unmount first"; fi
  [ -n "$label" ] || label="$role$(($(conf_lines | awk -F'|' -v r="$role" '$2==r' | wc -l) + 1))"
  local blank=0 children fstype
  children="$(lsblk -nro NAME "$dev" | tail -n +2 | wc -l)"; fstype="$(lsblk -ndo FSTYPE "$dev" | head -n1)"
  [ "$children" -eq 0 ] && [ -z "$fstype" ] && blank=1
  if [ "$blank" -eq 0 ] && [ "$force" -eq 0 ]; then die "$dev already contains data. Re-run with --force to ERASE it."; fi
  if [ "$yes" -eq 0 ]; then
    echo "About to ERASE $dev ($(lsblk -ndo SIZE,MODEL "$dev")) and format it as ext4 '$label' ($role)."
    printf 'Type ERASE %s to continue: ' "$(basename "$dev")"; read -r ans </dev/tty
    [ "$ans" = "ERASE $(basename "$dev")" ] || die "aborted — nothing changed"
  fi
  run wipefs -a "$dev"
  run parted -s "$dev" mklabel gpt mkpart "tvbox-$label" ext4 1MiB 100%
  run partprobe "$dev"; run udevadm settle
  local part; part="$(lsblk -nlpo NAME,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
  [ "$DRY" = 1 ] && part="${dev}1"
  # -m 0: no reserved blocks (this is a data disk, not a root fs). No lazy init: fail now, not later.
  run mkfs.ext4 -F -m 0 -L "tvbox-$label" -E lazy_itable_init=0,lazy_journal_init=0 "$part"
  local uuid; uuid="$([ "$DRY" = 1 ] && echo DRY-UUID || blkid -s UUID -o value "$part")"
  register "$uuid" "$role" "$label"
  ok "formatted $part as tvbox-$label ($role), UUID $uuid"
  sync_all
}

register() {  # register uuid role label — also writes the sentinel on first mount
  mkdir -p "$(dirname "$DISKS_CONF")"
  [ -f "$DISKS_CONF" ] || printf '# UUID|role|label   (managed by scripts/disks.sh)\n' > "$DISKS_CONF"
  grep -q "^$1|" "$DISKS_CONF" || printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$DISKS_CONF"
}

# ---------------------------------------------------------------- adopt
# After a re-flash /etc/tvbox is gone but the disks still carry their tvbox-<label> filesystem label.
# Non-destructive: nothing is formatted or written except the registry line.
adopt() {
  local n=0 name label uuid fstype role
  while read -r name label uuid fstype; do
    case "$label" in tvbox-*) ;; *) continue ;; esac
    [ "$fstype" = ext4 ] && [ -n "$uuid" ] || continue
    grep -q "^$uuid|" "$DISKS_CONF" 2>/dev/null && continue
    label="${label#tvbox-}"
    case "$label" in backup*) role=backup ;; *) role=data ;; esac
    register "$uuid" "$role" "$label"; ok "adopted $name as $label ($role)"; n=$((n + 1))
  done < <(lsblk -rno NAME,LABEL,UUID,FSTYPE 2>/dev/null | awk 'NF==4')
  [ "$n" -gt 0 ] || echo "adopt: nothing new to adopt"
}

# ---------------------------------------------------------------- sync
mount_disk() {  # mount_disk uuid label
  local uuid="$1" label="$2" mp dev
  mp="$(mnt_of "$label")"
  dev="/dev/disk/by-uuid/$uuid"
  [ -e "$dev" ] || return 1
  mkdir -p "$mp"
  if is_mounted "$mp"; then
    healthy "$mp" "$uuid" && return 0
    warn "$label: mounted but not answering — recovering"
    run umount -l "$mp" || true
  fi
  # Repair a dirty fs left by a yanked cable before mounting (no-op when clean).
  run fsck.ext4 -p "$dev" >/dev/null 2>&1 || true
  run chattr -i "$mp" 2>/dev/null || true
  # nofail/commit=60: do not hang boot for a missing USB disk, fewer journal flushes.
  run mount -o noatime,commit=60,errors=remount-ro "$dev" "$mp" || { warn "$label: mount failed"; return 1; }
  if [ ! -f "$mp/$SENTINEL" ]; then printf '%s' "$uuid" > "$mp/$SENTINEL"; fi
  healthy "$mp" "$uuid" || { warn "$label: sentinel mismatch — not using this disk"; run umount -l "$mp" || true; return 1; }
  ok "$label mounted at $mp"
}

drop_disk() {  # drop_disk label — disk vanished: stop pointing anything at it
  local mp; mp="$(mnt_of "$1")"
  if is_mounted "$mp"; then run umount -l "$mp" || true; warn "$1 disappeared — unmounted (pool keeps working from SSD)"; fi
  [ -d "$mp" ] && run chattr +i "$mp" 2>/dev/null || true
}

pool_mounted() { is_mounted "$STORAGE_ROOT"; }

mount_pool() {
  pool_mounted && return 0
  mkdir -p "$LANDING_DIR" "$STORAGE_ROOT"
  run chattr -i "$STORAGE_ROOT" 2>/dev/null || true
  # ff: first branch with room wins -> the SSD landing dir. minfreespace guards the SSD floor.
  run mergerfs -o "allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=ff,moveonenospc=true,minfreespace=$MIN_FREE,fsname=tvbox-pool" \
    "$LANDING_DIR" "$STORAGE_ROOT" || die "mergerfs mount failed"
  ok "pool mounted at $STORAGE_ROOT (SSD landing: $LANDING_DIR)"
}

pool_branches() { [ -e "$STORAGE_ROOT/.mergerfs" ] && getfattr --only-values -n user.mergerfs.branches "$STORAGE_ROOT/.mergerfs" 2>/dev/null | tr ':' '\n' || true; }

pool_set() {  # pool_set add|del <mountpoint>
  [ "$DRY" = 1 ] && { echo "DRY: pool $1 $2"; return 0; }
  case "$1" in
    add) pool_branches | grep -q "^$2" || setfattr -n user.mergerfs.branches -v "+>$2=RW" "$STORAGE_ROOT/.mergerfs" ;;
    del) pool_branches | grep -q "^$2" && setfattr -n user.mergerfs.branches -v "-$2" "$STORAGE_ROOT/.mergerfs" || true ;;
  esac
}

sync_all() {
  local uuid role label mp
  mount_pool
  while IFS='|' read -r uuid role label; do
    [ -n "$uuid" ] || continue
    mp="$(mnt_of "$label")"
    if mount_disk "$uuid" "$label"; then
      [ "$role" = data ] && pool_set add "$mp"
    else
      [ "$role" = data ] && pool_set del "$mp"
      drop_disk "$label"
    fi
  done < <(conf_lines)
}

# ---------------------------------------------------------------- status
status() {
  local uuid role label mp line n=0
  pool_mounted && echo "pool      : mounted at $STORAGE_ROOT" || echo "pool      : NOT mounted"
  [ -d "$LANDING_DIR" ] && echo "ssd cache : $(df -h --output=used,size,pcent "$LANDING_DIR" | tail -n1 | awk '{print $1" of "$2" ("$3")"}'), landing holds $(du -sh "$LANDING_DIR" 2>/dev/null | cut -f1)"
  while IFS='|' read -r uuid role label; do
    [ -n "$uuid" ] || continue; n=$((n + 1)); mp="$(mnt_of "$label")"
    if is_mounted "$mp" && healthy "$mp" "$uuid"; then
      line="$(df -h --output=used,size,pcent "$mp" | tail -n1 | awk '{print $1" of "$2" ("$3")"}')"
      printf '%-10s: %s ONLINE  %s\n' "$label" "$role" "$line"
    else printf '%-10s: %s OFFLINE (uploads keep landing on the SSD; reconnect the disk)\n' "$label" "$role"; fi
  done < <(conf_lines)
  [ "$n" -gt 0 ] || echo "disks     : none registered — run: sudo ./scripts/disks.sh scan"
}

case "${1:-status}" in
  scan) scan ;;
  adopt) need_root; adopt ;;
  add) shift; need_root; add "$@" ;;
  sync) need_root; sync_all ;;
  status) status ;;
  *) echo "usage: disks.sh scan|add|adopt|sync|status" >&2; exit 2 ;;
esac
