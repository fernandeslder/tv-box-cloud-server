#!/usr/bin/env bash
# build-usb.sh — turn an already-mounted FAT32 USB stick into the one-stick tv-box installer
# WITHOUT reformatting it: the Ubuntu Server ISO is unpacked onto the stick's root and an extra
# "TV box: automated install" boot entry is added in front of the stock ones.
#
#   <stick>/                 Ubuntu Server ISO contents (EFI/, boot/, casper/, ...)
#   <stick>/seed/            autoinstall user-data, meta-data, tvbox-seed.env   (nocloud datasource)
#   <stick>/tv-box/          tvbox.bundle (git bundle of this repo), SHA256SUMS, legion/, clients/, checklist
#   <stick>/<anything else>  untouched (your own files stay where they are)
#
# UEFI boot only (the stock Ubuntu ISO layout on FAT32). The stick keeps its filesystem and old files.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

ISO="" TARGET="" USERNAME_="tvbox" KEY_FILE="" HASH_FILE="" WIFI_SSID="" TZ_="" KBD="us" HOSTNAME_="tvbox"
DOMAIN="" ENV_EXTRA="" ASSUME_YES=0 DO_ISO=1 DO_SEED=1
usage() {
  cat <<U
Usage: $0 --iso FILE --target MOUNTPOINT --ssh-key-file PUB --password-hash-file FILE [options]
  --iso FILE               ubuntu-XX.XX.X-live-server-amd64.iso (verified against SHA256SUMS next to it)
  --target DIR             the mounted, writable FAT32 stick
  --ssh-key-file FILE      PUBLIC key authorised for the login user (SSH is key-only)
  --password-hash-file F   first line = sha-512 crypt hash of the console/sudo password
  --user NAME              login user (default tvbox)
  --wifi-ssid SSID         bake Wi-Fi in; password from \$TVBOX_WIFI_PASS
  --timezone ZONE          default: this computer's
  --keyboard LAYOUT        default: us
  --domain NAME            pre-answer the wizard's domain (e.g. lder.fyi)
  --env-extra FILE         extra non-secret KEY=VALUE lines for tvbox-seed.env
  --no-seed                unpack the ISO + boot entry + tv-box/ only (seed later with --seed-only)
  --seed-only              (re)write seed/ and tv-box/ only; the ISO must already be unpacked
  --yes                    do not ask before writing to the stick
U
}
die() { echo "error: $*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --iso) ISO=$2; shift 2 ;; --target) TARGET=$2; shift 2 ;; --user) USERNAME_=$2; shift 2 ;;
    --ssh-key-file) KEY_FILE=$2; shift 2 ;; --password-hash-file) HASH_FILE=$2; shift 2 ;;
    --wifi-ssid) WIFI_SSID=$2; shift 2 ;; --timezone) TZ_=$2; shift 2 ;; --keyboard) KBD=$2; shift 2 ;;
    --domain) DOMAIN=$2; shift 2 ;; --env-extra) ENV_EXTRA=$2; shift 2 ;; --yes) ASSUME_YES=1; shift ;;
    --no-seed) DO_SEED=0; shift ;; --seed-only) DO_ISO=0; shift ;;
    -h|--help) usage; exit 0 ;; *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }
[ "$DO_ISO" -eq 0 ] || [ -n "$ISO" ] || { usage >&2; exit 2; }
[ "$DO_SEED" -eq 0 ] || { [ -n "$KEY_FILE" ] && [ -n "$HASH_FILE" ]; } || { usage >&2; exit 2; }
[ "$DO_ISO" -eq 0 ] || [ -f "$ISO" ] || die "no such ISO: $ISO"
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

if [ "$DO_ISO" -eq 1 ]; then
# --- ISO integrity ---------------------------------------------------------------------------------
iso_name=$(basename "$ISO")
sums="$(dirname "$ISO")/SHA256SUMS"
if [ -f "$sums" ] && grep -q " \*\?$iso_name\$" "$sums"; then
  want=$(grep " \*\?$iso_name\$" "$sums" | head -n1 | cut -d' ' -f1)
  have=$(sha256sum "$ISO" | cut -d' ' -f1)
  [ "$want" = "$have" ] || die "ISO checksum mismatch for $iso_name (want $want, have $have)"
  echo "ISO checksum OK ($iso_name)"
