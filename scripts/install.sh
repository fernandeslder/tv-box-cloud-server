#!/usr/bin/env bash
# install.sh — master bootstrap. Idempotent, safe to re-run via SSH/agent.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh
need_root
# auto-create .env files from examples so a fresh clone just works (user still edits passwords/UUIDs)
[ -f ../docker/.env ] || { cp ../docker/.env.example ../docker/.env; log "created docker/.env from example — EDIT passwords/UUIDs"; }
[ -f ../docker/cloud/.env.immich ] || { cp ../docker/cloud/.env.immich.example ../docker/cloud/.env.immich 2>/dev/null || true; }
[ -f ../configs/router.conf ] || { cp ../configs/router.conf.example ../configs/router.conf; log "created configs/router.conf (paid escalation OFF by default)"; }
# load UUIDs/paths for storage step if present
set -a; [ -f ../docker/.env ] && . ../docker/.env; set +a
log "tvbox install start"
./10-base.sh
./20-desktop-htpc.sh
./30-docker.sh
./40-storage.sh
./50-network-dns.sh
./60-tailscale-ssh.sh
./90-verify.sh
log "tvbox install done — next: cd ../docker && docker compose up -d"
