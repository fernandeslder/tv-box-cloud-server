#!/usr/bin/env bash
# 10-base.sh — packages + always-on-box power behaviour.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
export DEBIAN_FRONTEND=noninteractive
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

# Always-on server: never sleep, ignore the lid (this may be a laptop chassis).
install -d /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/tvbox.conf <<'CONF'
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
