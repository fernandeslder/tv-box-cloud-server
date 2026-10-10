#!/usr/bin/env bash
# arch-install.sh — install CachyOS (Arch) onto the TV box's NVMe.
# Run as root from the CachyOS live ISO (over SSH). Replaces the Ubuntu
# autoinstall route: wipe --disk, pacstrap a base system, copy the repo
# bundle and seed env into it, then run arch/chroot.sh inside it to set up
# the first boot (hostname, user, SSH key, Wi-Fi, timezone, ...).
#
# Safety:
#   * nothing touches a disk unless --confirm-wipe names the very same
#     device as --disk (exported as TVBOX_CONFIRM_WIPE for arch_disk_prepare);
#   * removable/USB media and the disk the running live system sits on are
#     refused outright;
#   * every system-changing command goes through run(), which only PRINTS the
#     command under TVBOX_DRY_RUN=1, so the exact sequence can be reviewed;
#   * the password hash and the Wi-Fi password travel in exported variables
#     only — never on a command line, so they can never show up in output.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DRY="${TVBOX_DRY_RUN:-0}"
MOUNT=/mnt

DISK="" CONFIRM="" HASH_FILE="" KEY_FILE="" BUNDLE="" ENV_FILE=""
USER_="tvbox" HOSTNAME_="tvbox" TZ_="America/Moncton" KBD="us" DOMAIN="" WIFI_SSID=""

usage() {
  cat <<U
Usage: $0 --disk DEV --password-hash-file FILE --ssh-key-file FILE [options]
  Run as root from the CachyOS live ISO; installs CachyOS onto the box's NVMe.
  --disk DEV              internal NVMe/SSD to wipe and install onto (required)
  --confirm-wipe DEV      must be the same device as --disk (the destructive step's confirmation)
  --password-hash-file F  first line = sha-512 crypt hash (\$6\$...) of the console password
  --ssh-key-file F        PUBLIC key authorised for the login user (SSH is key-only)
  --user NAME             login user (default tvbox)
  --hostname NAME         default tvbox
  --timezone ZONE         default America/Moncton
  --keyboard LAYOUT       default us
  --domain NAME           optional domain for the box
  --wifi-ssid SSID        bake Wi-Fi in; the password comes from \$TVBOX_WIFI_PASS
  --bundle FILE           git bundle copied to /opt/tvbox.bundle
  --env-file FILE         copied to /opt/tvbox-seed.env (mode 600)
  --dry-run               print every command instead of running it
U
}
die() { echo "error: $*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then echo "DRY: $*"; else "$@"; fi; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --disk) DISK=$2; shift 2 ;;
    --confirm-wipe) CONFIRM=$2; shift 2 ;;
    --password-hash-file) HASH_FILE=$2; shift 2 ;;
    --ssh-key-file) KEY_FILE=$2; shift 2 ;;
    --user) USER_=$2; shift 2 ;;
    --hostname) HOSTNAME_=$2; shift 2 ;;
    --timezone) TZ_=$2; shift 2 ;;
    --keyboard) KBD=$2; shift 2 ;;
    --domain) DOMAIN=$2; shift 2 ;;
    --wifi-ssid) WIFI_SSID=$2; shift 2 ;;
    --bundle) BUNDLE=$2; shift 2 ;;
    --env-file) ENV_FILE=$2; shift 2 ;;
    --dry-run) DRY=1; export TVBOX_DRY_RUN=1; shift ;;   # exported: the sourced libs read TVBOX_DRY_RUN
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# --- validate -------------------------------------------------------------------
[ -n "$DISK" ] || { usage >&2; die "--disk is required"; }
[ -n "$HASH_FILE" ] || die "--password-hash-file is required"
[ -n "$KEY_FILE" ] || die "--ssh-key-file is required"
[ -r "$HASH_FILE" ] || die "cannot read the password hash file: $HASH_FILE"
[ -r "$KEY_FILE" ] || die "cannot read the SSH key file: $KEY_FILE"
[ -z "$BUNDLE" ] || [ -r "$BUNDLE" ] || die "cannot read the bundle: $BUNDLE"
[ -z "$ENV_FILE" ] || [ -r "$ENV_FILE" ] || die "cannot read the env file: $ENV_FILE"

HASH=$(head -n1 "$HASH_FILE")
[[ "$HASH" == "\$6\$"* ]] || die "the password hash file must hold a \$6\$ sha-512 crypt hash (mkpasswd -m sha-512)"
SSH_KEY=$(head -n1 "$KEY_FILE")
[ -n "$SSH_KEY" ] || die "the SSH key file is empty"

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run this as root from the CachyOS live ISO"

