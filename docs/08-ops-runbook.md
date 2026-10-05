# 08 — Ops Runbook

## Daily
`tvbox status` (storage, containers, URLs) and `tvbox doctor` (checks LAN IP, DNS, HTTPS, SMB, disks, containers, backup age). Alerts land in `/var/log/tvbox-alerts.log` and, if `NTFY_URL` is set in `docker/.env`, on your phone via ntfy.

## Updates
- OS: `sudo apt update && sudo apt upgrade` monthly; reboot test.
- Apps: `tvbox update` (git pull + `compose pull` + up). Watchtower only touches low-risk UIs.
- **Immich**: bump `IMMICH_VERSION` in `docker/.env` on the box *and* on the Legion together (`legion/` scripts read the same version). Read the release notes first.
- **Nextcloud**: majors cannot be skipped. Change `nextcloud:35-apache` one major at a time in `docker/cloud/compose.yml`, `docker compose up -d`, let it upgrade, repeat.
- **Pi-hole / Unbound / Gluetun / MariaDB / Postgres**: pinned on purpose; bump deliberately and read the notes.

## Backups
`backup.timer` runs `backups/backup.sh` nightly (03:30) to the **backup disk**: pool folders + DB dumps (Immich Postgres, Nextcloud MariaDB) + Pi-hole Teleporter + `.env`, `router.conf`, Caddy certs/CA, `/etc/tvbox`, Samba users. Failures notify; `tvbox doctor` flags a backup older than 3 days. `restic check` reads 2% of the data each night.
- **Restic password**: generated at install, shown once in `~/tvbox-credentials.txt`. It is deliberately **not** inside the backup. Put it in your password manager — without it the backups cannot be read.
- Backup disk smaller than the data? The script warns when the included folders exceed ~90% of it; trim `BACKUP_INCLUDE`.
- Offsite (optional, luxury): `rclone`/`restic copy` the repo to B2/Storj; the repo is already encrypted.

## Restore
```bash
sudo tvbox restore list                      # snapshots
sudo tvbox restore files /restore            # latest snapshot's files, under /restore, to inspect/copy back
sudo tvbox restore databases                 # reload Immich + Nextcloud dumps into the running stack
```
Disaster flow: re-flash -> bootstrap (same domain) -> put the restic password in `/etc/tvbox/restic-password` -> plug the backup disk -> `restore files` -> copy folders into `/mnt/pool` -> `restore databases`. **Test a restore once, now**, and quarterly after.

## Disks
`tvbox disks status`. A disk shown OFFLINE: reseat the cable; the minute-timer remounts it. Files that landed meanwhile sit on the SSD and drain on their own. SSD above 85%: `tvbox mover` now, then check that the data disk is online.

## If DNS breaks
Point the router (or one device) at your ISP DNS, then `docker logs pihole`, `tvbox doctor`.

## First boot checklist (things only real hardware can confirm)
1. `tvbox doctor` is green. 2. Unplug the data disk for a minute while uploading a photo; replug; confirm `tvbox status` returns to ONLINE and the file drains. 3. Open a Nextcloud share link on mobile data (public path). 4. `sudo tvbox backup`, then `restic snapshots`. 5. Reboot; confirm everything returns by itself.
