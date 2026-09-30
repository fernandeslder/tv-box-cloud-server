#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh; need_root
apt_install plasma-desktop sddm kodi kodi-pvr-iptvsimple firefox mpv yt-dlp cec-utils flatpak \
  pipewire wireplumber bluetooth bluez
have flatpak && flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
install -Dm644 ../configs/sddm/autologin.conf /etc/sddm.conf.d/autologin.conf
log "20-desktop-htpc ok (Flatpak TV apps installed manually per docs/03)"
