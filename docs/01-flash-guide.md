# 01 — Flash Guide (Ubuntu 24.04 LTS)

## Why Ubuntu 24.04 LTS + Plasma minimal + Kodi
- Kernel 6.8→6.17 HWE + Mesa 24/25: Renoir Vega 6 VA-API (H.264/HEVC/VP9) works out of box. Verify with `vainfo`.
- 5yr LTS to 2029, native `docker-ce`, `mergerfs` in universe, official Tailscale repo, OpenSSH.
- Largest docs/LLM knowledge = most reliable idempotent scripts for agent reinstalls.
- Rejected: Bazzite/ChimeraOS (immutable/rolling, bad for Docker+Pi-hole server), Proxmox (single iGPU can't do HDMI passthrough cleanly), NixOS (best reproducibility, worst agent/package friction for Kodi), Debian (fine runner-up, weaker HWE/PPAs).

## What to download
- `ubuntu-24.04.4-server-amd64.iso` (or newer 24.04.x point release — ships HWE kernel).
- Flash with Ventoy or Balena Etcher to USB. Boot UEFI, install with:
  - hostname: `tvbox`, user: `htpc`, OpenSSH server: yes, import your `~/.ssh/id_ed25519.pub`.

## Install steps
1. Flash USB, boot, install Server (minimal, no snaps you don't need).
2. First boot:
   ```bash
   sudo apt update && sudo apt install -y linux-generic-hwe-24.04 git curl
   ```
3. SSH in from another machine and continue with `docs/02-os-postinstall.md`.
4. Keep this repo cloned at `~/tv-box-cloud-server` — after any future re-flash, repeat:
   ```bash
   git clone https://github.com/<you>/tv-box-cloud-server.git ~/tv-box-cloud-server
   cd ~/tv-box-cloud-server && cp docker/.env.example docker/.env
   nano docker/.env   # UUIDs, passwords, TZ
   sudo ./scripts/install.sh
   ```

## Current dev machine note
You are currently on Linux Mint 22.3 (Ubuntu 24.04 base) — good for drafting this repo, but do the real install on a fresh Ubuntu Server flash so SDDM autologin + Kodi session + resolved fix + mergerfs are clean.
