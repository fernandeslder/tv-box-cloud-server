#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
echo "== vainfo =="; vainfo 2>&1 | grep -iE "VA-API|H264|HEVC|VP9" || echo "VA-API not ready (ok on dev machine)"
echo "== docker =="; docker ps 2>&1 | head -n 20 || true
echo "== pool =="; mountpoint -q /mnt/pool && df -h /mnt/pool || echo "/mnt/pool not mounted (ok if HDDs pending)"
echo "== dns =="; ss -tulnp 2>/dev/null | grep -E ":53" || echo "port 53 free (good pre-pihole)"
have tailscale && tailscale status || echo "tailscale not up"
log "90-verify done"
