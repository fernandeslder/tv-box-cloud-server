# 04 — Storage + Smart Cloud (Immich + Nextcloud)

## Filesystem: ext4 per-disk + mergerfs pool
Mismatched 1TB+4TB, growable — do NOT use ZFS/bcachefs/btrfs-RAID here.

```bash
# /etc/fstab (UUIDs from blkid, use nofail + automount)
UUID=<1TB-UUID>  /mnt/disk1 ext4 defaults,nofail,x-systemd.automount 0 2
UUID=<4TB-UUID>  /mnt/disk2 ext4 defaults,nofail,x-systemd.automount 0 2
/mnt/disk* /mnt/pool fuse.mergerfs defaults,allow_other,use_ino,category.create=mfs,moveonenospc=true,minfreespace=20G,fsname=mergerfs 0 0
```

## SSD vs HDD roles
- SSD `/mnt/cache` (ext4, 238GB NVMe): `/var/lib/docker`, Postgres, Redis, Immich `thumbs/encoded-video`, Nextcloud previews, model-cache. This is the "1GB/s ingest" feel — HDD sequential (~180MB/s) already saturates 1Gbps (125MB/s); DB/thumbs latency is the real bottleneck.
- Pool `/mnt/pool`: `inbox/` (single Uploads target, drained by ingest), `Photos/ Documents/ Music/ Recordings/ Videos/ Other/ private/` (ingest sorted, all in Nextcloud), `immich/` (photo originals), `files/` (Nextcloud data), `media/` (Jellyfin), `backups/`.
- Optional SSD landing + nightly mover (`rsync --remove-source-files` + rescan) — simpler to write originals direct to pool and keep thumbs on SSD.

## Photos = Immich (primary)
- Server + Postgres (`pgvector/pgvector:pg16`) + Redis on SSD; `UPLOAD_LOCATION=/mnt/pool/immich`.
- Phone: Immich app auto-backup (incremental, background). Nextcloud app only for docs.
- No manual folders: timeline + map + CLIP search + faces + auto-albums. Ollama captions → Immich API tags (see `06-ai-classification.md`).
- Faces: detection is automatic (InsightFace in immich-ml). You name each person once in the app's People view; from then on search "Maya" and get every photo of Maya. To cover the sorted folders too, add `/mnt/pool/Photos` as an Immich **external library** (read-only) — faces + search over everything, zero duplication.
- Compose: `docker/cloud/compose.yml`. Keep local `immich-machine-learning` as CPU fallback; prefer remote CUDA on laptop.

## Uploads: everything lands in `inbox/`
- `inbox/` is the single Uploads target: point the Nextcloud phone app's auto-upload folder at it, save manual downloads (music, photos, files) straight into it, symlink `~/Uploads` to it. `ingest.sh` drains it into sorted folders; nothing lives in `inbox/` permanently.

## Files = Nextcloud (+ Memories)
- Docs/files only, data dir `/mnt/pool/files`. If you want pure speed over collaboration, swap to **Seafile** (SeafDrive virtual disk, faster than WebDAV).
- Do NOT point Immich + Nextcloud Photos + PhotoPrism at the same library. `Immich=photos, Nextcloud=files`.

## Backup (3-2-1)
- Nightly `restic -r /mnt/usb/restic backup /mnt/pool --exclude thumbs`, `forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
- Weekly `restic copy` / `rclone sync` encrypted to B2/Storj (~$6/TB/mo, paid + proprietary APIs — optional). The free path is USB + second disk; offsite is a luxury, not a requirement. Test `restic mount` restore quarterly.
- SnapRAID: skip now (4TB parity for 1TB data = wasteful). Add when you have 2 data disks + parity disk ≥ largest data disk.

## Order
1. ext4 + mergerfs pool, 2. Immich + Postgres on SSD, 3. remote ML on laptop via Tailscale, 4. Nextcloud/Seafile only if needed, 5. Presidio sidecar, 6. restic to USB, 7. add 4TB + SnapRAID later.
