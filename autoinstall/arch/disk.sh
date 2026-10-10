#!/usr/bin/env bash
# arch/disk.sh — prepare the box's disk for the CachyOS (Arch) install.
#
#   arch_disk_prepare <dev> <mnt>
#     GPT: 1 GiB EFI System Partition (FAT32, label EFI) + the rest btrfs
#     (label tvbox) with subvolumes @ (root), @home, @var-log, @snapshots,
#     all mounted under <mnt> with noatime,compress=zstd:1,space_cache=v2;
#     the ESP is mounted at <mnt>/boot.
#
# Sourced by autoinstall/arch-install.sh; never run directly.
#
# Safety — all checked BEFORE anything touches the disk:
#   * TVBOX_CONFIRM_WIPE must name the exact device being wiped.
#   * Removable/USB disks are refused (lsblk RM=1 or TRAN=usb).
#   * The disk that holds the running live system is refused.
#   * Only whole disks are accepted — never a partition.
#
# Test hooks: TVBOX_DRY_RUN=1 prints every destructive command instead of
# running it (tests/arch-disk.bats fakes lsblk/findmnt on PATH).
set -euo pipefail

DRY="${TVBOX_DRY_RUN:-0}"
run() { if [ "$DRY" = 1 ]; then echo "DRY: $*"; else "$@"; fi; }
die() { printf 'arch-disk: %s\n' "$*" >&2; exit 1; }

# Partition device for <dev>, partition <n>: names ending in a digit
# (nvme0n1, mmcblk0) grow a 'p' before the number (nvme0n1p1);
# others do not (sda1).
part_dev() {  # part_dev <dev> <n>
  case "$(basename "$1")" in
    *[0-9]) printf '%sp%s' "$1" "$2" ;;
    *)      printf '%s%s' "$1" "$2" ;;
  esac
}

canon() {  # canon <device> — "/dev/sda" and "sda" compare equal
  local d="${1#/dev/}"
  printf '%s' "${d%/}"
}

# Disks backing the running root filesystem. Walks the whole chain so a
# btrfs-subvolume, LVM or LUKS root still resolves to its disk.
root_disks() {
  local src
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  src="${src%%\[*}"
  [ -n "$src" ] || return 0
  lsblk -srno NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}' || true
}

is_system_disk() {  # is_system_disk <dev>
  root_disks | grep -qx "$(basename "$1")"
}

arch_disk_prepare() {  # arch_disk_prepare <dev> <mnt>
  local dev="${1:-}" mnt="${2:-}"
  [ -n "$dev" ] && [ -n "$mnt" ] || die "usage: arch_disk_prepare <device> <mountpoint>"
  dev="/dev/${dev#/dev/}"

  # Nothing is ever written without an explicit, exact-device confirmation.
  [ -n "${TVBOX_CONFIRM_WIPE:-}" ] \
    || die "refusing to wipe $dev: set TVBOX_CONFIRM_WIPE=$dev to confirm"
  [ "$(canon "$TVBOX_CONFIRM_WIPE")" = "$(canon "$dev")" ] \
    || die "refusing: TVBOX_CONFIRM_WIPE=$TVBOX_CONFIRM_WIPE names a different device than $dev"

  [ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] || [ -n "${TVBOX_TEST_NOROOT:-}" ] \
    || die "run as root (the installer runs over SSH as root)"

  if [ "$DRY" != 1 ]; then
    local t
    for t in wipefs sgdisk mkfs.fat mkfs.btrfs btrfs mount umount findmnt lsblk; do
      command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
    done
  fi

  local info kind removable tran
  info="$(lsblk -dno TYPE,RM,TRAN "$dev" 2>/dev/null)" \
    || die "refusing: $dev is not a block device"
  read -r kind removable tran <<<"$info"
  [ "$kind" = disk ] || die "refusing: $dev is not a whole disk (lsblk says: ${kind:-nothing})"
  [ "$removable" = 0 ] || die "refusing: $dev is removable (RM=$removable)"
  [ "${tran:-}" != usb ] || die "refusing: $dev is a USB disk (TRAN=usb)"
  if is_system_disk "$dev"; then
    die "refusing: $dev holds the running live system"
  fi

  local esp btrfs_dev opts
  esp="$(part_dev "$dev" 1)"
  btrfs_dev="$(part_dev "$dev" 2)"
  opts="noatime,compress=zstd:1,space_cache=v2"

  run wipefs -a "$dev"
  run sgdisk --zap-all "$dev"
  run sgdisk --new=1:0:+1G --typecode=1:EF00 --change-name=1:EFI "$dev"
  run sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:tvbox "$dev"
  run mkfs.fat -F 32 -n EFI "$esp"
  run mkfs.btrfs -L tvbox "$btrfs_dev"

  run mkdir -p "$mnt"
  run mount -o "$opts" "$btrfs_dev" "$mnt"
  run btrfs subvolume create "$mnt/@"
  run btrfs subvolume create "$mnt/@home"
  run btrfs subvolume create "$mnt/@var-log"
  run btrfs subvolume create "$mnt/@snapshots"
  run umount "$mnt"
  run mount -o "$opts,subvol=@" "$btrfs_dev" "$mnt"
  run mkdir -p "$mnt/boot" "$mnt/home" "$mnt/var/log" "$mnt/snapshots"
  run mount -o "$opts,subvol=@home" "$btrfs_dev" "$mnt/home"
  run mount -o "$opts,subvol=@var-log" "$btrfs_dev" "$mnt/var/log"
  run mount -o "$opts,subvol=@snapshots" "$btrfs_dev" "$mnt/snapshots"
  run mount "$esp" "$mnt/boot"
}
