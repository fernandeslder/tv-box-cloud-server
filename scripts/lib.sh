#!/usr/bin/env bash
# lib.sh — shared helpers. Idempotent: check state before changing it.
set -euo pipefail
LOG=/var/log/tvbox-install.log
log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }; }
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
