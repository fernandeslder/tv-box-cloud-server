#!/usr/bin/env bash
# build-usb-arch.sh — make an already-mounted FAT32 stick boot the CachyOS
# installer ISO WITHOUT reformatting it: the ISO is copied to cachyos/cachyos.iso
# and a GRUB loopback entry "CachyOS installer (TV box)" is placed first in
# boot/grub/grub.cfg. The stick keeps its filesystem, its boot entries and every
# file already on it.
#
#   <stick>/cachyos/cachyos.iso   the CachyOS ISO (loopback-booted, never extracted)
#   <stick>/boot/grub/grub.cfg    + one loopback menu entry, first in the file
#   <stick>/<anything else>       untouched
#
# GRUB boot only. Modeled on build-usb.sh (same safety checks, same idempotency).
# Test hooks: TVBOX_DRY_RUN=1 (prints actions), TVBOX_USB_ALLOW_ANY_DIR=1 (any dir).
set -euo pipefail

DRY="${TVBOX_DRY_RUN:-0}"
run() { if [ "$DRY" = 1 ]; then echo "DRY: $*"; else "$@"; fi; }

FAT32_MAX=$((4 * 1024 * 1024 * 1024 - 1))   # largest single file FAT32 can hold
ISO="" TARGET="" SHA256_HEX="" ASSUME_YES=0
usage() {
  cat <<U
Usage: $0 --iso FILE --target MOUNTPOINT [--sha256 HEX] [--yes]
  --iso FILE      cachyos-*-x86_64.iso (verified against --sha256 HEX, or the
                  SHA256SUMS/SHA256 file next to the ISO)
  --target DIR    the mounted, writable FAT32 stick (needs boot/grub/grub.cfg)
  --sha256 HEX    expected SHA256 of the ISO (default: the sums file next to it)
  --yes           do not ask before writing to the stick
U
}
die() { echo "error: $*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --iso) ISO=$2; shift 2 ;; --target) TARGET=$2; shift 2 ;;
    --sha256) SHA256_HEX=$2; shift 2 ;; --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;; *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }
[ -n "$ISO" ] || { usage >&2; exit 2; }
[ -f "$ISO" ] || die "no such ISO: $ISO"
[ -d "$TARGET" ] || die "no such directory: $TARGET"
[ -w "$TARGET" ] || die "$TARGET is not writable (remount rw)"
TARGET=$(cd "$TARGET" && pwd)
[ -n "$TARGET" ] && [ "$TARGET" != / ] || die "refusing to use / as the target"

# --- safety: only a real, mounted, non-system filesystem -----------------------------------------
if [ -z "${TVBOX_USB_ALLOW_ANY_DIR:-}" ]; then
  mountpoint -q "$TARGET" || die "$TARGET is not a mountpoint"
  case "$TARGET" in /boot|/boot/efi|/home|/usr|/var|/etc) die "refusing system path $TARGET" ;; esac
  fs=$(findmnt -n -o FSTYPE "$TARGET" 2>/dev/null || true)
  [ "$fs" = vfat ] || die "$TARGET is $fs, not vfat: this builder keeps the stick's FAT32 filesystem"
fi

GRUB="$TARGET/boot/grub/grub.cfg"
[ -f "$GRUB" ] || die "no boot/grub/grub.cfg on the stick: this builder adds the loopback entry to an existing GRUB configuration"

