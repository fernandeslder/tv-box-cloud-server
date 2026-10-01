# TV Box + Cloud Server

One always-on box, HDMI to TV. Two jobs:
1. **TV box** — couch UI for YouTube, Twitch, Moonlight (gaming PC), browser, IPTV, Stremio + Torrentio.
2. **Smart cloud server** — SSD ingest cache + 1TB + 4TB HDD pool, auto phone upload, automatic classification, local secrets screening, Pi-hole ad-blocking.

Target hardware: AMD Ryzen 5 PRO 4650U + Radeon iGPU, 14GB RAM, 238GB NVMe (cache), 1TB + 4TB HDDs (added later).
AI offload machine: Legion 7, RTX 4080 Laptop 12GB VRAM + 32GB RAM (see `docs/10-legion-ai-server.md`).
OS target: **Ubuntu 24.04 LTS + Plasma minimal + Kodi** (see `docs/`).

## Quick start (after OS flash)

```bash
git clone https://github.com/fernandeslder/tv-box-cloud-server.git ~/tv-box-cloud-server
cd ~/tv-box-cloud-server
cp docker/.env.example docker/.env && nano docker/.env
sudo ./scripts/install.sh
cd docker && docker compose config --quiet && docker compose up -d
./scripts/90-verify.sh
```

## Layout

```
README.md
docs/           # full plan: flash, OS, HTPC, storage, AI, Pi-hole, ops, roadmap
docker/         # compose stacks (net, cloud, media) + .env.example
scripts/        # idempotent bootstrap (safe to re-run via SSH / agent)
configs/        # sddm, resolved, fstab, kodi snippets
backups/        # backup.sh + policy
```

## Service map (final)

| Stack | Services | Access |
|---|---|---|
| HTPC (bare metal, not Docker) | Kodi, VacuumTube, Firefox, Moonlight-qt, Stremio, IPTVnator, Spotube | TV HDMI |
| net | Pi-hole v6 + Unbound, Caddy, Tailscale, Dockge, Homepage, Uptime Kuma, Beszel, Watchtower | `*.home.lan` |
| cloud | Immich + Postgres + Redis, Nextcloud (files), TruffleHog + local LLM secrets gate, restic | `photos.home.lan`, `files.home.lan` |
| media/dl (opt-in) | Jellyfin, qBittorrent + Gluetun, Prowlarr/Sonarr/Radarr | `jellyfin.home.lan` |
| Legion 7 (AI worker) | Ollama (`qwen2.5:3b` secrets judge + `moondream` vision) + Immich remote ML `:3003` | Tailscale only |

## Docs index

- `docs/00-overview.md` — goals, architecture diagram
- `docs/01-flash-guide.md` — full OS setup checklist (USB → installer → first boot)
- `docs/02-os-postinstall.md` — drivers, autologin, VA-API
- `docs/03-htpc-tv.md` — Kodi + apps + remotes
- `docs/04-storage-smart-cloud.md` — mergerfs + Immich + Nextcloud
- `docs/05-network-pihole.md` — Pi-hole + Unbound + Caddy + Tailscale
- `docs/06-ai-classification.md` — secrets screening (TruffleHog + local LLM judge) + OCR
- `docs/07-remote-access.md` — SSH + agent reinstall flow
- `docs/08-ops-runbook.md` — updates, backup/restore
- `docs/09-roadmap-ideas.md` — extras I recommend
- `docs/10-legion-ai-server.md` — Legion 7 setup (do in parallel with TV box install)

Status: **planning phase**. Nothing is installed by these docs alone. Run `scripts/install.sh` only on the flashed target.
