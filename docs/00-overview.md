# 00 — Overview & Architecture

## Goals
- Always-on, always plugged into TV via HDMI. Family-usable with phone remote.
- 1Gbps LAN uploads to cloud storage. No manual folders — timeline + search + auto-tags.
- Free/offline-first AI. Heavy models run on laptop (12GB VRAM), never pay per-image.
- Pi-hole network-wide ad-blocking. No port forwarding — Tailscale for remote.
- Fully reproducible: flash → `git clone` → `install.sh` → `docker compose up -d`. An agent can redo it over SSH.

## Non-goals (for now)
- No Proxmox/NixOS/Bazzite/ChimeraOS (see `docs/01-flash-guide.md` rationale).
- No RAID/ZFS on mismatched 1TB+4TB. No parity until 2nd large disk.
- No public internet exposure. No paid photo-AI APIs as primary path.

## Architecture

```
TV <—HDMI— [TV BOX] AMD Ryzen 5 PRO 4650U, 14GB, 238GB NVMe
  Bare metal: Ubuntu 24.04 + Plasma + Kodi -fs + VacuumTube/Firefox/Moonlight/Stremio/IPTVnator
  Docker (SSD: /mnt/cache, HDD pool: /mnt/pool):
    net:    pihole:53 + unbound:5335 + caddy:80/443 + dockge + homepage + uptime-kuma
    cloud:  immich-server + postgres + redis (SSD) + originals on /mnt/pool/immich
            nextcloud (files on /mnt/pool/files) + presidio-analyzer (PII gate) + restic
    media:  jellyfin (/dev/dri VA-API) + gluetun + qbittorrent (opt-in)

Phones --1Gbps LAN--> Caddy (*.home.lan) --> Immich/Nextcloud
  Immich app (photos) + Nextcloud app (docs)

Laptop (12GB VRAM) --Tailscale--> immich-machine-learning:cuda + ollama (moondream/llava)
  Immich server fans out to remote ML URL; Presidio blocks PII before any cloud fallback.

Router DHCP --> DNS = Pi-hole IP. Pi-hole upstream = Unbound (recursive, no third party).
Remote: Tailscale Split-DNS --> Pi-hole tailnet IP --> Caddy. No port forwards.
```

## Storage policy
- Per-disk `ext4`. Pool via `mergerfs`: `/mnt/disk1 + /mnt/disk2 -> /mnt/pool`, `category.create=mfs,minfreespace=20G`.
- SSD (`/mnt/cache`): Docker, Postgres, Redis, Immich thumbs/encoded-video, Nextcloud previews — this is what makes it feel instant.
- HDD pool: Immich originals, Nextcloud data, Jellyfin media, backups staging.
- Backup: nightly `restic` to USB + weekly `rclone` to B2/Storj (encrypted). SnapRAID only when you have 2 data disks + parity.

## Decisions locked
1. Photos = **Immich** (best face/CLIP/search, native app, offline).
2. Files = **Nextcloud** (collab) — swap to **Seafile** if you only want raw speed.
3. DNS = **Pi-hole v6 + Unbound** (user asked Pi-hole; recursive = max privacy).
4. YouTube TV UI = **VacuumTube**, not Kodi YouTube addon (API-key/quota pain).
5. Moonlight client = **moonlight-qt**, host = **Sunshine** on gaming PC.
6. Stremio v5 + **Torrentio** (`https://torrentio.strem.fun`) + optional Debrid.
7. Proxy = **Caddy** (only owner of :80/:443). Pi-hole web remapped to :8080.
