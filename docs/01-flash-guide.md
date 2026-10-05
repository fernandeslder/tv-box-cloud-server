# 01 — Flash Guide: from blank box to running services

You do this once (~1 hour, mostly waiting). While it runs, follow `docs/10-legion-ai-server.md` on the Legion 7.

**What you need:** an 8GB+ USB stick, another computer, ethernet cable, `ubuntu-24.04.x-server-amd64.iso` (newest point release).
Keep the HDDs **disconnected** during the install so they can't be partitioned by mistake.

## Option A — zero-touch (autoinstall seed)
1. On your other computer: `cd autoinstall && ./make-seed.sh` (asks user, SSH key, password, optional Wi-Fi).
2. Make the installer USB (Ventoy: copy the `.iso`; or Etcher/Rufus), and a second small FAT32 stick labelled `CIDATA` holding the files from `seed/`.
3. Plug both + ethernet into the box, boot the installer (`F12` on Lenovo), answer `yes` to autoinstall.
4. **Confirm the disk** (NVMe only) — the one required click. Walk away; the box reboots and runs the setup itself.
5. Follow progress: `ssh <user>@tvbox.local` then `tail -f /var/log/tvbox-firstboot.log`.

Details, other seed routes and troubleshooting: `autoinstall/README.md`.

## Option B — manual installer (screen by screen)
Boot the USB (UEFI entry) → `Try or Install Ubuntu Server`, then:
- **Language / keyboard / network:** defaults; DHCP is fine.
- **Storage:** "use entire disk" on the **238GB NVMe only** (LVM optional). Triple-check no HDD is selected.
- **Profile:** hostname `tvbox`, your username, a strong password.
- **SSH:** install OpenSSH server = **yes**; import/paste your `~/.ssh/id_ed25519.pub`.
- **Snaps:** select none.
- **Confirm** the destructive action and wait for the install to finish.
- **Reboot** and remove the USB when asked.
- **Connect:** `ssh <user>@tvbox.local` (or the IP from your router) and continue below.

## Run the setup
```bash
sudo apt update && sudo apt install -y git curl   # only if missing
curl -fsSL https://raw.githubusercontent.com/fernandeslder/tv-box-cloud-server/master/bootstrap.sh | sudo bash
```
This clones the repo to `/opt/tvbox` and starts the wizard (20-40 min, mostly downloads). It asks a few questions (domain, TV desktop, extras), **generates every password**, offers to format any blank USB disks (you type `ERASE` once), and ends by printing the address to open on your phone. Re-run safely any time: `cd /opt/tvbox && sudo ./setup.sh` (`--reconfigure` to be asked again).

**Unattended** (autoinstall, or `TVBOX_NONINTERACTIVE=1`): answers come from `/opt/tvbox-seed.env` (same keys as `docker/.env.example`, e.g. `DOMAIN`, `CF_API_TOKEN`, `TVBOX_DISKS=/dev/sdb:data,/dev/sdc:backup`). Without a `TVBOX_DISKS` line the installer never formats anything: it runs SSD-only and you add disks later with `sudo tvbox disks add /dev/sdX data`.

Human steps that always remain: confirm the install disk, approve the Tailscale subnet route + Split DNS, reserve the box's IP in the router and point the router's DNS at it (`docs/05`, `docs/08`).

## OS choice
**Ubuntu Server 24.04 LTS is recommended**: 5 years of support, and Docker, Plasma, Kodi and mergerfs are all packaged.
Debian 13 and Linux Mint 22 also work with the same setup (autoinstall is Ubuntu-only; use Option B there).

## If you ever re-flash
Data survives on the USB disks. Recovery = install the OS, run the setup again (disks labelled `tvbox-*` are re-adopted automatically, not reformatted), then `tvbox restore databases` (`docs/08`).
