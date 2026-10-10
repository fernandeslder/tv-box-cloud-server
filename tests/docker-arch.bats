load helpers
setup() {
  mk_tmp
  ORIG_PATH="$PATH"
  mkdir -p "$T/bin" "$T/real"
  # Fakes: every package/service/user call is logged, nothing real ever runs.
  cat > "$T/bin/pacman" <<'F'
#!/bin/sh
printf '%s\n' "$*" >> "$PACMAN_LOG"
F
  cat > "$T/bin/systemctl" <<'F'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
F
  cat > "$T/bin/usermod" <<'F'
#!/bin/sh
printf '%s\n' "$*" >> "$USERMOD_LOG"
F
  cat > "$T/bin/sudo" <<'F'
#!/bin/sh
exec "$@"
F
  chmod +x "$T/bin/"*
  # lib.sh upstream owns the pkg_* contract; BASH_ENV (sourced by the script's
  # non-interactive bash) provides it until then, calling the fake pacman.
  printf 'pkg_install() { pacman -S --noconfirm "$@"; }\n' > "$T/pkgenv"
  # Everything the script needs, except docker: it must be absent so the
  # install path runs even on a machine that already has docker.
  for b in env bash dirname id date install getent grep tail cut mktemp cat; do
    ln -sf "$(command -v "$b")" "$T/real/$b"
  done
  export PATH="$T/bin:$T/real" BASH_ENV="$T/pkgenv" \
    TVBOX_TEST_NOROOT=1 TVBOX_USER=tvbox PKG_FAMILY=arch \
    PACMAN_LOG="$T/pacman.log" SYSTEMCTL_LOG="$T/systemctl.log" USERMOD_LOG="$T/usermod.log" \
    DOCKER_ETC="$T/etc/docker" SYSTEMD_UNIT_DIR="$T/sysd"
  : > "$PACMAN_LOG"; : > "$SYSTEMCTL_LOG"; : > "$USERMOD_LOG"
}
teardown() { PATH="$ORIG_PATH"; rm -rf "$T"; }
@test "arch: docker, docker-compose and docker-buildx from the repos, service enabled, user in docker group" {
  run "$REPO/scripts/30-docker.sh"
  [ "$status" -eq 0 ]
  grep -q -- 'docker docker-compose docker-buildx' "$PACMAN_LOG"
  grep -q -- 'enable --now docker' "$SYSTEMCTL_LOG"
  grep -q -- '-aG docker tvbox' "$USERMOD_LOG"
}
