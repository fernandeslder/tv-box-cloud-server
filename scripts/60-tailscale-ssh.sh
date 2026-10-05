#!/usr/bin/env bash
# 60-tailscale-ssh.sh — Tailscale (+ LAN subnet router) and SSH hardening that cannot lock you out.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
if ! have tailscale; then
  curl -fsSL -m 60 --retry 3 https://tailscale.com/install.sh | sh
fi
# Subnet routing: remote devices reach the box at its normal LAN IP, so one DNS answer works everywhere.
printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/99-tvbox-tailscale.conf
sysctl -p /etc/sysctl.d/99-tvbox-tailscale.conf >/dev/null 2>&1 || true
lan="$(env_get LAN_CIDR)"
args=(up --ssh --accept-dns=false)
[ -n "$lan" ] && args+=("--advertise-routes=$lan")
key="$(env_get TAILSCALE_AUTHKEY)"
[ -n "$key" ] && args+=("--authkey=$key")
if tailscale status >/dev/null 2>&1; then
  tailscale "${args[@]}" >/dev/null 2>&1 || true
elif [ -n "$key" ]; then
  tailscale "${args[@]}" || warn "tailscale up failed"
else
  warn "Tailscale installed but not logged in. Run once:  sudo tailscale ${args[*]}"
  warn "then approve the subnet route + set Split DNS in the admin console (docs/05)."
fi

# Key-only SSH — but only if a key exists, otherwise this would lock you out.
if [ -s "$TVBOX_HOME/.ssh/authorized_keys" ]; then
  install -Dm644 "$REPO_DIR/configs/ssh/10-hardening.conf" /etc/ssh/sshd_config.d/10-hardening.conf
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  warn "no SSH key for $TVBOX_USER yet: leaving password login on. Add a key, then re-run setup."
fi
log "60-tailscale ok"
