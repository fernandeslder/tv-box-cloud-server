#!/usr/bin/env bash
# backup.sh — nightly restic backup to the dedicated BACKUP disk (never to the data disk).
#
# What goes in (the "important" set, sized for a smaller backup disk):
#   pool folders  : $BACKUP_INCLUDE (default: Photos Documents private Recordings Other immich nextcloud-data)
#   database dumps: Immich Postgres + Nextcloud MariaDB (the SSD holds the live DBs: a dump is what survives)
#   config        : docker/.env, router.conf, /etc/tvbox, Samba users, Pi-hole Teleporter export,
#                   Caddy certs/CA, Uptime Kuma, Nextcloud config.php
# What is skipped: Videos, Music, media/ (re-downloadable, big), thumbnails/transcodes (regenerable),
#   the AI queue. Add them with BACKUP_INCLUDE in docker/.env if the backup disk is big enough.
# FAILS LOUDLY: a backup that silently does nothing is worse than none. Failures notify.
set -euo pipefail
. "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"
need_root

NOTIFY="$REPO_DIR/scripts/notify.sh"
fail() { "$NOTIFY" error "backup FAILED: $*" || true; die "$*"; }

# ---- find the backup disk (role=backup, healthy) -----------------------------
mp=""
if [ -f "$DISKS_CONF" ]; then
  while IFS='|' read -r uuid role label; do
    [ "$role" = backup ] || continue
    cand="$HDD_ROOT/$label"
    if mountpoint -q "$cand" && [ "$(timeout 5 cat "$cand/.tvbox-disk" 2>/dev/null || true)" = "$uuid" ]; then mp="$cand"; break; fi
  done < <(grep -vE '^\s*(#|$)' "$DISKS_CONF")
fi
[ -n "$mp" ] || fail "no backup disk online. Plug it in (tvbox disks status) or register one: sudo scripts/disks.sh add /dev/sdX backup"
REPO="${RESTIC_REPO:-$mp/restic}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$TVBOX_ETC/restic-password}"
[ -s "$RESTIC_PASSWORD_FILE" ] || fail "missing restic password file $RESTIC_PASSWORD_FILE"
restic -r "$REPO" cat config >/dev/null 2>&1 || restic -r "$REPO" init >/dev/null

# ---- dumps ------------------------------------------------------------------
DUMPS="$CACHE_ROOT/db-dumps"; mkdir -p "$DUMPS"
cd "$REPO_DIR/docker"
dc() { docker compose "$@"; }
if dc ps --status running immich-db 2>/dev/null | grep -q immich-db; then
  dc exec -T immich-db pg_dump -U immich -d immich --clean --if-exists | gzip > "$DUMPS/immich.sql.gz.tmp" \
    && mv "$DUMPS/immich.sql.gz.tmp" "$DUMPS/immich.sql.gz" || fail "Immich DB dump failed"
else echo "backup: immich-db not running, skipping its dump" >&2; fi
if dc ps --status running nextcloud-db 2>/dev/null | grep -q nextcloud-db; then
  dc exec -T -e MYSQL_PWD="$(env_get NEXTCLOUD_DB_ROOT_PASSWORD)" nextcloud-db mariadb-dump -u root --single-transaction nextcloud \
    | gzip > "$DUMPS/nextcloud.sql.gz.tmp" && mv "$DUMPS/nextcloud.sql.gz.tmp" "$DUMPS/nextcloud.sql.gz" || fail "Nextcloud DB dump failed"
else echo "backup: nextcloud-db not running, skipping its dump" >&2; fi
# Pi-hole v6 Teleporter export (settings, lists, local DNS).
ph_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(dc ps -q pihole 2>/dev/null | head -n1)" 2>/dev/null || true)"
if [ -n "$ph_ip" ]; then
  PH_PASS="$(env_get PIHOLE_PASS)" PH_IP="$ph_ip" OUT="$DUMPS/pihole-teleporter.zip" python3 - <<'PY' || echo "backup: Pi-hole export skipped" >&2
import json, os, urllib.request
base = f"http://{os.environ['PH_IP']}:8080/api"
req = urllib.request.Request(base + "/auth", json.dumps({"password": os.environ["PH_PASS"]}).encode(), {"Content-Type": "application/json"})
sid = json.load(urllib.request.urlopen(req, timeout=15))["session"]["sid"]
req = urllib.request.Request(base + "/teleporter", headers={"sid": sid})
open(os.environ["OUT"], "wb").write(urllib.request.urlopen(req, timeout=60).read())
PY
fi
cp -a /var/lib/samba/private/passdb.tdb "$DUMPS/samba-passdb.tdb" 2>/dev/null || true

# ---- what to back up ----------------------------------------------------------
INCLUDE="${BACKUP_INCLUDE:-$(env_get BACKUP_INCLUDE "Photos Documents private Recordings Other immich nextcloud-data")}"
paths=("$DUMPS" "/var/lib/tvbox" "$ENV_FILE" "$REPO_DIR/configs/router.conf" "$TVBOX_ETC" "$REPO_DIR/docker/net/data" "$REPO_DIR/docker/cloud/data")
need=0
for d in $INCLUDE; do
  [ -e "$STORAGE_ROOT/$d" ] || continue
  paths+=("$STORAGE_ROOT/$d")
  need=$((need + $(du -sb "$STORAGE_ROOT/$d" 2>/dev/null | cut -f1)))
done
free="$(df -B1 --output=avail "$mp" | tail -n1 | tr -dc '0-9')"
if [ "$need" -gt "$((free * 9 / 10))" ]; then
  "$NOTIFY" warn "backup disk may be too small: data to back up $((need / 1073741824))GB, free $((free / 1073741824))GB. Trim BACKUP_INCLUDE in docker/.env." || true
fi

restic -r "$REPO" backup --tag nightly --exclude '**/thumbs' --exclude '**/encoded-video' --exclude '**/.ai-queue' --exclude "$TVBOX_ETC/restic-password" \
  --exclude "$REPO_DIR/docker/net/data/caddy-config" "${paths[@]}" || fail "restic backup failed (is the backup disk full?)"
restic -r "$REPO" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune || fail "restic prune failed"
restic -r "$REPO" check --read-data-subset=2% || fail "restic check found a problem"

install -d /var/lib/tvbox; date -Is > /var/lib/tvbox/last-backup
echo "backup: OK $(date -Is) -> $REPO"
