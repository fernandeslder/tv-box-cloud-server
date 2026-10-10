#!/usr/bin/env bash
# 20-desktop-htpc.sh — TV desktop (Plasma + Kodi). Skipped for headless servers (TVBOX_DESKTOP=no).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
if [ "$(env_get TVBOX_DESKTOP yes)" != yes ]; then log "20-desktop skipped (headless)"; exit 0; fi

if [ "${PKG_FAMILY:-debian}" = arch ]; then
  # The desktop itself must install; the extras are best-effort and each skipped if this release lacks it.
  pkg_install plasma-desktop plasma-bigscreen sddm kodi \
    || die "could not install the TV desktop (plasma-desktop, plasma-bigscreen, sddm, kodi)"
  # Debian's package enables the display manager itself; on Arch it is left disabled
  systemctl enable sddm.service >/dev/null 2>&1 || warn "could not enable sddm.service"
  systemctl set-default graphical.target >/dev/null 2>&1 || true
  # Steam is [multilib]-only: when this image ships the repo commented out, enable it
  # and refresh the databases so Steam resolves in the optional sweep below.
  pacman_conf="${TVBOX_PACMAN_CONF:-/etc/pacman.conf}"
  if grep -qE '^[[:space:]]*#[[:space:]]*\[multilib\]' "$pacman_conf"; then
    sed -i -E 's|^[[:space:]]*#[[:space:]]*\[multilib\]|[multilib]|' "$pacman_conf"
    sed -i -E '/^\[multilib\]/,+1 s|^[[:space:]]*#[[:space:]]*(Include[[:space:]]*=)|\1|' "$pacman_conf"
    pkg_update
  fi
  # steam needs a lib32 Vulkan driver; name the right one so --noconfirm does not pick an arbitrary provider
  pkg_install_optional lib32-mesa lib32-vulkan-radeon
  pkg_install_optional pipewire wireplumber pipewire-pulse bluez bluez-utils flatpak mpv firefox \
    yt-dlp libcec plasma-nm plasma-pa powerdevil kscreen konsole kodi-addon-pvr-iptvsimple \
    steam sunshine waydroid gamescope
else
  # The desktop itself must install; the extras are best-effort and each skipped if this release lacks it.
  # plasma-session-wayland ships /usr/share/wayland-sessions/plasma.desktop. apt_install skips "Recommends", and
  # plasma-desktop only recommends it, so without it SDDM has no Plasma session to log in to.
  apt_install plasma-desktop plasma-session-wayland sddm kodi \
    || die "could not install the TV desktop (plasma-desktop, plasma-session-wayland, sddm, kodi)"
  # Ubuntu/Debian split Kodi's official add-on repository into its own package; without it Kodi has no
  # "Get more..." (no skins, no add-ons from the repository).
  apt_install_optional kodi-repository-kodi
  apt_install_optional sddm-theme-breeze plasma-nm plasma-pa powerdevil kscreen xdg-desktop-portal-kde fonts-noto-core konsole
  apt_install_optional kodi-pvr-iptvsimple kodi-inputstream-adaptive kodi-peripheral-joystick firefox mpv \
    cec-utils flatpak pipewire wireplumber bluetooth bluez
fi

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

# SDDM on the TV box: Wayland greeter (Plasma 6 here is Wayland-only, there is no Xorg)
# and the TV user logged straight into the TV session.
if [ "${PKG_FAMILY:-debian}" = arch ]; then
  # plasma-bigscreen ships /usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop and
  # plasma-desktop ships plasma.desktop; TVBOX_SESSION picks the autologin session.
  sddm_conf_dir="${TVBOX_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
  install -d "$sddm_conf_dir"
  printf '[General]\nDisplayServer=wayland\n' > "$sddm_conf_dir/10-tvbox.conf"
  if [ -n "$TVBOX_USER" ]; then
    printf '[Autologin]\nUser=%s\nSession=%s\n' "$TVBOX_USER" "${TVBOX_SESSION:-plasma-bigscreen-wayland}" \
      > "$sddm_conf_dir/autologin.conf"
  fi
else
  # SDDM defaults to X11 and a `weston` greeter compositor; neither is installed (Plasma 6 here is Wayland-only,
  # there is no Xorg). Use KWin for the Wayland greeter and log the TV user straight into Plasma.
  install -d /etc/sddm.conf.d
  {
    printf '[General]\nDisplayServer=wayland\nGreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell\n\n'
    printf '[Wayland]\nCompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1\n'
    [ ! -d /usr/share/sddm/themes/breeze ] || printf '\n[Theme]\nCurrent=breeze\n'
  } > /etc/sddm.conf.d/10-tvbox.conf
  if [ -n "$TVBOX_USER" ]; then
    printf '[Autologin]\nUser=%s\nSession=plasma.desktop\n' "$TVBOX_USER" > /etc/sddm.conf.d/autologin.conf
  fi
fi
log "20-desktop-htpc ok (Flatpak TV apps: docs/03)"
