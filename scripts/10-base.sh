#!/usr/bin/env bash
# 10-base.sh — packages + always-on-box power behaviour.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
export DEBIAN_FRONTEND=noninteractive
if [ "${PKG_FAMILY:-debian}" = arch ]; then
  # Arch equivalents, every name verified against the official repos (pacman -Si).
  # mergerfs and wsdd2 are AUR-only, so they stay best-effort: pkg_install_optional
  # warns and carries on when the repos do not carry them.
  pkg_update
  pkg_install ca-certificates curl git jq rsync file attr parted e2fsprogs util-linux \
    smartmontools restic rclone samba avahi nss-mdns qrencode ufw htop \
    python tesseract poppler ffmpeg openssl unzip binutils bind iproute2 imagemagick
  pkg_install fuse3
  pkg_install_optional wsdd2
  # mergerfs is AUR-only on Arch/CachyOS: without it disks.sh cannot mount the pool. Use the upstream static
  # release (same idea as the yt-dlp binary); TVBOX_LOCAL_PREFIX relocates it for tests.
  if ! command -v mergerfs >/dev/null 2>&1; then
    prefix="${TVBOX_LOCAL_PREFIX:-/usr/local}"
    mtmp="$(mktemp -d)"
    mver="$(curl -fsSL -m 30 https://api.github.com/repos/trapexit/mergerfs/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
    mver="${mver:-2.42.0}"
    if curl -fsSL -m 240 --retry 3 -o "$mtmp/mergerfs.tgz" \
         "https://github.com/trapexit/mergerfs/releases/download/$mver/mergerfs-$mver-static-linux_amd64.tar.gz" \
       && tar -xzf "$mtmp/mergerfs.tgz" -C "$mtmp" && [ -f "$mtmp/usr/local/bin/mergerfs" ]; then
      install -D -m 755 "$mtmp/usr/local/bin/mergerfs" "$prefix/bin/mergerfs"
      [ ! -f "$mtmp/usr/local/bin/mergerfs-fusermount" ] \
        || install -D -m 755 "$mtmp/usr/local/bin/mergerfs-fusermount" "$prefix/bin/mergerfs-fusermount"
      log "mergerfs $mver installed to $prefix/bin"
    else
      warn "could not install mergerfs: the storage pool will not mount until you do"
    fi
    rm -rf "$mtmp"
  fi
else
  apt-get update -qq
  apt_install ca-certificates curl git jq rsync file attr parted e2fsprogs util-linux \
    smartmontools restic rclone mergerfs samba avahi-daemon qrencode ufw htop \
    python3 tesseract-ocr poppler-utils ffmpeg openssl unzip binutils bind9-dnsutils iproute2
  apt_install wsdd2 2>/dev/null || apt_install wsdd 2>/dev/null || warn "wsdd not available: Windows may need \\\\tvbox typed manually"

  if [ "$(env_get TVBOX_DESKTOP yes)" = yes ]; then
    # Video acceleration for the Ryzen/Vega iGPU. `mesa-va-drivers` was folded into mesa-libgallium
    # on newer releases, so every name is optional and installed on its own.
    apt_install_optional mesa-va-drivers mesa-libgallium mesa-vulkan-drivers vainfo libva2 libva-drm2
  fi
fi

# Always-on server: never sleep, ignore the lid (this may be a laptop chassis).
# Test hook (same pattern as disks.sh): TVBOX_SYSTEMD_ETC relocates the /etc/systemd writes.
SYSTEMD_ETC="${TVBOX_SYSTEMD_ETC:-/etc/systemd}"
install -d "$SYSTEMD_ETC/logind.conf.d"
cat > "$SYSTEMD_ETC/logind.conf.d/tvbox.conf" <<'CONF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true

# Hostname (for tvbox.local via mDNS and \\tvbox in Windows).
host="$(env_get TVBOX_HOSTNAME tvbox)"
[ "$(hostname)" = "$host" ] || hostnamectl set-hostname "$host" 2>/dev/null || warn "could not set hostname"
log "10-base ok"
