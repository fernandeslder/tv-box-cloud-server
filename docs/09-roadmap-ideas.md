# 09 — Roadmap / Extra Ideas

**Deferred: email.** A mailbox on your domain needs an outbound relay and Cloudflare Email Routing for inbound (Bell blocks port 25 and mail cannot ride a Tunnel). Plan: Stalwart or Mailcow-lite + Brevo/SMTP2GO relay. Not built yet.

Beyond what you asked — all fit your taste, all free, all run on this box:

1. **Jellyfin server** (`/dev/dri` VA-API) — local movie/show library on the pool, plays in Kodi + Jellyfin Desktop + phones. (Prowlarr/Sonarr/Radarr are not included yet; add them behind Gluetun if wanted.)
2. **Paperless-ngx** — auto-ingest scans/PDFs from Nextcloud, OCR + full-text search. Complements the Tier-0/1 screening (it only ever sees clean files).
3. **Navidrome — self-hosted Spotify (NEXT UP, already in `docker/media/compose.yml`)** — Subsonic-API music server, ~50MB RAM, reads pool `Music/` read-only (ingest sorts it). Phone apps (both FOSS): **Tempo** (GPL, recommended) or **Ultrasonic** (GPL). Web UI included. Handles playlists, transcodes FLAC→MP3 on the fly for mobile data. Start it the day your first albums land in `Music/`.
4. **Audiobookshelf (NEXT UP, already in compose)** — audiobooks + podcasts, ~100MB RAM, own phone app with sleep timer + progress sync. Libraries point at pool `Other/audiobooks` + `Other/podcasts`. If you read at 2x, this is your app.
5. **Homepage dashboard** at `home.lan` — one family page: Photos, Files, Music, Jellyfin, Pi-hole, qbit. Already in net stack — add Navidrome/Audiobookshelf tiles when they go live.
6. **Scrutiny** — SMART web UI for the 1TB/4TB HDDs, email/Discord alerts before a disk dies.
7. **Home Assistant** (optional, ~300MB) — TV-box can double as Zigbee/Z-Wave hub later; automate "movie mode" lights via HDMI-CEC trigger.
8. **Tailscale exit node** — free VPN when traveling, routes via home Pi-hole (ad-blocking on the road).
9. **Syncthing** (sidecar to Nextcloud) — laptop ↔ server folder sync without cloud, good for the AI model-cache + code.
10. **Stirling-PDF / IT-Tools** — tiny web utils family actually uses.
11. **Restic + offsite copy** — USB/second-disk first (free); B2/Storj encrypted copy is paid + optional. Add offsite week one only if you want it — the 4TB shouldn't be the only copy either way.
12. **Kavita** (ebooks/comics/manga, ~100MB) — only if you read: send-to-Kindle style OPDS + phone readers, reads a pool `Other/ebooks` folder. Skip if you don't read digitally.
13. **RomM** (retro game library, ~200MB) — fits your Moonlight/gaming side: catalogs ROMs on the pool, browser play via EmulatorJS, pairs with a controller on the couch. Only if you have a retro collection; not a priority.

Suggested order after green: net (Pi-hole+Caddy+Tailscale) → Immich → Nextcloud → **Navidrome + Audiobookshelf** → Jellyfin → Paperless → *arr/qbit → Home Assistant.
Each is one dir under `docker/` with its own `compose.yml` + README so you can `up -d` incrementally.