# The wipe gate: the caller must name the exact device twice.
[ -n "$CONFIRM" ] || die "refusing to write to a disk: pass --confirm-wipe $DISK"
[ "$CONFIRM" = "$DISK" ] || die "--confirm-wipe $CONFIRM is not --disk $DISK"
export TVBOX_CONFIRM_WIPE="$CONFIRM"

# --- device safety: no removable/USB media, never the live system's own disk ----
info=$(lsblk -dnpo RM,TRAN "$DISK" 2>/dev/null) || die "$DISK: lsblk failed (not a block device?)"
read -r RM TRAN _ <<<"$info"
[ "$RM" = 0 ] || die "$DISK is removable (or lsblk could not read it): install to the internal NVMe/SSD"
[ "${TRAN:-}" != usb ] || die "$DISK is a USB disk: install to the internal NVMe/SSD"
live_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
live_disk=""
if [ -n "$live_src" ]; then
  live_disk=$(lsblk -srno NAME,TYPE "$live_src" 2>/dev/null | awk '$2=="disk"{print $1; exit}' || true)
fi
[ -z "$live_disk" ] || [ "$live_disk" != "$DISK" ] || die "$DISK holds the running live system: boot from the live USB"
[ "$live_src" != "$DISK" ] || die "$DISK holds the running live system: boot from the live USB"

# --- libs (autoinstall/arch/, written alongside this script; TVBOX_ARCH_LIB_DIR overrides) ---
LIB_DIR=${TVBOX_ARCH_LIB_DIR:-$HERE/arch}
for f in disk.sh packages.sh chroot.sh; do
  [ -f "$LIB_DIR/$f" ] || die "missing $LIB_DIR/$f (expected in autoinstall/arch/ next to this script)"
done
# shellcheck disable=SC1091  # sourced via a computed path
. "$LIB_DIR/disk.sh"       # arch_disk_prepare <dev> <mountpoint>
# shellcheck disable=SC1091
. "$LIB_DIR/packages.sh"   # arch_enable_cachyos_repos; arch_base_packages
DRY="${TVBOX_DRY_RUN:-$DRY}"   # the libs set their own DRY at source time: re-assert ours

# --- install --------------------------------------------------------------------
if [ "$DRY" = 1 ]; then echo "TVBOX_DRY_RUN=1: every command below is printed, nothing runs"; fi
echo "installing CachyOS onto $DISK (mounted at $MOUNT)"
arch_enable_cachyos_repos
arch_disk_prepare "$DISK" "$MOUNT"

mapfile -t PKGS < <(arch_base_packages)
[ "${#PKGS[@]}" -gt 0 ] || die "arch_base_packages listed no packages"
run pacstrap -K "$MOUNT" "${PKGS[@]}"

# The installed system must keep the CachyOS repos: pacstrap leaves it with the stock pacman.conf, so
# linux-cachyos and the optimized packages would never update. Copy what the live repo setup produced.
run install -Dm644 /etc/pacman.conf "$MOUNT/etc/pacman.conf"
if arch_cpu_has_v3; then arch_use_v3_repos "$MOUNT/etc/pacman.conf"; fi
for ml in /etc/pacman.d/cachyos*mirrorlist; do
  [ -e "$ml" ] || [ "$DRY" = 1 ] || continue
  run install -Dm644 "$ml" "$MOUNT$ml"
done

# genfstab writes the installed system's fstab (redirection, so it runs via bash -c)
run bash -c "genfstab -U $MOUNT > $MOUNT/etc/fstab"

[ -z "$BUNDLE" ] || run install -m 0644 "$BUNDLE" "$MOUNT/opt/tvbox.bundle"
[ -z "$ENV_FILE" ] || run install -m 0600 "$ENV_FILE" "$MOUNT/opt/tvbox-seed.env"
run install -m 0755 "$LIB_DIR/chroot.sh" "$MOUNT/root/chroot.sh"

# chroot.sh reads its answers from the environment: the password hash and the
# Wi-Fi password travel in exported variables only, never on the command line.
export TVBOX_HOSTNAME="$HOSTNAME_" TVBOX_USER="$USER_" TVBOX_PASS_HASH="$HASH" \
       TVBOX_SSH_KEY="$SSH_KEY" TVBOX_TZ="$TZ_" TVBOX_KBD="$KBD" \
       TVBOX_WIFI_SSID="$WIFI_SSID" TVBOX_WIFI_PASS="${TVBOX_WIFI_PASS:-}" TVBOX_DOMAIN="$DOMAIN"
[ -z "$WIFI_SSID" ] || [ -n "$TVBOX_WIFI_PASS" ] || echo "warning: --wifi-ssid is set but \$TVBOX_WIFI_PASS is empty" >&2
run arch-chroot "$MOUNT" /root/chroot.sh

run umount -R "$MOUNT"

echo "DONE: CachyOS is installed on $DISK."
echo "Next steps: remove the live USB and reboot the box."
