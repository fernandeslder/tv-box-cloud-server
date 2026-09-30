#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh; need_root
mkdir -p /etc/systemd/resolved.conf.d
install -m644 ../configs/systemd/no-stub.conf /etc/systemd/resolved.conf.d/no-stub.conf
rm -f /etc/resolv.conf && ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved || true
log "50-network-dns ok"
