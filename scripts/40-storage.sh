#!/usr/bin/env bash
# 40-storage.sh — SSD cache + USB HDD storage.
#   /mnt/cache            NVMe: Docker DBs, thumbnails, transcodes, and landing/ (the write cache)
#   /mnt/hdd/<label>      each USB disk, mounted by UUID by scripts/disks.sh
#   /mnt/pool             mergerfs(landing + data disks): the one folder every app and share uses
# Disks come from, in order: already registered (/etc/tvbox/disks.conf),
# TVBOX_DISKS="/dev/sdb:data,/dev/sdc:backup" (unattended), or an interactive proposal.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root

mkdir -p "$CACHE_ROOT" "$LANDING_DIR" "$HDD_ROOT"
install -d "$TVBOX_ETC"
render "$REPO_DIR/configs/systemd/99-tvbox-usb.rules" /etc/udev/rules.d/99-tvbox-usb.rules
udevadm control --reload 2>/dev/null || true

register_disks() {
  "$REPO_DIR/scripts/disks.sh" adopt || true
  local plan="${TVBOX_DISKS:-$(env_get TVBOX_DISKS)}" item dev role
  if [ -n "$plan" ]; then
    for item in ${plan//,/ }; do
      dev="${item%%:*}"; role="${item##*:}"
      "$REPO_DIR/scripts/disks.sh" add "$dev" "$role" --yes
    done
    return
  fi
  [ -s "$DISKS_CONF" ] && grep -qvE '^\s*(#|$)' "$DISKS_CONF" && return 0
  [ -t 0 ] || { warn "no disks registered and no terminal: running SSD-only. Add disks later: sudo scripts/disks.sh scan"; return 0; }

  echo; echo "USB / extra disks found:"; "$REPO_DIR/scripts/disks.sh" scan; echo
  # Blank, non-system disks, biggest first.
  mapfile -t blanks < <("$REPO_DIR/scripts/disks.sh" scan | awk '/blank/ {print $1" "$2}' | sort -k2 -h -r | awk '{print $1}')
  if [ "${#blanks[@]}" -eq 0 ]; then
    warn "no blank disks to format. Plug them in and run: sudo ./scripts/disks.sh scan"
    return 0
  fi
  echo "Proposed plan:"
  local i=0
  for dev in "${blanks[@]}"; do
    if [ "$i" -eq 0 ]; then role=data; elif [ "$i" -eq 1 ]; then role=backup; else role=data; fi
    echo "  $dev -> $role   ($(lsblk -ndo SIZE,MODEL "$dev"))"; plan="$plan$dev:$role "; i=$((i + 1))
  done
  echo "  data   = where your files live (biggest disk)"
  echo "  backup = nightly restic backups of the important folders (second disk)"
  printf '\nThis ERASES the disks above. Type ERASE to continue, or Enter to skip: '
  read -r ans
  if [ "$ans" != ERASE ]; then warn "skipped — running SSD-only. Re-run setup when ready."; return 0; fi
  for item in $plan; do "$REPO_DIR/scripts/disks.sh" add "${item%%:*}" "${item##*:}" --yes; done
}

register_disks
"$REPO_DIR/scripts/disks.sh" sync

# Folder skeleton. Shared group www-data (gid 33) = Nextcloud's group inside its container,
# so Samba, ingest, Immich-import and Nextcloud all read/write the same files.
if mountpoint -q "$STORAGE_ROOT"; then
  for d in inbox Photos Documents Music Recordings Videos Other private duplicates immich nextcloud-data media backups-staging .ai-queue; do
    mkdir -p "$STORAGE_ROOT/$d"
  done
  chown "$TVBOX_USER:www-data" "$STORAGE_ROOT"/{inbox,Photos,Documents,Music,Recordings,Videos,Other,private,duplicates,media,.ai-queue}
  chmod 2775 "$STORAGE_ROOT"/{inbox,Photos,Documents,Music,Recordings,Videos,Other,duplicates,media,.ai-queue}
  chmod 2770 "$STORAGE_ROOT/private"
  chown 33:33 "$STORAGE_ROOT/nextcloud-data"; chmod 750 "$STORAGE_ROOT/nextcloud-data"
  chown root:root "$STORAGE_ROOT/immich" "$STORAGE_ROOT/backups-staging"
else
  die "pool did not mount at $STORAGE_ROOT — check: sudo ./scripts/disks.sh status"
fi

# Cache-side dirs for containers (databases etc. live here, never on the HDDs).
mkdir -p "$CACHE_ROOT"/{immich-pg,immich-thumbs,immich-encoded,nextcloud-db,redis,jellyfin-transcode,db-dumps}

# Units: render @REPO@/@USER@/@POOL@ and enable.
POOL="$STORAGE_ROOT"; USER_="$TVBOX_USER"; REPO="$REPO_DIR"
for f in "$REPO_DIR"/configs/systemd/*.service "$REPO_DIR"/configs/systemd/*.timer "$REPO_DIR"/configs/systemd/*.path; do
  n="$(basename "$f")"
  sed -e "s#@REPO@#$REPO#g" -e "s#@USER@#$USER_#g" -e "s#@POOL@#$POOL#g" "$f" > "/etc/systemd/system/$n"
done
systemctl daemon-reload
systemctl enable --now tvbox-storage.timer tvbox-mover.timer >/dev/null 2>&1 || warn "could not enable storage timers"
log "40-storage ok"
"$REPO_DIR/scripts/disks.sh" status
