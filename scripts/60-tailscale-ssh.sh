#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh; need_root
if ! have tailscale; then
  curl -fsSL -m 60 --retry 3 https://tailscale.com/install.sh | sh
else
  log "tailscale already present"
fi
install -Dm644 ../configs/ssh/10-hardening.conf /etc/ssh/sshd_config.d/10-hardening.conf
systemctl reload sshd || true
log "60-tailscale ok — run: tailscale up --ssh --accept-dns"