else
  echo "warning: no SHA256SUMS next to the ISO: integrity NOT verified" >&2
fi

# --- space -----------------------------------------------------------------------------------------
need=$(( $(stat -c %s "$ISO") + 300 * 1024 * 1024 ))
free=$(df -B1 --output=avail "$TARGET" | tail -n1 | tr -dc '0-9')
[ "$free" -ge "$need" ] || die "not enough free space on the stick (need ~$((need / 1048576)) MB, have $((free / 1048576)) MB)"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "This writes the ISO contents + seed + tv-box/ into $TARGET. Existing files are kept."
  printf 'Continue? [y/N] '; read -r a; [[ "$a" =~ ^[Yy] ]] || die "aborted"
fi

# --- 1. seed (user-data, meta-data, tvbox-seed.env) -------------------------------------------------
if [ "$DO_SEED" -eq 1 ]; then
SEED="$TARGET/seed"
mkdir -p "$SEED"
ENV_TMP=$(mktemp); trap 'rm -f "$ENV_TMP"' EXIT
{
  echo "# Non-secret answers for the unattended first boot (no API tokens on the stick: docs/01)."
  echo "TVBOX_HOSTNAME=$HOSTNAME_"
  echo "TVBOX_DESKTOP=yes"
  echo "COMPOSE_PROFILES=media"
  [ -z "$DOMAIN" ] || echo "DOMAIN=$DOMAIN"
  [ -z "$TZ_" ] || echo "TZ=$TZ_"
  [ -z "$ENV_EXTRA" ] || grep -E '^[A-Z0-9_]+=' "$ENV_EXTRA" || true
} > "$ENV_TMP"
seed_args=(--user "$USERNAME_" --ssh-key-file "$KEY_FILE" --password-hash-file "$HASH_FILE" --keyboard "$KBD"
           --env-file "$ENV_TMP" --out "$SEED" --no-iso)
[ -z "$TZ_" ] || seed_args+=(--timezone "$TZ_")
[ -z "$WIFI_SSID" ] || seed_args+=(--wifi-ssid "$WIFI_SSID")
"$HERE/make-seed.sh" "${seed_args[@]}" >/dev/null
echo "seed written: $SEED"
fi

# --- 2. unpack the ISO onto the stick ----------------------------------------------------------------
if [ "$DO_ISO" -eq 1 ]; then
echo "unpacking $iso_name (this takes a few minutes on USB) ..."
if command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$ISO" -C "$TARGET"
elif command -v xorriso >/dev/null 2>&1; then xorriso -osirrox on -indev "$ISO" -extract / "$TARGET" >/dev/null 2>&1
elif command -v 7z >/dev/null 2>&1; then 7z x -y -o"$TARGET" "$ISO" >/dev/null
else die "need bsdtar, xorriso or 7z to unpack the ISO"; fi
# 7z leaves a "[BOOT]" folder of El Torito images behind; the stick does not need it.
if [ -d "${TARGET:?}/[BOOT]" ]; then rm -rf "${TARGET:?}/[BOOT]"; fi
[ -f "$TARGET/boot/grub/grub.cfg" ] || die "the ISO did not unpack a boot/grub/grub.cfg: wrong ISO?"

# --- 3. boot entry ----------------------------------------------------------------------------------------
python3 - "$TARGET/boot/grub/grub.cfg" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, newline="").read()
if "TV box: automated install" in s:
    sys.exit(0)                      # already patched: idempotent
m = re.search(r'^menuentry\s+"[^"]*"[^{]*\{.*?^\}', s, re.S | re.M)
if not m:
    sys.exit("no menuentry found in grub.cfg")
entry = m.group(0)
lin = re.search(r'^(\s*linux\s+\S+)(.*)$', entry, re.M)
if not lin:
    sys.exit("first menuentry has no linux line")
