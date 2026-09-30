# 09 — Roadmap / Extra Ideas (recommended)

Beyond what you asked — all fit your taste, all free, all run on this box:

1. **Jellyfin server** (`/dev/dri` VA-API) — local movie/show library on the pool, plays in Kodi + Jellyfin Desktop + phones. Pair with **Prowlarr/Sonarr/Radarr** (opt-in, route via Gluetun).
2. **Paperless-ngx** — auto-ingest scans/PDFs from Nextcloud, OCR + PII gate + full-text search. Natural companion to Presidio.
3. **Audiobookshelf + Navidrome** — audiobooks + music server, phone apps, tiny RAM.
4. **Homepage dashboard** at `home.lan` — one family page: Photos, Files, Jellyfin, Pi-hole, qbit. Already in net stack.
5. **Scrutiny** — SMART web UI for the 1TB/4TB HDDs, email/Discord alerts before a disk dies.
6. **Home Assistant** (optional, ~300MB) — TV-box can double as Zigbee/Z-Wave hub later; automate "movie mode" lights via HDMI-CEC trigger.
7. **Tailscale exit node** — free VPN when traveling, routes via home Pi-hole (ad-blocking on the road).
8. **Syncthing** (sidecar to Nextcloud) — laptop ↔ server folder sync without cloud, good for the AI model-cache + code.
9. **Stirling-PDF / IT-Tools** — tiny web utils family actually uses.
10. **Restic + B2/Storj encrypted copy** — already in runbook; add it week one so the 4TB isn't the only copy.

Suggested order after green: net (Pi-hole+Caddy+Tailscale) → Immich → Nextcloud → Jellyfin → Paperless → *arr/qbit → Home Assistant.
Each is one dir under `docker/` with its own `compose.yml` + README so you can `up -d` incrementally.
