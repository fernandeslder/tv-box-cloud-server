# 04 — Storage: USB HDDs as the vault, the SSD as a write cache

## Layout
| Path | What | Where it physically lives |
|---|---|---|
| `/mnt/cache` | Postgres, MariaDB, thumbnails, transcodes, DB dumps | NVMe |
| `/mnt/cache/landing` | write cache branch of the pool | NVMe |
| `/mnt/hdd/data1`, `data2`… | data disks (role `data`) | USB HDD |
| `/mnt/hdd/backup1` | backup disk (role `backup`, restic only) | USB HDD |
| `/mnt/pool` | **the one folder everything uses** | mergerfs(landing + data disks) |

Pool folders: `inbox/ Photos/ Documents/ Music/ Recordings/ Videos/ Other/ private/ duplicates/ immich/ nextcloud-data/ media/`. They are group `www-data`, setgid, so Samba, ingest and Nextcloud all read/write the same files.

## How a write flows
1. Phone/PC uploads -> mergerfs picks the first branch with space: the **SSD** (`category.create=ff`, `minfreespace=20G`). Full network speed, no HDD wait.
2. `tvbox-mover.timer` (every 10 min, idle priority) copies files that are settled (>15 min untouched) **and** older than the keep window (3 days = read cache) to the data disk with the most free space, verifies byte-for-byte, then deletes the SSD copy.
3. When the SSD passes **70% full** the mover ignores the keep window and drains oldest-first down to 50%.
Tune in `docker/.env`: `MOVER_MIN_AGE_MIN`, `MOVER_KEEP_DAYS`, `MOVER_HIGH_PCT`, `MOVER_LOW_PCT`, `LANDING_MIN_FREE`.

**Honest trade-off:** a file is on the SSD only until the mover runs. The window is short for big/old files and up to a few days for recent ones; if the SSD dies in that window, those files are lost. The nightly backup copies from the pool (SSD + HDD), so it covers them once it has run.

## When a USB disk disconnects
- `tvbox-storage.timer` (every minute) + a udev rule re-run `disks.sh sync`: a disk whose UUID reappears is fsck'd (`-p`), remounted and re-added to the pool **live** (no container restarts). A disk that stopped answering is lazily unmounted and removed from the pool.
- Meanwhile `/mnt/pool` never disappears (the SSD branch is always there): uploads continue; reads of files only on the missing disk fail until it returns. `tvbox status` shows `OFFLINE`; `tvbox doctor` says what to do.
- Empty mountpoints are `chattr +i`, so nothing can silently write into `/mnt/hdd/data1` on the SSD while the disk is away. Every disk carries a `.tvbox-disk` sentinel checked before use.
- USB autosuspend is turned off for mass-storage devices (udev). If a specific enclosure still drops, see "Troubleshooting USB" below.

## Adding / replacing disks
```bash
sudo tvbox disks scan                       # blank / has-data / system
sudo tvbox disks add /dev/sdX data          # formats ext4 after you type ERASE sdX
sudo tvbox disks add /dev/sdY backup
```
Disks with existing data need `--force` (and still ask). The system disk is never offered.

## Photos = Immich
Originals land in `/mnt/pool/immich`; thumbnails and encoded video live on the SSD. The sorted `Photos/` tree is added automatically as a **read-only external library** (`/external/photos`) so faces and search cover everything with no duplication. Phone: Immich app auto-backup. Faces: name each person once in the People view.

## Files = Nextcloud
Data dir `/mnt/pool/nextcloud-data`; MariaDB on the SSD. `post-install.sh` links the sorted folders (`Uploads Photos Documents Music Videos Recordings Other` + admin-only `private`) as **External Storage**, so everything the ingest sorts is visible in Nextcloud. Set the phone app's auto-upload folder to **Uploads**.

## Backups (3-2-1, local half)
Dedicated backup disk, restic, nightly 03:30: Photos, Documents, private, Recordings, Other, immich, nextcloud-data + DB dumps + configs. Videos/Music/media are skipped by default (re-downloadable; size). Details and restore: `08-ops-runbook.md`.

## Troubleshooting USB
Frequent `reset`/`disconnect` in `dmesg`: try another cable/port, a powered hub or the enclosure's own PSU; as a last resort disable UAS for that enclosure (`usb-storage.quirks=VID:PID:u` on the kernel command line — find the IDs with `lsusb`).
