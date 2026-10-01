#!/usr/bin/env bash
# backups/backup.sh — restic backup of the pool to USB. FAILS LOUDLY on purpose:
# a backup that silently does nothing is worse than no backup script at all.
#
# What it backs up: the whole pool (sorted folders, private/, phone uploads),
# plus server config (.env) and Kodi userdata. Transient queue state (.ai-queue)
# and regenerable thumbs are excluded.
#
# One-time setup (on the box):
#   sudo mkdir -p /mnt/usb && sudo mount /dev/disk/by-uuid/<USB-UUID> /mnt/usb
#   openssl rand -base64 32 | sudo tee /root/restic-password >/dev/null
#   sudo chmod 600 /root/restic-password
# Runs weekly via configs/systemd/backup.timer (installed by scripts/install.sh).
set -euo pipefail
REPO="${RESTIC_REPO:-/mnt/usb/restic}"
PASS="${RESTIC_PASSWORD_FILE:-/root/restic-password}"
[ -f "$PASS" ] || { echo "backup: missing password file $PASS (see header setup)" >&2; exit 1; }
[ -d /mnt/usb ] || { echo "backup: /mnt/usb not mounted — plug in the USB disk" >&2; exit 1; }
export RESTIC_PASSWORD_FILE="$PASS"
restic -r "$REPO" cat-config >/dev/null 2>&1 || restic -r "$REPO" init
restic -r "$REPO" backup ~/tv-box-cloud-server/docker/.env /home/htpc/.kodi --exclude thumbs
restic -r "$REPO" backup /mnt/pool --exclude thumbs --exclude .ai-queue
restic -r "$REPO" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
restic -r "$REPO" check
echo "backup: OK $(date -Is)"
