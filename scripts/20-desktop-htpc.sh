#!/usr/bin/env bash
# 20-desktop-htpc.sh — TV desktop (Plasma + Kodi). Skipped for headless servers (TVBOX_DESKTOP=no).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
if [ "$(env_get TVBOX_DESKTOP yes)" != yes ]; then log "20-desktop skipped (headless)"; exit 0; fi
# The desktop itself must install; the extras are best-effort and each skipped if this release lacks it.
apt_install plasma-desktop sddm kodi || die "could not install the TV desktop (plasma-desktop, sddm, kodi)"
apt_install_optional kodi-pvr-iptvsimple kodi-inputstream-adaptive kodi-peripheral-joystick firefox mpv \
  cec-utils flatpak pipewire wireplumber bluetooth bluez
have flatpak && flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

# YouTube changes weekly and the distro's yt-dlp is months old: use the upstream release binary
# (/usr/local/bin wins over /usr/bin) and let a weekly timer self-update it.
if curl -fsSL -m 120 --retry 3 https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp.new; then
  chmod 755 /usr/local/bin/yt-dlp.new && mv -f /usr/local/bin/yt-dlp.new /usr/local/bin/yt-dlp
  install -m 644 "$REPO_DIR/configs/systemd/tvbox-ytdlp.service" "$REPO_DIR/configs/systemd/tvbox-ytdlp.timer" /etc/systemd/system/
  systemctl daemon-reload; systemctl enable --now tvbox-ytdlp.timer >/dev/null 2>&1 || true
else
  rm -f /usr/local/bin/yt-dlp.new
  apt_install_optional yt-dlp
  warn "could not fetch upstream yt-dlp: using the distro package (it may lag behind YouTube)"
fi
if [ -n "$TVBOX_USER" ]; then
  install -d /etc/sddm.conf.d
  printf '[Autologin]\nUser=%s\nSession=plasma.desktop\n' "$TVBOX_USER" > /etc/sddm.conf.d/autologin.conf
fi
log "20-desktop-htpc ok (Flatpak TV apps: docs/03)"
