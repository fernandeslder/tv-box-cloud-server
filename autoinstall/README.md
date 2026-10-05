# Zero-touch install (Ubuntu Server 24.04 autoinstall)

Goal: boot the installer USB, confirm **one** screen (the disk), walk away. The box installs the OS,
reboots, and on first boot downloads this repo and runs `setup.sh` by itself.

Files here:
- `user-data` — the autoinstall template (placeholders filled by `make-seed.sh`).
- `meta-data` — required by cloud-init, intentionally trivial.
- `make-seed.sh` — fills the template and builds `seed/` (+ `seed.iso`). Never prints your password.

## What a human still has to do (honest list)
1. Create the seed (below) and the installer USB.
2. **Confirm the disk** at the storage screen. This is deliberate: a wrong guess wipes a disk.
3. Put real secrets in the env file (Cloudflare token, Pi-hole password, ...) or run `sudo ./setup.sh` once over SSH.
4. **`tailscale up`** needs you to approve the device in your browser (login link in the log / on SSH).
5. Connect the HDDs *after* the install and fill their UUIDs (`blkid`), as in the main docs.

## Step by step (simplest route: second USB stick named CIDATA)
1. **On your main computer**, make a key if you have none: `ssh-keygen -t ed25519`
2. Build the seed (Linux/macOS/WSL; needs `bash`, plus `openssl` or `mkpasswd`):
   ```bash
   git clone https://github.com/fernandeslder/tv-box-cloud-server.git && cd tv-box-cloud-server/autoinstall
   ./make-seed.sh                       # asks user, SSH key file, password, optional Wi-Fi
   # or non-interactive:
   ./make-seed.sh --user tvbox --ssh-key-file ~/.ssh/id_ed25519.pub --wifi-ssid MyWifi
   # optional: pre-fill setup answers (copy docker/.env.example to a file and edit it first)
   ./make-seed.sh --env-file ../docker/.env
   ```
   Result: `seed/` (`user-data`, `meta-data`, optionally `tvbox-seed.env`) and `seed.iso` (volume label `CIDATA`).
   No tool? Edit `user-data` by hand: replace the `@@...@@` values; hash with `mkpasswd -m sha-512` or `openssl passwd -6`.
   Wi-Fi: remove the `#W# ` prefix on that block and fill SSID/password.
3. Make the **Ubuntu Server 24.04 installer USB** as usual (Ventoy: copy the `.iso`; or Etcher/Rufus).
4. Take a **second USB stick** (any size, will be wiped), format it **FAT32 with the volume label `CIDATA`**
   (Windows: Format → Volume label; Linux: `sudo mkfs.vfat -F32 -n CIDATA /dev/sdX1`), then copy the **files inside `seed/`**
   to its root. (Alternative: `sudo dd if=seed.iso of=/dev/sdX bs=4M status=progress` — double-check `sdX`!)
5. Plug **both** sticks + ethernet (+ HDMI/keyboard) into the box. **HDDs and other USB drives stay unplugged.**
   Boot from the installer stick (`F12` on Lenovo) → `Try or Install Ubuntu Server`.
6. The installer finds the seed, asks `Continue with autoinstall?` → type `yes`. It then **stops at Storage**:
   check that it shows the NVMe/SSD only, confirm, and answer the final "destructive action" prompt.
7. Walk away. Remove both sticks when it reboots.

### Other routes
- **Kernel argument / HTTP (no second stick):** on the installer GRUB menu press `e`, add to the `linux` line
  `autoinstall ds=nocloud-net\;s=http://<your-pc-ip>:8000/` (keep the backslash), `F10`. On your PC run
  `cd seed && python3 -m http.server 8000`. The `tvbox-seed.env` pre-fill is **not** picked up this way
  (copy it later to `/opt/tvbox-seed.env` and run `sudo systemctl start tvbox-firstboot`).
- **Seed inside the installer ISO:** `ds=nocloud;s=/cdrom/` with `user-data`/`meta-data` added to the ISO root — fiddly, not recommended.

## What the install does
- Installs to the SSD/NVMe only (`layout: direct`, `match: {ssd: true}`): HDDs are rotational so they don't match,
  but a USB SSD would — keep USB drives unplugged. The screen is interactive so you always confirm.
- Hostname `tvbox`, your user, **SSH key-only login** (password login over SSH is off; the console still takes the password).
- Ethernet via DHCP (Wi-Fi optional), packages `git curl avahi-daemon`, no installer self-update.
- Installs `tvbox-firstboot.service`: after the first reboot and network-up it downloads `bootstrap.sh` from this repo's
  `master` branch and runs it with `TVBOX_NONINTERACTIVE=1` (and `TVBOX_ENV_FILE=/opt/tvbox-seed.env` if the seed had
  `tvbox-seed.env`; the file is stored root-only, mode 600). `bootstrap.sh` clones to `/opt/tvbox` and runs `setup.sh --yes`.
- Marker `/var/lib/tvbox-firstboot.done` is written on success and the service disables itself. On failure it stays enabled
  and retries on the next boot.

## How long
OS install ~10–15 min (needs internet for packages). First-boot setup ~20–40 min more (Plasma, Kodi, Docker, Mesa).
The box may reboot during setup.

## Find the box and watch progress
```bash
ssh tvbox@tvbox.local            # your username; or find the IP in the router's DHCP list
tail -f /var/log/tvbox-firstboot.log
journalctl -u tvbox-firstboot -b # same service, journal view
ls /var/lib/tvbox-firstboot.done # exists = finished OK
sudo systemctl start tvbox-firstboot   # re-run after fixing a failure
```
`tvbox.local` needs mDNS (built into macOS/Linux/Windows 10+). If it doesn't resolve, use the IP from the router.

## Not verified
Written without a test install: Subiquity schema details (`match: {ssd: true}`, `late-commands` mounting of the CIDATA
device, Wi-Fi netplan) follow the Ubuntu docs but should be checked on the first real run (a VM works: attach `seed.iso` as a CD).
