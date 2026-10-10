# shellcheck disable=SC2016,SC2030,SC2031  # bats idioms: inner bash -c vars, per-test exports
bats_require_minimum_version 1.5.0
load helpers
setup() {
  mk_tmp
  mkdir -p "$T/bin"
  export CALLS="$T/calls.log"; : > "$CALLS"
  # fake package managers: log "<args>" and succeed
  for b in apt-get apt-cache pacman; do
    cat > "$T/bin/$b" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
exit 0
F
    chmod +x "$T/bin/$b"
  done
  export PATH="$T/bin:$PATH"
}
teardown() { rm -rf "$T"; }

release() {  # release ID [ID_LIKE] — writes a realistic os-release file
  printf 'ID="%s"\n' "$1" > "$T/os-release"
  if [ -n "${2:-}" ]; then printf 'ID_LIKE="%s"\n' "$2" >> "$T/os-release"; fi
}
fam() {  # fam — PKG_FAMILY detected from $T/os-release (no PKG_FAMILY override)
  run env -u PKG_FAMILY TVBOX_OS_RELEASE="$T/os-release" \
    bash -c '. "$1"; printf %s "$PKG_FAMILY"' _ "$REPO/scripts/lib.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s' "$output"
}
lib() {  # lib <cmd> [args...] — source lib.sh, then run the command
  run bash -c '. "$1"; shift; "$@"' _ "$REPO/scripts/lib.sh" "$@"
}

@test "PKG_FAMILY: ubuntu os-release detects debian" {
  release ubuntu debian
  [ "$(fam)" = debian ]
}
@test "PKG_FAMILY: debian os-release detects debian" {
  release debian
  [ "$(fam)" = debian ]
}
@test "PKG_FAMILY: cachyos os-release detects arch" {
  release cachyos arch
  [ "$(fam)" = arch ]
}
@test "PKG_FAMILY: arch os-release detects arch" {
  release arch
  [ "$(fam)" = arch ]
}
@test "PKG_FAMILY: env override beats os-release detection" {
  release ubuntu debian
  run env PKG_FAMILY=arch TVBOX_OS_RELEASE="$T/os-release" \
    bash -c '. "$1"; printf %s "$PKG_FAMILY"' _ "$REPO/scripts/lib.sh"
  [ "$status" -eq 0 ]; [ "$output" = arch ]
}

@test "debian pkg_install runs apt-get install -y --no-install-recommends" {
  export PKG_FAMILY=debian
  lib pkg_install curl jq
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "install -y --no-install-recommends curl jq" ]
}
@test "debian pkg_install is non-interactive (DEBIAN_FRONTEND)" {
  export PKG_FAMILY=debian
  cat > "$T/bin/apt-get" <<'F'
#!/usr/bin/env bash
[ "${DEBIAN_FRONTEND:-}" = noninteractive ] || exit 97
printf '%s\n' "$*" >> "$CALLS"
F
  lib pkg_install curl
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "install -y --no-install-recommends curl" ]
}
@test "arch pkg_install runs pacman -S --noconfirm --needed" {
  export PKG_FAMILY=arch
  lib pkg_install firefox
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "-S --noconfirm --needed firefox" ]
}
@test "debian pkg_available runs apt-cache show" {
  export PKG_FAMILY=debian
  lib pkg_available curl
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "show curl" ]
}
@test "arch pkg_available runs pacman -Si" {
  export PKG_FAMILY=arch
  lib pkg_available firefox
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "-Si firefox" ]
}
@test "pkg_available fails when the repos lack the package" {
  export PKG_FAMILY=arch
  cat > "$T/bin/pacman" <<'F'
#!/usr/bin/env bash
case "$*" in *gone*) exit 1;; esac
printf '%s\n' "$*" >> "$CALLS"; exit 0
F
  lib pkg_available gone-pkg
  [ "$status" -ne 0 ]
}
@test "debian pkg_update runs apt-get update -qq" {
  export PKG_FAMILY=debian
  lib pkg_update
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "update -qq" ]
}
@test "arch pkg_update runs pacman -Sy --noconfirm" {
  export PKG_FAMILY=arch
  lib pkg_update
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "-Sy --noconfirm" ]
}
@test "debian pkg_install_optional checks each package and installs the present ones" {
  export PKG_FAMILY=debian
  cat > "$T/bin/apt-cache" <<'F'
#!/usr/bin/env bash
case "$*" in *gone*) exit 1;; esac
printf '%s\n' "$*" >> "$CALLS"; exit 0
F
  lib pkg_install_optional curl gone jq
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "show curl" ]
  grep -qx 'install -y --no-install-recommends curl' "$CALLS"
  grep -qx 'show jq' "$CALLS"
  grep -qx 'install -y --no-install-recommends jq' "$CALLS"
  [[ "$output" == *"package gone does not exist on this release: skipped"* ]]
  run ! grep -q -- 'install.*gone' "$CALLS"
}
@test "arch pkg_install_optional checks each package with pacman -Si" {
  export PKG_FAMILY=arch
  cat > "$T/bin/pacman" <<'F'
#!/usr/bin/env bash
case "$*" in *gone*) exit 1;; esac
printf '%s\n' "$*" >> "$CALLS"; exit 0
F
  lib pkg_install_optional firefox gone
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "-Si firefox" ]
  grep -qx -- '-S --noconfirm --needed firefox' "$CALLS"
  [[ "$output" == *"package gone does not exist on this release: skipped"* ]]
  run ! grep -q -- 'S.*gone' "$CALLS"
}
@test "apt_install and apt_install_optional still work as aliases" {
  export PKG_FAMILY=debian
  lib apt_install curl
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "install -y --no-install-recommends curl" ]
  lib apt_install_optional jq
  [ "$status" -eq 0 ]
  grep -qx 'show jq' "$CALLS"
  grep -qx 'install -y --no-install-recommends jq' "$CALLS"
}
