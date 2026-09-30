# 08 — Ops Runbook

## Updates
- OS: `sudo apt update && sudo apt upgrade -y` monthly + reboot test (pool + containers come up via fstab automount + `restart: unless-stopped`).
- Docker images: Watchtower (fork `nickfedor/watchtower`) auto-updates labeled safe UIs at 4am. Manually `docker compose pull && up -d` for Pi-hole/Unbound/Gluetun/qbit/Immich (pin Immich server + ML to same version).
- Immich: server + remote-ML versions MUST match. Update both together.

## Backup / restore
```bash
./backups/backup.sh          # restic to /mnt/usb + /mnt/pool/backups + pihole teleporter + kodi userdata tar
restic -r /mnt/usb/restic snapshots
restic -r /mnt/usb/restic mount /tmp/restore  # test quarterly
```
What is backed up: `docker/.env`, compose files, `pihole.toml` + Teleporter export, Postgres dump (Immich), `/home/htpc/.kodi`, Caddy data. What is NOT re-backed-up: Immich thumbs (regenerable).

## Re-flash recovery
User data survives on HDD pool. Recovery = flash (doc 01) → clone → fill `.env` → `install.sh` → `compose up -d` → `backup.sh restore`. Test with a reboot before pointing router DNS at Pi-hole.

## Monitoring
Homepage (family dashboard) + Uptime Kuma (alerts for Pi-hole/Caddy/Immich) + Beszel (disk/RAM) + Scrutiny (SMART) optional. `uptime-kuma` data in volume so history survives restarts.

## If DNS breaks (Pi-hole down)
Router fallback: set router DNS back to `1.1.1.1` temporarily, then `docker logs pihole` + `ss -tulnp | grep :53` + re-run `50-network-dns.sh`.
