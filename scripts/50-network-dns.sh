#!/usr/bin/env bash
# 50-network-dns.sh — free port 53 for Pi-hole, set up the LAN firewall.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
install -d /etc/systemd/resolved.conf.d
install -m644 "$REPO_DIR/configs/systemd/no-stub.conf" /etc/systemd/resolved.conf.d/no-stub.conf
if [ -d /run/systemd/resolve ]; then
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved || true
fi

# Firewall: LAN + Tailscale in, everything else out of reach. Private ranges only, so
# a wrong LAN guess can never lock you out of SSH on the same network.
if [ "$(env_get TVBOX_FIREWALL yes)" = yes ] && have ufw; then
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fe80::/10; do
    ufw allow from "$net" >/dev/null
  done
  ufw allow in on tailscale0 >/dev/null 2>&1 || true
  ufw --force enable >/dev/null
  ok "firewall on: private LAN + Tailscale only"
fi
log "50-network-dns ok"
