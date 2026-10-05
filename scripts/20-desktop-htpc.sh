#!/usr/bin/env bash
# 20-desktop-htpc.sh — TV desktop (Plasma + Kodi). Skipped for headless servers (TVBOX_DESKTOP=no).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
if [ "$(env_get TVBOX_DESKTOP yes)" != yes ]; then log "20-desktop skipped (headless)"; exit 0; fi
apt_install plasma-desktop sddm kodi kodi-pvr-iptvsimple firefox mpv yt-dlp cec-utils flatpak \
  pipewire wireplumber bluetooth bluez || warn "some desktop packages failed (continuing)"
have flatpak && flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
if [ -n "$TVBOX_USER" ]; then
  install -d /etc/sddm.conf.d
  printf '[Autologin]\nUser=%s\nSession=plasma.desktop\n' "$TVBOX_USER" > /etc/sddm.conf.d/autologin.conf
fi
log "20-desktop-htpc ok (Flatpak TV apps: docs/03)"
