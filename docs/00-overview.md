# 00 — Overview & Architecture

## Goals
- Always-on box under the TV: family-usable, phone-remote friendly.
- Setup is **one command**; every secret is generated; every device onboards from one page.
- Uploads are fast (SSD write cache), data lives on cheap USB HDDs, and a loose cable never loses a file.
- Network-wide ad-blocking (Pi-hole + Unbound). No port forwarding. Tailscale away from home.
- Free/offline-first AI. Heavy models run on the Legion; external APIs only see redacted text for the few files the Legion is unsure about.

## Non-goals (for now)
- No RAID/ZFS on mismatched disks; no parity until a second large disk exists.
- No email server (deferred — see `09-roadmap-ideas.md`).
- No public exposure of logins or admin pages. Ever.

## Architecture

```
TV <-HDMI- [TV BOX]  Ubuntu Server 24.04 + (optional) Plasma/Kodi
  SSD (NVMe)  /mnt/cache   DBs, thumbnails, transcodes, landing/ (write cache)
  USB HDDs    /mnt/hdd/*   data disk(s) + a dedicated backup disk, mounted by UUID
  mergerfs    /mnt/pool    = landing (SSD) + data HDD(s). New writes -> SSD. mover.sh -> HDD.
  Docker      net:   Pi-hole, Unbound, Caddy, (cloudflared), Homepage, Uptime Kuma, Beszel
              cloud: Immich (+Postgres+Redis+ML), Nextcloud (+MariaDB+cron)
              media: Jellyfin, Navidrome, Audiobookshelf (profile)  torrent: gluetun+qBittorrent (profile)
  Host        Samba (\\tvbox\Uploads, \\tvbox\Cloud), Tailscale (subnet router), ingest + AI timers, restic

Phones/PCs --LAN--> Caddy (https://*.domain, trusted cert via Cloudflare DNS-01) --> apps
Away:  Tailscale (subnet route to the LAN IP; Pi-hole answers *.domain)   -> same URLs
Public: Cloudflare Tunnel -> Caddy, share-link paths ONLY (login/admin/upload blocked at Caddy)
Legion (GPU): Ollama (Jev judge, vision), whisper, Immich ML CUDA  -- over Tailscale
```

## Storage policy
- Per-disk ext4, identified by UUID in `/etc/tvbox/disks.conf`. Roles: **data** (pooled) and **backup** (restic only).
- Pool = `mergerfs(SSD landing : data HDDs)`, create policy `ff` -> writes always land on the SSD; the mover copies settled files to the roomiest healthy data disk, verifies, then frees the SSD. See `04-storage-smart-cloud.md`.
- Databases and thumbnails stay on the SSD (nightly dumps go to the backup disk).

## Decisions locked
1. Photos = **Immich**; Files = **Nextcloud**; plus **Samba** for plain network drives.
2. DNS = **Pi-hole v6 + Unbound**; reverse proxy = **Caddy** (only owner of :80/:443).
3. TLS = **Cloudflare DNS-01** wildcard on your domain (nothing to install on devices). Without a domain: Caddy local CA + a one-tap `root.crt` on the setup page.
4. Remote = **Tailscale** (subnet router) for everything; **Cloudflare Tunnel** only for public share links.
5. External AI = **Command Code Provider API** only; Legion first.
6. OS = **Ubuntu Server 24.04 LTS** recommended; Debian 13 / Linux Mint 22 work with the same installer.

## Cost policy
Free > self-hosted > cheap-and-smart > strong. External calls are redacted, transcript-only (~4KB), tiered (`jev` -> free -> value -> strong), and capped monthly. Honest exceptions: NVIDIA driver blob, Tailscale/Cloudflare control planes (proprietary, free tiers), open-weights model licenses.
