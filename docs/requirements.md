# Requirements (source of truth — compiled from the owner's answers)

## Device + roles
- One always-on box (ThinkPad-class laptop chassis: Ryzen 5 PRO 4650U, 14GB, 238GB NVMe) over HDMI to a TV: TV box + personal cloud.
- TV: YouTube, Twitch, Moonlight, browser, IPTV, Stremio + Torrentio, own music (Navidrome), Jellyfin. USB HID remotes; no native HDMI-CEC on x86.
- Network: Pi-hole required; Wi-Fi now, **Ethernet later** (the installer must survive the IP change).
- Reproducible: flash -> one command -> running. Agent-redoable over SSH. Repo: github.com/fernandeslder/tv-box-cloud-server (public; no secrets in it).

## Setup experience (owner's priority)
- One command + interactive wizard that generates all secrets; phone onboarding page with QR codes; Windows/Mac/Linux client helpers; one-command Legion setup (Windows + CachyOS); autoinstall USB seed. Works on any apt-based distro and any username.

## Storage
- **Data on external USB HDDs; the internal SSD is a write cache** (fast ingest) plus DBs/thumbnails. 1TB + 4TB blank disks, formatted ext4 by the installer after explicit confirmation. Largest = data, the other = backup.
- Must tolerate a loose/disconnecting USB cable: keep working from the SSD, re-attach automatically, never write into an empty mountpoint.
- Backup is a **dedicated disk** (never the same disk as the data); important folders only if it is smaller.
- `inbox/` is the single Uploads target; sorted trees Photos/ Documents/ Music/ Recordings/ Videos/ Other/ + private/ are visible in Samba, Nextcloud, and Photos is an Immich external library.

## Cloud
- Phone photo backup (Immich), phone/PC file sync + web UI (Nextcloud), Samba network shares, sharing with other people, access away from home via Tailscale.
- Domain: **lder.fyi** on Cloudflare (dynamic IP on Bell): trusted certs via DNS-01; **public only for Nextcloud share links + Immich shared albums** via a Cloudflare Tunnel; everything else Tailscale/LAN only.
- Email server: **deferred**.

## Threat model (secrets, not PII)
- Only credentials matter (API keys, passwords, tokens, private keys). Names/addresses are not a concern.
- Secrets live in `private/` — still visible to the owner. Nothing secret-bearing goes to outside APIs.
- Calls to the owner's own Legion need no redaction. **Calls to any external API are redacted.**
- Security stance: convenience first (private-LAN firewall, no hardening that costs usability), but nothing admin-facing published to the LAN, and public exposure is share-links only.

## AI
- Everything on by default: Tier 0 TruffleHog, Jev judge on the Legion, sorting, faces, whisper, vision.
- External provider: **Command Code Provider API**. Choose the intelligence level needed: `typesafe/jev` -> free models -> cheap-but-strong (deepseek, glm, mimo, kimi, muse) -> strong only if allowed. Monthly cap; free always allowed.
- Legion 7 (RTX 4080 12GB, dual-boot Win11/CachyOS, often offline): queue waits; one workload family at a time.

## System 1 vs System 2
- System 1 (Jev) = typed decisions (noul/choice/score), never parsed prose; malformed = defer. Fallback: Legion -> local NanoJev -> defer. System 2 (qwen2.5:7b) only invents category names.

## Sorting
- Faces via Immich; audio speech-vs-music via whisper (8+ words = speech); music -> Music/<Artist>/[Album]/ with fuzzy artist dedup (>= 0.82); documents filename-first with stage-0 local rules (IDs/Finance/Health -> private/) before any model.
