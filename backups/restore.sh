#!/usr/bin/env bash
# restore.sh — bring data and databases back from the backup disk.
#   restore.sh list                    snapshots
#   restore.sh files <target-dir>      restore the latest snapshot's files under <target-dir> (inspect, then copy back)
#   restore.sh databases               load the latest Immich + Nextcloud dumps into the running containers
# Typical disaster flow: re-flash -> ./setup.sh (same domain) -> plug the backup disk -> restore.sh files /restore
#   -> copy folders into /mnt/pool -> restore.sh databases. Details: docs/08-ops-runbook.md.
set -euo pipefail
. "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"
need_root
mp=""
while IFS='|' read -r _ role label; do
  [ "$role" = backup ] && [ -d "$HDD_ROOT/$label/restic" ] && mp="$HDD_ROOT/$label"
done < <(grep -vE '^\s*(#|$)' "$DISKS_CONF" 2>/dev/null || true)
REPO="${RESTIC_REPO:-${mp:+$mp/restic}}"
[ -n "${REPO:-}" ] || die "backup disk not found/mounted (sudo tvbox disks sync)"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$TVBOX_ETC/restic-password}"
[ -s "$RESTIC_PASSWORD_FILE" ] || die "restic password missing: put it in $RESTIC_PASSWORD_FILE (from tvbox-credentials.txt)"
case "${1:-list}" in
  list) restic -r "$REPO" snapshots ;;
  files) t="${2:?usage: restore.sh files <target-dir>}"; mkdir -p "$t"; restic -r "$REPO" restore latest --target "$t"; ok "restored to $t" ;;
  databases)
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    restic -r "$REPO" restore latest --target "$tmp" --include "$CACHE_ROOT/db-dumps"
    d="$tmp$CACHE_ROOT/db-dumps"; cd "$REPO_DIR/docker"
    [ -f "$d/immich.sql.gz" ] && gunzip -c "$d/immich.sql.gz" | docker compose exec -T immich-db psql -U immich -d immich >/dev/null && ok "Immich DB restored"
    [ -f "$d/nextcloud.sql.gz" ] && gunzip -c "$d/nextcloud.sql.gz" | docker compose exec -T -e MYSQL_PWD="$(env_get NEXTCLOUD_DB_ROOT_PASSWORD)" nextcloud-db mariadb -u root nextcloud && ok "Nextcloud DB restored"
    ;;
  *) die "usage: restore.sh list|files <dir>|databases" ;;
esac