# --- ISO integrity ------------------------------------------------------------------------------
iso_dir=$(dirname "$ISO")
iso_name=$(basename "$ISO")
if [ -n "$SHA256_HEX" ]; then
  want=$(printf '%s' "$SHA256_HEX" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  have=$(sha256sum "$ISO" | cut -d' ' -f1)
  [ "$want" = "$have" ] || die "ISO checksum mismatch (want $want, have $have)"
  echo "ISO checksum OK ($iso_name)"
else
  sums=""
  for f in SHA256SUMS SHA256; do
    if [ -f "$iso_dir/$f" ]; then sums="$iso_dir/$f"; break; fi
  done
  if [ -n "$sums" ] && grep -q " \*\?$iso_name\$" "$sums"; then
    want=$(grep " \*\?$iso_name\$" "$sums" | head -n1 | cut -d' ' -f1)
    have=$(sha256sum "$ISO" | cut -d' ' -f1)
    [ "$want" = "$have" ] || die "ISO checksum mismatch for $iso_name (want $want, have $have)"
    echo "ISO checksum OK ($iso_name)"
  else
    echo "warning: no --sha256 and no sums file next to the ISO: integrity NOT verified" >&2
  fi
fi

# --- FAT32 single-file limit, then free space ----------------------------------------------------
iso_size=$(stat -c %s "$ISO")
[ "$iso_size" -le "$FAT32_MAX" ] \
  || die "the ISO is $iso_size bytes: FAT32 cannot hold a single file bigger than 4 GiB; use a smaller ISO or reformat the stick"
need=$(( iso_size + 100 * 1024 * 1024 ))
free=$(df -B1 --output=avail "$TARGET" | tail -n1 | tr -dc '0-9')
[ "$free" -ge "$need" ] || die "not enough free space on the stick (need ~$((need / 1048576)) MB, have $((free / 1048576)) MB)"

# --- the ISO's kernel / initramfs / microcode names ----------------------------------------------
# The loopback entry must reference the real paths inside the ISO; they differ
# between releases, so detect them with bsdtar instead of hard-coding names.
tmp_listing=$(mktemp); tmp_new=$(mktemp)
trap 'rm -f "$tmp_listing" "$tmp_new"' EXIT
bsdtar -tf "$ISO" | sed 's#^\./##' > "$tmp_listing" || die "cannot list $iso_name with bsdtar: not an ISO9660 image?"
pick() { awk -v p="^/?$1\$" '$0 ~ p { sub(/^\//, ""); print; exit }' "$tmp_listing"; }
kernel=$(pick 'arch/boot/x86_64/vmlinuz-linux-cachyos')
[ -n "$kernel" ] || kernel=$(pick 'arch/boot/x86_64/vmlinuz[^/]*')
[ -n "$kernel" ] || die "no kernel (arch/boot/x86_64/vmlinuz*) inside the ISO: wrong ISO?"
initrd=$(pick 'arch/boot/x86_64/initramfs-linux-cachyos.img')
[ -n "$initrd" ] || initrd=$(pick 'arch/boot/x86_64/initramfs-linux[^/]*.img')
[ -n "$initrd" ] || initrd=$(pick 'arch/boot/x86_64/initramfs[^/]*.img')
[ -n "$initrd" ] || die "no initramfs (arch/boot/x86_64/initramfs*.img) inside the ISO: wrong ISO?"
ucode=$(pick 'arch/boot/amd-ucode.img')
[ -n "$ucode" ] || ucode=$(pick 'arch/boot/[^/]*ucode.img')

# --- the stick's filesystem UUID (the installer finds its medium through img_dev=) --------------
uuid=$(findmnt -n -o UUID "$TARGET" 2>/dev/null || true)
if [ -z "$uuid" ]; then
  dev=$(findmnt -n -o SOURCE "$TARGET" 2>/dev/null || true)
  [ -n "$dev" ] || die "cannot find the device behind $TARGET"
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
fi
[ -n "$uuid" ] || die "cannot read the UUID of the filesystem at $TARGET (needed for img_dev=/dev/disk/by-uuid/)"

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "This copies the ISO into $TARGET/cachyos/ and adds a \"CachyOS installer (TV box)\" entry to boot/grub/grub.cfg. Existing files are kept."
  printf 'Continue? [y/N] '; read -r a; [[ "$a" =~ ^[Yy] ]] || die "aborted"
fi

# --- 1. the ISO itself ---------------------------------------------------------------------------
echo "copying $iso_name to cachyos/cachyos.iso ..."
run mkdir -p -- "$TARGET/cachyos"
run cp -- "$ISO" "$TARGET/cachyos/cachyos.iso"

# --- 2. boot entry (first in the file, every existing entry kept) --------------------------------
MARKER='CachyOS installer (TV box)'
if grep -qF "$MARKER" "$GRUB"; then
  echo "boot entry already present: boot/grub/grub.cfg"
else
  echo "adding the boot entry to boot/grub/grub.cfg ..."
  {
    printf 'menuentry "%s" {\n' "$MARKER"
    printf '    loopback loop /cachyos/cachyos.iso\n'
    printf '    linux (loop)/%s img_dev=/dev/disk/by-uuid/%s img_loop=/cachyos/cachyos.iso earlymodules=loop archisobasedir=arch\n' "$kernel" "$uuid"
    if [ -n "$ucode" ]; then
      printf '    initrd (loop)/%s (loop)/%s\n' "$ucode" "$initrd"
    else
      printf '    initrd (loop)/%s\n' "$initrd"
    fi
    printf '}\n\n'
    cat "$GRUB"
  } > "$tmp_new"
  run cp -- "$tmp_new" "$GRUB"
fi

# The installer verifies the medium against md5sum.txt ("install media checksum verification failed"
# otherwise, and it then blames unrelated crashes on it). We edited grub.cfg, so record its new sum.
# Runs on every build, so a stick made before this is repaired by a re-run too.
if [ -f "$TARGET/md5sum.txt" ] && grep -qF './boot/grub/grub.cfg' "$TARGET/md5sum.txt"; then
  echo "updating md5sum.txt for the patched boot/grub/grub.cfg ..."
  new_md5=$(md5sum "$GRUB" | cut -d' ' -f1)
  awk -v n="$new_md5" '$2 == "./boot/grub/grub.cfg" { print n "  " $2; next } { print }' "$TARGET/md5sum.txt" > "$tmp_new"
  run cp -- "$tmp_new" "$TARGET/md5sum.txt"
  ( cd "$TARGET" && grep -F ' ./boot/grub/grub.cfg' md5sum.txt | md5sum -c --quiet - ) \
    || die "could not update md5sum.txt for boot/grub/grub.cfg"
fi

run sync
echo "DONE. Boot the box from this stick (F12), pick \"$MARKER\"."
