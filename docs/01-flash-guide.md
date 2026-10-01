# 01 — Flash Guide: full OS setup, step by step (human checklist)

Target: the box that will live under your TV. You do this part by hand once (~1 hour, mostly waiting). While the long `apt`/Docker downloads run, switch to your Legion 7 and follow `docs/10-legion-ai-server.md` in parallel.

## What you need
- 8GB+ USB stick (will be wiped), another computer, ethernet cable (recommended for the install).
- Ubuntu Server ISO: `ubuntu-24.04.x-server-amd64.iso` (get the newest 24.04.x point release — it ships the HWE kernel + new Mesa).
- Leave the 1TB/4TB HDDs **disconnected** during OS install so you can't accidentally partition them. Connect them afterwards.

## Step 1 — Make the boot USB (on your other machine)
Pick one:
- **Ventoy** (recommended): install Ventoy to the USB, then just copy the `.iso` file onto it.
- **Balena Etcher / Rufus**: flash the `.iso` directly to the USB.
Result: a bootable Ubuntu installer stick.

## Step 2 — Boot the TV box from USB
1. Plug USB + ethernet + keyboard into the box (HDMI to TV so you can see it).
2. Power on, open the boot menu (`F12` on Lenovo, `F2`/`Del` for BIOS on others) and select the USB stick (UEFI entry).
3. Choose `Try or Install Ubuntu Server`.

## Step 3 — Ubuntu Server installer (Subiquity) screens
1. Language, keyboard, network: DHCP is fine.
2. Storage: **install to the 238GB NVMe only**. Use entire disk (with LVM if offered — fine either way). Triple-check no HDD is selected.
3. Profile: hostname `tvbox`, username `htpc`, set a strong password.
4. **Install OpenSSH server: YES.** On the SSH screen, paste your `~/.ssh/id_ed25519.pub` from your other machine (or add it later — see step 5).
5. Skip snaps. Reboot, remove USB when asked.

## Step 4 — First boot + SSH in (from your other machine)
```bash
ssh htpc@tvbox        # or: ssh htpc@<box-LAN-IP>
sudo apt update && sudo apt upgrade -y && sudo reboot
```

## Step 5 — Clone this repo and configure (the only typing-heavy part)
```bash
git clone https://github.com/fernandeslder/tv-box-cloud-server.git ~/tv-box-cloud-server
cd ~/tv-box-cloud-server
cp docker/.env.example docker/.env && nano docker/.env
```
Fill in (everything else has sane defaults):
- `PIHOLE_PASS` — Pi-hole admin password.
- `IMMICH_DB_PASSWORD` — database password (any long random string).
- `CADDY_LAN_IP` — the box's LAN IP (e.g. `192.168.2.10`).
- `STORAGE_DISK1_UUID` / `STORAGE_DISK2_UUID` — from `blkid` **after** you connect the HDDs. Leave commented until then.

## Step 6 — Run the installer (go do Legion 7 setup while it works)
```bash
sudo ./scripts/install.sh
```
This takes 20–40 min (Plasma, Kodi, Docker, Mesa). It's idempotent — safe to re-run if anything fails. Now switch machines: `docs/10-legion-ai-server.md`.

## Step 7 — Start services + verify (back on the TV box)
```bash
cd ~/tv-box-cloud-server/docker && docker compose up -d
../scripts/90-verify.sh
```
Then: `docs/08-ops-runbook.md` (router DNS cutover to Pi-hole, backup test).

## If you ever re-flash
Data survives on the HDD pool. Recovery = steps 4–7 again, nothing else to remember.
