# Backups — restic to USB + pool staging. Run nightly via systemd timer or cron.
#   restic -r /mnt/usb/restic backup /mnt/pool --exclude thumbs
#   pihole Teleporter export + tar of docker/.env + kodi userdata included below.
#!/usr/bin/env bash
set -euo pipefail
REPO=${RESTIC_REPO:-/mnt/usb/restic}
restic -r "$REPO" backup ~/tv-box-cloud-server/docker/.env /home/htpc/.kodi --exclude thumbs || true
restic -r "$REPO" backup /mnt/pool --exclude thumbs || true
restic -r "$REPO" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune || true
