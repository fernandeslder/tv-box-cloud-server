# shellcheck shell=bash
load helpers

setup() {
  mk_tmp
}

teardown() { rm -rf "$T"; }

base_packages() {
  . "$REPO/autoinstall/arch/packages.sh"
  arch_base_packages
}

nvidia_packages() {
  export TVBOX_GPU=nvidia
  . "$REPO/autoinstall/arch/packages.sh"
  arch_base_packages
}

dry_repos() {
  export TVBOX_DRY_RUN=1
  export TVBOX_PACMAN_CONF=/nonexistent   # independent of the host's /etc/pacman.conf
  . "$REPO/autoinstall/arch/packages.sh"
  arch_enable_cachyos_repos
}

live_repos() {
  export PATH="$T/bin:$PATH" CALLS="$T/calls" TVBOX_PACMAN_CONF=/nonexistent
  unset TVBOX_DRY_RUN   # live mode: the fakes on PATH record the calls
  . "$REPO/autoinstall/arch/packages.sh"
  arch_enable_cachyos_repos
}

@test "arch_base_packages: non-empty, no duplicates, carries the CachyOS kernel and btrfs-progs" {
  run base_packages
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq "${#lines[@]}" ]
  printf '%s\n' "${lines[@]}" | grep -qx 'linux-cachyos'
  printf '%s\n' "${lines[@]}" | grep -qx 'btrfs-progs'
}

@test "arch_base_packages: default list has no GPU driver" {
  run base_packages
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c nvidia)" -eq 0 ]
}

@test "arch_base_packages: TVBOX_GPU=nvidia appends the verified nvidia-open-dkms" {
  run nvidia_packages
  [ "$status" -eq 0 ]
  printf '%s\n' "${lines[@]}" | grep -qx 'nvidia-open-dkms'
}

@test "arch_enable_cachyos_repos: dry run prints download, extract, run in order" {
  run dry_repos
  [ "$status" -eq 0 ]
  dl="$(grep -nF 'mirror.cachyos.org/cachyos-repo.tar.xz' <<<"$output" | head -1 | cut -d: -f1)"
  ex="$(grep -nF 'tar -xf' <<<"$output" | head -1 | cut -d: -f1)"
  rn="$(grep -nF 'cachyos-repo.sh' <<<"$output" | head -1 | cut -d: -f1)"
  [ -n "$dl" ]; [ -n "$ex" ]; [ -n "$rn" ]
  [ "$dl" -lt "$ex" ]; [ "$ex" -lt "$rn" ]
  # the repo script runs from its own extracted directory
  printf '%s\n' "$output" | grep -qF '&& ./cachyos-repo.sh'
}

@test "arch_enable_cachyos_repos: live mode runs curl, tar, then the repo script" {
  mkdir -p "$T/bin"
  cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$CALLS"
EOF
  cat > "$T/bin/tar" <<'EOF'
#!/bin/sh
echo "tar $*" >> "$CALLS"
EOF
  cat > "$T/bin/bash" <<'EOF'
#!/bin/sh
echo "bash $*" >> "$CALLS"
EOF
  chmod +x "$T/bin/curl" "$T/bin/tar" "$T/bin/bash"
  : > "$T/calls"
  run live_repos
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$T/calls")" -eq 3 ]
  dl="$(grep -nF 'mirror.cachyos.org/cachyos-repo.tar.xz' "$T/calls" | head -1 | cut -d: -f1)"
  ex="$(grep -nF 'tar -xf' "$T/calls" | head -1 | cut -d: -f1)"
  rn="$(grep -nF 'cachyos-repo.sh' "$T/calls" | head -1 | cut -d: -f1)"
  [ -n "$dl" ]; [ -n "$ex" ]; [ -n "$rn" ]
  [ "$dl" -lt "$ex" ]; [ "$ex" -lt "$rn" ]
  # the fake bash only ever saw the cd into the extracted dir plus the script
  grep -qF "cd '" "$T/calls"
  grep -qF "/cachyos-repo' && ./cachyos-repo.sh" "$T/calls"
}

@test "repos are not re-added when the live system already has them" {
  mk_tmp; printf '[options]\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n[core]\n' > "$T/pacman.conf"
  TVBOX_PACMAN_CONF="$T/pacman.conf" TVBOX_DRY_RUN=1 run bash -c ". '$REPO/autoinstall/arch/packages.sh'; arch_enable_cachyos_repos"
  [ "$status" -eq 0 ]; [[ "$output" == *"already configured"* ]]; [[ "$output" != *"DRY: curl"* ]]
}
@test "v3 repos are inserted above [core], once" {
  mk_tmp; printf '[options]\nHoldPkg = pacman\n\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$T/pacman.conf"
  run env -u TVBOX_DRY_RUN bash -c ". '$REPO/autoinstall/arch/packages.sh'; arch_use_v3_repos '$T/pacman.conf'; arch_use_v3_repos '$T/pacman.conf'"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[cachyos-v3\]' "$T/pacman.conf")" -eq 1 ]
  [ "$(grep -n '^\[cachyos-v3\]' "$T/pacman.conf" | cut -d: -f1)" -lt "$(grep -n '^\[core\]' "$T/pacman.conf" | cut -d: -f1)" ]
  grep -q '^\[cachyos-extra-v3\]' "$T/pacman.conf"
}
