#!/usr/bin/env bash
# tvbox — configure the installed CachyOS (Arch) system. Runs INSIDE arch-chroot
# as root (called by ../arch-install.sh).
#
# Required env:  TVBOX_HOSTNAME TVBOX_USER TVBOX_PASS_HASH TVBOX_SSH_KEY
# Optional env:  TVBOX_TZ (default UTC)   TVBOX_KBD (default us)
#                TVBOX_DOMAIN
#                TVBOX_WIFI_SSID TVBOX_WIFI_PASS  (Wi-Fi keyfile when SSID is set)
#
# TVBOX_ROOT prefixes every file path (default /) so the script can also run
# against a temp dir. TVBOX_DRY_RUN=1 prints every system-changing command
# instead of running it; file writes still land under TVBOX_ROOT.
set -euo pipefail

TVBOX_ROOT=${TVBOX_ROOT:-/}

die() { echo "chroot.sh: error: $*" >&2; exit 1; }

# The only way a system-changing command runs: executed, or just printed
# when TVBOX_DRY_RUN=1. Everything written directly below targets
# $TVBOX_ROOT/... and so stays inside the test dir.
run() {
  if [ "${TVBOX_DRY_RUN:-0}" = 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

for v in TVBOX_HOSTNAME TVBOX_USER TVBOX_PASS_HASH TVBOX_SSH_KEY; do
  [ -n "${!v:-}" ] || die "$v is required (export it before running this inside arch-chroot)"
done
TVBOX_TZ=${TVBOX_TZ:-UTC}
TVBOX_KBD=${TVBOX_KBD:-us}

echo "==> timezone ($TVBOX_TZ)"
run ln -sf "/usr/share/zoneinfo/$TVBOX_TZ" "$TVBOX_ROOT/etc/localtime"
run hwclock --systohc

echo "==> locale en_US.UTF-8"
mkdir -p "$TVBOX_ROOT/etc"
lg="$TVBOX_ROOT/etc/locale.gen"
if [ -f "$lg" ]; then
  sed -i 's/^#\?en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$lg"
else
  printf 'en_US.UTF-8 UTF-8\n' > "$lg"
fi
run locale-gen
printf 'LANG=en_US.UTF-8\n' > "$TVBOX_ROOT/etc/locale.conf"

echo "==> console keymap ($TVBOX_KBD)"
printf 'KEYMAP=%s\n' "$TVBOX_KBD" > "$TVBOX_ROOT/etc/vconsole.conf"

echo "==> hostname ($TVBOX_HOSTNAME)"
printf '%s\n' "$TVBOX_HOSTNAME" > "$TVBOX_ROOT/etc/hostname"
if [ -n "${TVBOX_DOMAIN:-}" ]; then
  fqdn="$TVBOX_HOSTNAME.$TVBOX_DOMAIN"
else
  fqdn="$TVBOX_HOSTNAME.localdomain"
fi
cat > "$TVBOX_ROOT/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $fqdn $TVBOX_HOSTNAME
EOF

echo "==> user $TVBOX_USER (wheel, key-only SSH)"
run useradd -m -G wheel,video,input,audio,render "$TVBOX_USER"
printf '%s:%s\n' "$TVBOX_USER" "$TVBOX_PASS_HASH" | run chpasswd -e
mkdir -p "$TVBOX_ROOT/etc/sudoers.d"
sudoers="$TVBOX_ROOT/etc/sudoers.d/10-wheel"
rm -f "$sudoers"   # 0440 is owner-read-only: rewrite via a fresh file
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$sudoers"
chmod 0440 "$sudoers"

mkdir -p "$TVBOX_ROOT/etc/ssh/sshd_config.d" "$TVBOX_ROOT/home/$TVBOX_USER/.ssh"
cat > "$TVBOX_ROOT/etc/ssh/sshd_config.d/10-tvbox.conf" <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
printf '%s\n' "$TVBOX_SSH_KEY" > "$TVBOX_ROOT/home/$TVBOX_USER/.ssh/authorized_keys"
chmod 700 "$TVBOX_ROOT/home/$TVBOX_USER/.ssh"
chmod 600 "$TVBOX_ROOT/home/$TVBOX_USER/.ssh/authorized_keys"
run chown -R "$TVBOX_USER:$TVBOX_USER" "$TVBOX_ROOT/home/$TVBOX_USER/.ssh"

echo "==> services"
run systemctl enable NetworkManager sshd avahi-daemon systemd-timesyncd fstrim.timer

if [ -n "${TVBOX_WIFI_SSID:-}" ]; then
  echo "==> Wi-Fi ($TVBOX_WIFI_SSID)"
  mkdir -p "$TVBOX_ROOT/etc/NetworkManager/system-connections"
  wpa="$TVBOX_ROOT/etc/NetworkManager/system-connections/$TVBOX_WIFI_SSID.nmconnection"
  uuid=$(cat /proc/sys/kernel/random/uuid)
  {
    printf '[connection]\nid=%s\nuuid=%s\ntype=802-11-wireless\n\n' "$TVBOX_WIFI_SSID" "$uuid"
    printf '[802-11-wireless]\nssid=%s\nmode=infrastructure\n\n' "$TVBOX_WIFI_SSID"
    if [ -n "${TVBOX_WIFI_PASS:-}" ]; then
      printf '[802-11-wireless-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$TVBOX_WIFI_PASS"
    fi
    printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
  } > "$wpa"
  chmod 600 "$wpa"
fi

echo "==> bootloader (systemd-boot)"
run bootctl install
mkdir -p "$TVBOX_ROOT/boot/loader/entries"
cat > "$TVBOX_ROOT/boot/loader/loader.conf" <<'EOF'
default tvbox
timeout 3
EOF
rootopts="root=LABEL=tvbox rootflags=subvol=@ rw"
cat > "$TVBOX_ROOT/boot/loader/entries/tvbox.conf" <<EOF
title   CachyOS Linux
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options $rootopts
EOF
cat > "$TVBOX_ROOT/boot/loader/entries/tvbox-fallback.conf" <<EOF
title   CachyOS Linux (fallback)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos-fallback.img
options $rootopts
EOF
run mkinitcpio -P

echo "==> first-boot service"
mkdir -p "$TVBOX_ROOT/usr/local/sbin" "$TVBOX_ROOT/etc/systemd/system"
cat > "$TVBOX_ROOT/usr/local/sbin/tvbox-firstboot.sh" <<'SCRIPT'
#!/bin/bash
set -uo pipefail
LOG=/var/log/tvbox-firstboot.log
MARKER=/var/lib/tvbox-firstboot.done
SEED_ENV=/opt/tvbox-seed.env
BUNDLE=/opt/tvbox.bundle
BOOTSTRAP_URL=https://raw.githubusercontent.com/fernandeslder/tv-box-cloud-server/master/bootstrap.sh

exec >>"$LOG" 2>&1
[ -e "$MARKER" ] && exit 0
echo "=== $(date -Is) tvbox first-boot setup starting"

# network-online can fire before DHCP/Wi-Fi really works: probe for up to 10 min
probe() {
  if command -v curl >/dev/null 2>&1; then curl -fsI --max-time 10 https://download.docker.com >/dev/null
  else getent hosts download.docker.com >/dev/null; fi
}
for _ in $(seq 1 60); do
  probe && break
  echo "$(date -Is) waiting for internet..."
  sleep 10
done

export TVBOX_NONINTERACTIVE=1
[ -f "$SEED_ENV" ] && export TVBOX_ENV_FILE="$SEED_ENV"

# Prefer the repo bundle from the installer USB (pinned commit, works when
# GitHub is unreachable); fall back to downloading bootstrap.sh from GitHub.
if [ -f "$BUNDLE" ]; then
  echo "using the repo bundle from the installer USB ($(git bundle list-heads "$BUNDLE" 2>/dev/null | head -n1))"
  export TVBOX_BUNDLE="$BUNDLE" TVBOX_NO_PULL=1
  tmp=$(mktemp -d)
  if git clone -q "$BUNDLE" "$tmp/repo"; then script="$tmp/repo/bootstrap.sh"; else script=""; fi
fi
if [ -z "${script:-}" ]; then
  script=$(mktemp)
  if ! curl -fsSL --retry 5 --retry-delay 10 "$BOOTSTRAP_URL" -o "$script"; then
    echo "$(date -Is) could not download bootstrap.sh; will retry on next boot"
    exit 1
  fi
fi

if bash "$script"; then
  touch "$MARKER"
  systemctl disable tvbox-firstboot.service
  echo "=== $(date -Is) tvbox first-boot setup finished OK"
else
  echo "=== $(date -Is) bootstrap FAILED; will retry on next boot (or: sudo systemctl start tvbox-firstboot)"
  exit 1
fi
SCRIPT
chmod 755 "$TVBOX_ROOT/usr/local/sbin/tvbox-firstboot.sh"

cat > "$TVBOX_ROOT/etc/systemd/system/tvbox-firstboot.service" <<'UNIT'
[Unit]
Description=TV box first-boot setup (runs bootstrap.sh once)
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/tvbox-firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tvbox-firstboot.sh
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT
run systemctl enable tvbox-firstboot.service
