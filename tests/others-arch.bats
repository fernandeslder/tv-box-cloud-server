load helpers

# A PATH holding only what the script under test execs before the point we
# assert: symlinked coreutils/libc tools plus fakes. No git, no real
# pacman/apt-get — the fake package managers log every call to $PM_LOG.
bare_path() {  # bare_path <extra-tool>...
  mkdir -p "$T/bin"
  local t
  for t in bash getent awk grep tail cut dirname cp cat "$@"; do
    ln -sf "$(command -v "$t")" "$T/bin/$t"
  done
}

fake_id_root() {  # id -u / id -g -> 0 (bootstrap.sh's sudo check)
  cat > "$T/bin/id" <<'F'
#!/bin/sh
case "$1" in -u|-g) echo 0 ;; esac
F
  chmod +x "$T/bin/id"
}

fake_pm() {  # fake_pm <pacman|apt-get> — log every invocation; "install" git
  cat > "$T/bin/$1" <<F
#!/bin/sh
printf '%s\n' "\$*" >> "\$PM_LOG"
cp "\$T/.git-fake" "\$T/bin/git"
F
  cat > "$T/.git-fake" <<'G'
#!/bin/sh
printf 'git %s\n' "$*" >> "$PM_LOG"
exit 1   # the test env is offline: the clone always fails
G
  chmod +x "$T/bin/$1" "$T/.git-fake"
}

teardown() { [ -n "${T:-}" ] && rm -rf "$T" || true; }

@test "bootstrap.sh installs git with pacman when only pacman exists" {
  mk_tmp
  bare_path
  fake_id_root
  fake_pm pacman
  run env PATH="$T/bin" PM_LOG="$T/pm.log" TVBOX_DIR="$T/dir" \
    TVBOX_REPO="https://example.invalid/tvbox.git" \
    bash "$REPO/bootstrap.sh"
  [ "$status" -eq 1 ]   # the fake git "clone" fails: the test env is offline
  [ "$(wc -l < "$T/pm.log")" -eq 2 ]   # apt-get is never touched
  grep -qx -- '-S --noconfirm --needed git curl ca-certificates' "$T/pm.log"
  grep -q '^git clone ' "$T/pm.log"
}

@test "bootstrap.sh installs git with apt-get when only apt-get exists" {
  mk_tmp
  bare_path
  fake_id_root
  fake_pm apt-get
  run env PATH="$T/bin" PM_LOG="$T/pm.log" TVBOX_DIR="$T/dir" \
    TVBOX_REPO="https://example.invalid/tvbox.git" \
    bash "$REPO/bootstrap.sh"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$T/pm.log")" -eq 3 ]
  grep -qx -- 'update -qq' "$T/pm.log"
  grep -qx -- 'install -y git curl ca-certificates' "$T/pm.log"
  grep -q '^git clone ' "$T/pm.log"
}

@test "install.sh wants a pacman box on Arch" {
  mk_tmp
  bare_path
  fake_id_root
  run env PATH="$T/bin" TVBOX_TEST_NOROOT=1 PKG_FAMILY=arch bash "$REPO/scripts/install.sh"
  [ "$status" -eq 1 ]
  grep -q 'pacman-based OS' <<<"$output"
}

@test "install.sh still wants an apt box on Debian" {
  mk_tmp
  bare_path
  fake_id_root
  run env PATH="$T/bin" TVBOX_TEST_NOROOT=1 PKG_FAMILY=debian bash "$REPO/scripts/install.sh"
  [ "$status" -eq 1 ]
  grep -q 'apt-based OS' <<<"$output"
}

@test "smart-check.sh hints pacman on Arch" {
  mk_tmp
  bare_path
  run env PATH="$T/bin" PKG_FAMILY=arch SMARTCTL="$T/none" TVBOX_STATE="$T/state" \
    bash "$REPO/scripts/smart-check.sh"
  [ "$status" -eq 0 ]
  grep -q 'smartctl missing (pacman -S --needed smartmontools)' <<<"$output"
}

@test "smart-check.sh hints apt off Arch" {
  mk_tmp
  bare_path
  run env PKG_FAMILY=debian PATH="$T/bin" SMARTCTL="$T/none" TVBOX_STATE="$T/state" \
    bash "$REPO/scripts/smart-check.sh"
  [ "$status" -eq 0 ]
  grep -q 'smartctl missing (apt install smartmontools)' <<<"$output"
}

@test "connect-linux.sh fstab recipe suggests pacman on Arch" {
  mk_tmp
  bare_path cat mkdir chmod
  fake_id_root
  fake_pm pacman
  mkdir -p "$T/home"
  run env PATH="$T/bin" HOME="$T/home" DISPLAY= WAYLAND_DISPLAY= bash -c \
    "printf '%s\n' '' tester secret | '$REPO/clients/connect-linux.sh' -f"
  [ "$status" -eq 0 ]
  grep -q 'sudo pacman -S --needed --noconfirm cifs-utils' <<<"$output"
}

@test "connect-linux.sh fstab recipe keeps apt off Arch" {
  mk_tmp
  bare_path cat mkdir chmod
  fake_id_root
  mkdir -p "$T/home"
  run env PATH="$T/bin" HOME="$T/home" DISPLAY= WAYLAND_DISPLAY= bash -c \
    "printf '%s\n' '' tester secret | '$REPO/clients/connect-linux.sh' -f"
  [ "$status" -eq 0 ]
  grep -q 'sudo apt install cifs-utils' <<<"$output"
}

@test "legion/setup-linux.sh keeps its pacman install paths" {
  grep -q 'have pacman' "$REPO/legion/setup-linux.sh"
  grep -q 'pacman -S --needed --noconfirm' "$REPO/legion/setup-linux.sh"
}
