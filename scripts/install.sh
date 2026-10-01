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
# load only storage UUIDs for 40-storage.sh (never export secrets into child envs)
eval "$(grep -E '^(STORAGE_DISK1_UUID|STORAGE_DISK2_UUID|STORAGE_ROOT|CACHE_ROOT)=' ../docker/.env 2>/dev/null || true)"
log "tvbox install start"
./10-base.sh
./20-desktop-htpc.sh
./30-docker.sh
./40-storage.sh
./50-network-dns.sh
./60-tailscale-ssh.sh
# enable background units (queue drain, price refresh, inbox ingest, weekly backup)
for t in ai-queue.timer price-check.timer ingest.timer ingest.path backup.timer; do
  svc="../configs/systemd/${t%.timer}.service"
  [ "$t" = "ingest.path" ] && svc="../configs/systemd/ingest.service"
  [ "$t" = "backup.timer" ] && svc="../configs/systemd/backup.service"
  install -Dm644 "$svc" "/etc/systemd/system/${t%.*}.service" 2>/dev/null || true
  install -Dm644 "../configs/systemd/$t" "/etc/systemd/system/$t" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now ai-queue.timer price-check.timer ingest.timer ingest.path backup.timer 2>/dev/null || log "timers not enabled (no systemd?)"
./90-verify.sh
log "tvbox install done — next: cd ../docker && docker compose up -d"
