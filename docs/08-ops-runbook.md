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
- **Restore test**: `backup-verify.timer` (Sundays 05:00) / `sudo tvbox verify-backup` checks the newest snapshot is recent, re-reads a rotating 5% of the repository, restores a random sample of real files (default 20) and byte-compares them with the live copies, and `gzip -t`s the database dumps. Failures notify; `tvbox doctor` flags a test older than 10 days.
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
`tvbox smart` (also daily, 06:15) reads SMART for every USB disk and the SSD; USB-SATA bridges are tried with `-d sat`. A failing disk raises an alert; growing pending/reallocated sectors raise a warning; a bridge that hides SMART shows UNKNOWN (never "failed").
`tvbox disks status`. A disk shown OFFLINE: reseat the cable; the minute-timer remounts it. Files that landed meanwhile sit on the SSD and drain on their own. SSD above 85%: `tvbox mover` now, then check that the data disk is online.

## If DNS breaks
Point the router (or one device) at your ISP DNS, then `docker logs pihole`, `tvbox doctor`.

## First boot checklist (things only real hardware can confirm)
1. `tvbox doctor` is green. 2. Unplug the data disk for a minute while uploading a photo; replug; confirm `tvbox status` returns to ONLINE and the file drains. 3. Open a Nextcloud share link on mobile data (public path). 4. `sudo tvbox backup`, then `restic snapshots`. 5. Reboot; confirm everything returns by itself.

## Laptop chassis (always on mains)
`tvbox-battery.service` caps the charge at `BATTERY_MAX_CHARGE` (default 80%) on batteries that expose `charge_control_end_threshold` (ThinkPads do), so a battery that never leaves the charger does not swell. Set `BATTERY_MAX_CHARGE=100` in `docker/.env` and re-run `sudo ./scripts/battery-care.sh` to charge fully (e.g. before travelling with the box).

## Optional: Paperless-ngx (profile `docs`)
Scans/PDFs with OCR + full-text search at `https://docs.<domain>`. Enable in the wizard (or add `docs` to `COMPOSE_PROFILES`), then `tvbox up`. Drop files in the **Paperless** network share (`pool/paperless/consume`); Paperless moves them into its own library (`pool/paperless/media`). Its database lives on the SSD; the nightly backup runs `document_exporter` into `pool/paperless/export` and backs that up with the originals. Admin login is in `~/tvbox-credentials.txt` (`PAPERLESS_ADMIN_*` in `docker/.env`). Not verifiable off-box: first login and consumption.

## Are the pinned images still real?
`scripts/check-images.py` resolves every image tag (compose files + `docker run` in scripts) against its registry; CI runs it weekly. A missing tag is fixed by changing the pin, never by `:latest` for databases.
