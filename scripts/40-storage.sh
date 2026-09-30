#!/usr/bin/env bash
# 40-storage.sh — env-driven fstab, no secrets hardcoded.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh; need_root
mkdir -p /mnt/disk1 /mnt/disk2 /mnt/pool /mnt/cache
if [ -n "${STORAGE_DISK1_UUID:-}" ] && ! grep -q "$STORAGE_DISK1_UUID" /etc/fstab; then
  echo "UUID=$STORAGE_DISK1_UUID /mnt/disk1 ext4 defaults,nofail,x-systemd.automount 0 2" >> /etc/fstab
fi
if [ -n "${STORAGE_DISK2_UUID:-}" ] && ! grep -q "$STORAGE_DISK2_UUID" /etc/fstab; then
  echo "UUID=$STORAGE_DISK2_UUID /mnt/disk2 ext4 defaults,nofail,x-systemd.automount 0 2" >> /etc/fstab
fi
if ! grep -q "mergerfs" /etc/fstab; then
  echo "/mnt/disk* /mnt/pool fuse.mergerfs defaults,allow_other,use_ino,category.create=mfs,moveonenospc=true,minfreespace=20G,fsname=mergerfs 0 0" >> /etc/fstab
fi
systemctl daemon-reload
mount -a || log "pool mount deferred (disks not attached yet — ok)"
mkdir -p /mnt/pool/immich /mnt/pool/files /mnt/pool/media /mnt/pool/backups /mnt/cache || true
log "40-storage ok"
