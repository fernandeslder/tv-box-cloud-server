# TV Box + Cloud Server

One always-on box, HDMI to the TV, two jobs:

1. **TV box** — Kodi, YouTube, Twitch, Moonlight, Stremio, IPTV, music, movies.
2. **Personal cloud** — phone photo backup (Immich), files (Nextcloud), a Windows/Mac network drive (Samba), ad-blocking DNS (Pi-hole), secret-screening of everything you upload.

**Storage model:** your **USB hard disks hold the data**; the **internal SSD is a write cache** so uploads run at full speed and a mover drains them to the HDDs in the background. If a USB cable wiggles loose, uploads keep landing on the SSD and catch up when the disk returns.

## Install (fresh machine → running server)

```bash
curl -fsSL https://raw.githubusercontent.com/fernandeslder/tv-box-cloud-server/master/bootstrap.sh | sudo bash
```

or, from a clone: `sudo ./setup.sh`

It asks a handful of questions (domain, TV desktop yes/no, optional extras), **generates every password itself**, detects and formats your blank USB disks after you type `ERASE`, installs Docker, starts everything, and prints one address to open on your phone: `https://setup.<your-domain>` (app links, QR codes, network-drive instructions).

Zero-touch from a USB stick you already own (no reformat): [`autoinstall/build-usb.sh`](autoinstall/README.md). Flash guide: [`docs/01-flash-guide.md`](docs/01-flash-guide.md). OS: **Ubuntu Server 26.04.1 LTS** (24.04 also works).

## Day to day

```bash
tvbox status      # storage, containers, addresses
tvbox doctor      # health check with plain-English fixes
tvbox backup      # run the backup now (also nightly)
tvbox verify-backup  # restore a sample from the backup and compare it (also weekly)
tvbox smart       # SMART health of every disk (also daily)
tvbox disks       # USB disk status / add a disk
tvbox update      # pull new versions
tvbox help
```

## What you get

| Address | What |
|---|---|
| `setup.<domain>` | One-page phone/PC onboarding: apps, QR codes, root cert (LAN-only mode), network drive |
| `photos.<domain>` | Immich — camera-roll backup, faces, search |
| `files.<domain>` | Nextcloud — documents, sync, sharing; your sorted library appears as folders |
| `\\tvbox\Uploads`, `\\tvbox\Cloud` | Samba shares. Drop anything in **Uploads**; it is sorted automatically |
| `home.<domain>`, `status.`, `metrics.`, `pihole.` | Dashboard, uptime, metrics, ad-blocking admin |
| `tv.`, `music.`, `audio.` | Jellyfin, Navidrome, Audiobookshelf (optional profile) |
| `docs.` | Paperless-ngx: OCR + full-text search for scans/PDFs (optional profile `docs`, drop files in `\\tvbox\Paperless`) |

Away from home: install Tailscale on the phone and everything works the same. Optional **public share links** (Nextcloud shares, Immich shared albums) go through a Cloudflare Tunnel — no port forwarding, works with a dynamic IP — and expose *only* share pages, never logins or admin.

## Repository map

```
setup.sh, bootstrap.sh     the entry points
scripts/                   installer steps (10-60), tvbox CLI, disks.sh, mover.sh, ingest + AI pipeline
docker/                    compose stacks: net (DNS, Caddy, tunnel, dashboards), cloud, media (profiles)
configs/                   systemd units (templated), Samba, SSH, router.conf.example
backups/                   restic backup + restore + weekly restore test (verify.sh)
clients/                   Windows / Mac / Linux "connect me" helpers
legion/                    one-command setup for the GPU worker (Windows + CachyOS)
autoinstall/               unattended Ubuntu install: seed + one-stick USB builder (build-usb.sh)
tests/                     bats suite (also runs in CI)
docs/                      the full plan; start with 00-overview.md
```

## Docs

[`00-overview`](docs/00-overview.md) · [`01-flash-guide`](docs/01-flash-guide.md) · [`02-os-postinstall`](docs/02-os-postinstall.md) · [`03-htpc-tv`](docs/03-htpc-tv.md) · [`04-storage-smart-cloud`](docs/04-storage-smart-cloud.md) · [`05-network-pihole`](docs/05-network-pihole.md) · [`06-ai-classification`](docs/06-ai-classification.md) · [`07-remote-access`](docs/07-remote-access.md) · [`08-ops-runbook`](docs/08-ops-runbook.md) · [`09-roadmap-ideas`](docs/09-roadmap-ideas.md) · [`10-legion-ai-server`](docs/10-legion-ai-server.md) · [`requirements`](docs/requirements.md) · [`review fixes`](docs/review-fixes.md)

## Status

Everything is lint-clean and unit-tested (`bats tests`: shellcheck, `docker compose config`, Caddy validation, the mover, router, redactor, ingest, wizard, backup + restore test, SMART, USB builder). CI also checks weekly that every pinned container image still exists (`scripts/check-images.py`). The parts that need real hardware — formatting disks, mounts, systemd, container start, Cloudflare/Tailscale accounts — were written carefully but have **not yet run on the box**; `docs/review-fixes.md` lists exactly what to watch on first boot.

MIT licensed — see [LICENSE](LICENSE).
