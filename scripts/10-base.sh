#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh; need_root
apt-get update
apt_install mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers vainfo libva2 \
  smartmontools restic rclone htop curl git mergerfs
log "10-base ok"
