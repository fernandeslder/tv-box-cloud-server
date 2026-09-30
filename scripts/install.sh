#!/usr/bin/env bash
# install.sh — master bootstrap. Idempotent, safe to re-run via SSH/agent.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh
need_root
log "tvbox install start"
./10-base.sh
./20-desktop-htpc.sh
./30-docker.sh
./40-storage.sh
./50-network-dns.sh
./60-tailscale-ssh.sh
./90-verify.sh
log "tvbox install done — next: cd ../docker && docker compose up -d"
