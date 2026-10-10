load helpers

# The PKG_FAMILY / pkg_* contract belongs to lib.sh (the Arch-support effort adds
# it there). Where lib.sh does not define it yet, these doubles forward to the
# fake package managers on PATH; once lib.sh defines the real ones, 10-base.sh
# sourcing lib.sh replaces them and the real contract drives the same fakes.
pkg_update()            { pacman -Sy; }
pkg_install()           { pacman -S --noconfirm "$@"; }
pkg_available()         { pacman -Si "$1" >/dev/null; }
pkg_install_optional() {
  local p
  for p in "$@"; do
    if pkg_available "$p"; then pacman -S --noconfirm "$p"; else warn "package $p is not in the repos: skipped"; fi
  done
}
export -f pkg_update pkg_install pkg_available pkg_install_optional

setup() {
  mk_tmp
  mkdir -p "$T/bin"
  cat >"$T/bin/pacman" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PACMAN_LOG"
exit 0
FAKE
  cat >"$T/bin/apt-get" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
exit 1
FAKE
  cat >"$T/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  cat >"$T/bin/hostnamectl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$T/bin/pacman" "$T/bin/apt-get" "$T/bin/systemctl" "$T/bin/hostnamectl"
  export PACMAN_LOG="$T/pacman.log" APT_LOG="$T/apt.log"
  : >"$PACMAN_LOG"; : >"$APT_LOG"
  export PATH="$T/bin:$PATH" PKG_FAMILY=arch TVBOX_TEST_NOROOT=1
  export ENV_FILE="$T/env" LOG="$T/log" TVBOX_SYSTEMD_ETC="$T/systemd-etc"
}
teardown() { rm -rf "$T"; }

@test "arch: base packages are requested from pacman, never from apt-get" {
  run "$REPO/scripts/10-base.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$PACMAN_LOG" ] || { echo "pacman was never called"; false; }
  local p
  for p in ca-certificates curl git jq rsync file attr parted e2fsprogs util-linux \
           smartmontools restic rclone samba avahi nss-mdns qrencode ufw htop \
           python tesseract poppler ffmpeg openssl unzip binutils bind iproute2 imagemagick; do
    grep -qw "$p" "$PACMAN_LOG" || { echo "pacman was never asked for $p"; false; }
  done
  [ ! -s "$APT_LOG" ] || { echo "apt-get was called: $(cat "$APT_LOG")"; false; }
  [ -f "$TVBOX_SYSTEMD_ETC/logind.conf.d/tvbox.conf" ]   # the script ran to completion
}

@test "debian: the apt package list is untouched" {
  grep -q 'apt_install ca-certificates curl git jq rsync file attr parted e2fsprogs util-linux' "$REPO/scripts/10-base.sh"
}
