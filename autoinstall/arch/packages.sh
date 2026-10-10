# shellcheck shell=bash
# packages.sh — CachyOS (Arch) repository and package helpers. Sourced by arch-install.sh.
#
#   arch_enable_cachyos_repos   add the CachyOS repos to pacman the official way
#   arch_base_packages          the pacstrap package list, one per line
#
# Test hooks: TVBOX_DRY_RUN=1 (prints every action instead of running it).

CACHYOS_REPO_URL="https://mirror.cachyos.org/cachyos-repo.tar.xz"

DRY="${TVBOX_DRY_RUN:-0}"
run() { if [ "$DRY" = 1 ]; then echo "DRY: $*"; else "$@"; fi; }

# The official one-shot setup: download the tarball, unpack it, and run its
# script — it detects x86-64-v3/v4/znver4 itself and writes the matching
# repos into /etc/pacman.conf (and imports the CachyOS keyring).
arch_enable_cachyos_repos() {
  local tmp
  tmp="$(mktemp -d)"
  run curl -fsSL -o "$tmp/cachyos-repo.tar.xz" "$CACHYOS_REPO_URL"
  run tar -xf "$tmp/cachyos-repo.tar.xz" -C "$tmp"
  # the script stages its own pacman.conf in its directory, so run it from there
  run bash -c "cd '$tmp/cachyos-repo' && ./cachyos-repo.sh"
  rm -rf "$tmp"
}

# Base system for pacstrap. Every name verified against archlinux.org/packages
# and the CachyOS repo list (mirror.cachyos.org) on 2026-10-10.
arch_base_packages() {
  local pkgs=(
    base
    base-devel
    linux-cachyos
    linux-cachyos-headers
    linux-firmware
    amd-ucode
    btrfs-progs
    networkmanager
    openssh
    sudo
    git
    curl
    nano
    vim
    htop
    man-db
    zram-generator
    avahi
    nss-mdns
    ufw
    cachyos-keyring
    cachyos-mirrorlist
    cachyos-v3-mirrorlist
    cachyos-settings
    fuse3
    vulkan-radeon
  )
  if [ "${TVBOX_GPU:-}" = nvidia ]; then
    # exact name from the CachyOS repo (DKMS module, builds against linux-cachyos)
    pkgs+=(nvidia-open-dkms)
  fi
  printf '%s\n' "${pkgs[@]}"
}
