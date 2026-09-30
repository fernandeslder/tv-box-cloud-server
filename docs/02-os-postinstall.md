# 02 — OS Postinstall (drivers, desktop, autologin)

Run via `scripts/install.sh` (idempotent) or manually:

```bash
# drivers + VA-API (Renoir VCN2.2: H264/HEVC/VP9, no AV1 decode)
sudo apt install -y mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
  vainfo libva2 firmware-sof-signed pipewire wireplumber bluetooth bluez
vainfo | grep -iE "VA-API|H264|HEVC|VP9"

# desktop + HTPC session (minimal Plasma, SDDM, Kodi)
sudo apt install -y plasma-desktop sddm kodi kodi-pvr-iptvsimple \
  firefox mpv yt-dlp cec-utils libcec4 flatpak
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Docker CE (Ubuntu repo docker.io is OK, but CE tracks compose v2 faster)
# see scripts/30-docker.sh

# mergerfs + tools
sudo apt install -y mergerfs smartmontools restic rclone htop
```

## SDDM autologin (`configs/sddm/autologin.conf`)
```ini
[Autologin]
User=htpc
Session=plasma.desktop
```
Kodi standalone session (`kodi.desktop`) stays selectable at login; autostart `kodi -fs` via `~/.config/autostart/kodi.desktop` if you want boot-to-Kodi.

## systemd-resolved fix (required before Pi-hole)
```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf "[Resolve]\nDNSStubListener=no\n" | sudo tee /etc/systemd/resolved.conf.d/no-stub.conf
sudo rm -f /etc/resolv.conf && sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
ss -tulnp | grep :53  # must be empty
```
Do NOT fully disable `systemd-resolved` — breaks netplan/VPN.

## Verify
`./scripts/90-verify.sh`: `vainfo`, `docker ps`, `mountpoint /mnt/pool`, `tailscale status`, `dig @127.0.0.1 google.com`.