args = "autoinstall ds=nocloud\\;s=/cdrom/seed/"
rest = lin.group(2)
rest = rest.replace("---", args + " ---", 1) if "---" in rest else rest.rstrip() + " " + args
new_entry = entry.replace(lin.group(0), lin.group(1) + rest, 1)
new_entry = re.sub(r'^menuentry\s+"[^"]*"', 'menuentry "TV box: automated install (you confirm the disk, then it runs itself)"', new_entry, count=1, flags=re.M)
header = "set default=0\nset timeout=15\n"
s = s[:m.start()] + header + new_entry + "\n\n" + s[m.start():]
open(p, "w", newline="").write(s)
PY
echo "boot entry added: boot/grub/grub.cfg"
else
  [ -f "$TARGET/boot/grub/grub.cfg" ] || die "--seed-only needs an unpacked ISO on the stick (run without it first)"
fi

# --- 4. tv-box/ bundle --------------------------------------------------------------------------------------
TB="$TARGET/tv-box"
mkdir -p "$TB"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git checkout: cannot build tvbox.bundle"
if ! git -C "$REPO" diff --quiet HEAD -- 2>/dev/null; then
  echo "warning: the repo has uncommitted changes: the bundle holds the last COMMIT only" >&2
fi
branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
rm -f "${TB:?}/tvbox.bundle"
git -C "$REPO" bundle create "$TB/tvbox.bundle" HEAD "$branch" >/dev/null 2>&1 \
  || git -C "$REPO" bundle create "$TB/tvbox.bundle" HEAD >/dev/null
git -C "$REPO" rev-parse HEAD > "$TB/COMMIT"
( cd "$TB" && sha256sum tvbox.bundle > tvbox.bundle.sha256 )
for d in legion clients docs; do
  [ -d "$REPO/$d" ] || continue
  rm -rf "${TB:?}/${d:?}"
  cp -r "$REPO/$d" "$TB/$d"
done
cat > "$TB/FIRST-BOOT-CHECKLIST.txt" <<CHK
TV BOX FIRST BOOT CHECKLIST            (built $(date -Is) from commit $(cut -c1-12 "$TB/COMMIT"))
================================================================================
1. Plug THIS stick + ethernet (Wi-Fi $( [ -n "$WIFI_SSID" ] && echo "'$WIFI_SSID' is baked in" || echo "is not configured")) + HDMI + a keyboard into the box. Leave the USB HDDs UNPLUGGED.
2. Power on, tap F12 (Lenovo boot menu), choose the USB stick (UEFI).
3. Pick "TV box: automated install". Everything runs by itself until the STORAGE screen:
   check that only the internal NVMe is offered, confirm, then confirm the destructive prompt.
4. The box powers off when the OS is installed. Unplug the stick, press power.
5. First boot installs the whole stack (20-40 min, needs internet). Watch from your PC:
     ssh $USERNAME_@tvbox.local        then:   tail -f /var/log/tvbox-firstboot.log
   Finished when /var/lib/tvbox-firstboot.done exists. Then:  tvbox status | tvbox doctor
6. Plug the USB HDDs, then:  sudo tvbox disks scan   and   sudo tvbox disks add /dev/sdX data|backup
7. Paste API tokens once (no secrets are on this stick):  sudo tvbox setup --reconfigure
   (Cloudflare token for trusted HTTPS, Tailscale auth key, Command Code key).
8. Router: reserve the box's IP, point DNS at it. Tailscale admin: approve the subnet route.
Passwords the box generated:  cat ~/tvbox-credentials.txt  (move to a password manager, then delete).
CHK
cat > "$TB/README.txt" <<R
tvbox.bundle      git bundle of github.com/fernandeslder/tv-box-cloud-server at commit $(cut -c1-12 "$TB/COMMIT")
                  (the installer clones it to /opt/tvbox, then 'tvbox update' follows GitHub)
legion/ clients/  helper scripts for the GPU PC and for phones/PCs
docs/             the full documentation
R
sum_dirs=(tv-box); [ ! -d "$TARGET/seed" ] || sum_dirs+=(seed)
( cd "$TARGET" && find "${sum_dirs[@]}" -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > tv-box/SHA256SUMS )
echo "tv-box/ written ($(cut -c1-12 "$TB/COMMIT"))"

sync
echo "DONE. Boot the box from this stick (F12), pick \"TV box: automated install\"."
