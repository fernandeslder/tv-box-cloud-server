load helpers
# The Arch path of 20-desktop-htpc.sh, driven entirely by fakes: no pacman, no
# network, no systemctl, and nothing outside $T is touched. Every fake bottoms
# out in a logging pacman, so the assertions hold both with these PATH fakes and
# with the real pkg_* functions from lib.sh (which themselves call pacman).
setup() {
  mk_tmp
  export TVBOX_TEST_NOROOT=1
  export PKG_FAMILY=arch
  export TVBOX_USER=tester
  export TVBOX_PACMAN_CONF="$T/pacman.conf"
  export TVBOX_SDDM_CONF_DIR="$T/etc/sddm.conf.d"
  export PKLOG="$T/pklog"
  B="$T/bin"; mkdir -p "$B" "$TVBOX_SDDM_CONF_DIR"
  # A pacman that finds everything in the repos and installs nothing for real.
  cat > "$B/pacman" <<'F'
#!/bin/sh
echo "pacman $*" >> "$PKLOG"
case "$1" in
  -Q*)  exit 1 ;;                      # local database: nothing installed yet
  -Si|-Ss|-Sq) echo "Name : $2"; exit 0 ;;
  *)    exit 0 ;;                      # -S install, -Sy refresh
esac
F
  cat > "$B/pkg_install" <<'F'
#!/bin/sh
exec pacman -S --noconfirm --needed "$@"
F
  cat > "$B/pkg_install_optional" <<'F'
#!/bin/sh
for p in "$@"; do
  pkg_available "$p" && pacman -S --noconfirm --needed "$p" \
    || echo "package $p is not in the repos: skipped" >&2
done
F
  cat > "$B/pkg_available" <<'F'
#!/bin/sh
exec pacman -Si "$1"
F
  cat > "$B/pkg_update" <<'F'
#!/bin/sh
exec pacman -Sy
F
  # No network: the upstream yt-dlp fetch must fail over to the distro package.
  cat > "$B/curl" <<'F'
#!/bin/sh
exit 1
F
  cat > "$B/flatpak" <<'F'
#!/bin/sh
echo "flatpak $*" >> "$PKLOG"
F
  cat > "$B/systemctl" <<'F'
#!/bin/sh
echo "systemctl $*" >> "$PKLOG"
F
  cat > "$B/apt-cache" <<'F'
#!/bin/sh
exit 1
F
  chmod +x "$B"/*
  # shellcheck disable=SC2329
  stock_pacman_conf() {   # a stock pacman.conf with [multilib] commented out
    printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n\n#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n' \
      > "$TVBOX_PACMAN_CONF"
  }
  # shellcheck disable=SC2329
  saw_install() {
    grep -E '^pacman -S ' "$PKLOG" | grep -qwF "$1"
  }
}
teardown() { rm -rf "$T"; }

@test "arch: installs the desktop and the optional extras" {
  stock_pacman_conf
  PATH="$B:$PATH" run "$REPO/scripts/20-desktop-htpc.sh"
  [ "$status" -eq 0 ]
  for p in plasma-desktop plasma-bigscreen sddm kodi; do saw_install "$p"; done
  for p in pipewire wireplumber pipewire-pulse bluez bluez-utils flatpak mpv firefox yt-dlp \
    libcec plasma-nm plasma-pa powerdevil kscreen konsole kodi-addon-pvr-iptvsimple \
    steam sunshine waydroid gamescope; do saw_install "$p"; done
}

@test "arch: enables the commented-out [multilib] and refreshes the databases before Steam" {
  stock_pacman_conf
  PATH="$B:$PATH" run "$REPO/scripts/20-desktop-htpc.sh"
  [ "$status" -eq 0 ]
  grep -q '^\[multilib\]' "$TVBOX_PACMAN_CONF"
  grep -A1 '^\[multilib\]' "$TVBOX_PACMAN_CONF" | grep -q '^Include'
  upd=$(grep -n 'pacman -Sy' "$PKLOG" | head -1 | cut -d: -f1)
  steam=$(grep -n 'pacman -S .*steam' "$PKLOG" | head -1 | cut -d: -f1)
  [ -n "$upd" ] && [ -n "$steam" ] && [ "$upd" -lt "$steam" ]
}

@test "arch: an [multilib] that is already enabled is left alone" {
  printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' \
    > "$TVBOX_PACMAN_CONF"
  PATH="$B:$PATH" run "$REPO/scripts/20-desktop-htpc.sh"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2314
  ! grep -q 'pacman -Sy' "$PKLOG"
  [ "$(grep -c '^\[multilib\]' "$TVBOX_PACMAN_CONF")" -eq 1 ]
}

@test "arch: SDDM gets a Wayland greeter and autologs into the big-screen session" {
  stock_pacman_conf
  PATH="$B:$PATH" run "$REPO/scripts/20-desktop-htpc.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TVBOX_SDDM_CONF_DIR/10-tvbox.conf")" = "$(printf '[General]\nDisplayServer=wayland')" ]
  [ "$(cat "$TVBOX_SDDM_CONF_DIR/autologin.conf")" = \
    "$(printf '[Autologin]\nUser=tester\nSession=plasma-bigscreen-wayland')" ]
}

@test "arch: TVBOX_SESSION picks the autologin session (plain plasma as fallback)" {
  stock_pacman_conf
  TVBOX_SESSION=plasma PATH="$B:$PATH" run "$REPO/scripts/20-desktop-htpc.sh"
  [ "$status" -eq 0 ]
  grep -q '^Session=plasma$' "$TVBOX_SDDM_CONF_DIR/autologin.conf"
  # shellcheck disable=SC2314
  ! grep -q 'plasma-bigscreen' "$TVBOX_SDDM_CONF_DIR/autologin.conf"
}

@test "arch: the distro-independent steps still run (flatpak remote, yt-dlp fallback)" {
  stock_pacman_conf
  PATH="$B:$PATH" run "$REPO/scripts/20-desktop-htpc.sh"
  [ "$status" -eq 0 ]
  grep -q '^flatpak remote-add --if-not-exists flathub' "$PKLOG"
  [[ "$output" == *"could not fetch upstream yt-dlp"* ]]
  # shellcheck disable=SC2314
  # the only systemctl calls: enabling the display manager and the graphical default target
  grep -qx 'systemctl enable sddm.service' "$PKLOG"
  ! grep '^systemctl' "$PKLOG" | grep -vxE 'systemctl (enable sddm.service|set-default graphical.target)'
}

@test "arch: installs the flatpak TV apps from flathub" {
  stock_pacman_conf
  PATH="$B:$PATH" run "$REPO/scripts/20-desktop-htpc.sh"
  [ "$status" -eq 0 ]
  # flathub is ensured (added if missing) before any app is pulled from it
  remote="$(grep -n '^flatpak remote-add --if-not-exists flathub' "$PKLOG" | head -1 | cut -d: -f1)"
  [ -n "$remote" ]
  for app in com.moonlight_stream.Moonlight rocks.shy.VacuumTube \
    com.stremio.Stremio com.github.KRTirtho.Spotube; do
    line="$(grep -nxF "flatpak install --assumeyes flathub $app" "$PKLOG" | head -1 | cut -d: -f1)"
    [ -n "$line" ]            # the app was installed
    [ "$line" -gt "$remote" ] # after flathub was ensured
  done
}
